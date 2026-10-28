#!/usr/bin/env bash
# Smoke test for the base stack. Run on the VPS after any change:
#   sudo ./smoke.sh
# Prints one PASS/FAIL line per check and exits non-zero if any failed.
# Read-only: it changes nothing. README §10.
set -uo pipefail

STACK_DIR="${STACK_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
CADDY_DIR="${CADDY_DIR:-/srv/caddy}"
# shellcheck source=lib/common.sh
. "$STACK_DIR/lib/common.sh"

FAILURES=0

pass() { printf 'PASS  %s\n' "$*"; }
fail() {
	printf 'FAIL  %s\n' "$*"
	FAILURES=$((FAILURES + 1))
}

# expect_code <label> <got> <want>
expect_code() {
	if [ "$2" = "$3" ]; then
		pass "$1 -> $2"
	else
		fail "$1 -> $2 (want $3)"
	fi
}

# HTTP status of a request, "000" when nothing answered. Extra args go to curl.
http_code() {
	curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$@" || true
}

check_containers() {
	local svc id status
	for svc in postgres redis evolution caddy; do
		id="$(compose ps -q "$svc" 2>/dev/null)"
		if [ -z "$id" ]; then
			fail "container $svc: not created"
			continue
		fi
		status="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$id" 2>/dev/null)"
		if [ "$status" = healthy ]; then
			pass "container $svc: healthy"
		else
			fail "container $svc: ${status:-unknown}"
		fi
	done
}

check_edge_network() {
	local members
	members="$(docker network inspect -f '{{range .Containers}}{{.Name}} {{end}}' baja-edge 2>/dev/null)"
	if [[ " $members " == *" caddy "* ]]; then
		pass "network baja-edge: caddy attached"
	else
		fail "network baja-edge: caddy not attached (members: ${members:-none})"
	fi
}

check_caddy_http() {
	local code
	code="$(http_code http://127.0.0.1/)"
	if [ "$code" != 000 ]; then
		pass "caddy answers on :80 (HTTP $code)"
	else
		fail "caddy: nothing answers on :80"
	fi
}

# Evolution must be published on the Tailscale IP and nowhere else.
check_evolution_binding() {
	local bindings line ok=1
	bindings="$(docker port caddy 8081/tcp 2>/dev/null)"
	[ -n "$bindings" ] || ok=0
	while IFS= read -r line; do
		[ -z "$line" ] && continue
		[ "${line%:*}" = "$TAILSCALE_IP" ] || ok=0
	done <<<"$bindings"
	if [ "$ok" = 1 ]; then
		pass "evolution listener bound to $TAILSCALE_IP only"
	else
		fail "evolution listener bindings: ${bindings:-none} (expected $TAILSCALE_IP:8081 only)"
	fi
}

check_evolution_api() {
	local base="http://$TAILSCALE_IP:8081" body state
	expect_code "evolution: no apikey" "$(http_code "$base/")" 401
	expect_code "evolution: with apikey" "$(http_code -H "apikey: $EVOLUTION_API_KEY" "$base/")" 200

	body="$(curl -s --max-time 10 -H "apikey: $EVOLUTION_API_KEY" \
		"$base/instance/connectionState/$EVOLUTION_INSTANCE" || true)"
	state="$(grep -o '"state":"[a-z]*"' <<<"$body" | head -n1 | cut -d'"' -f4)"
	if [ "$state" = open ]; then
		pass "evolution instance $EVOLUTION_INSTANCE: open"
	else
		fail "evolution instance $EVOLUTION_INSTANCE: ${state:-no state} (response: ${body:0:200})"
	fi
}

# Each staging vhost, straight to this origin (not through Cloudflare).
# baja-nginx running -> nginx must answer (200 for the apex; other vhosts
# may redirect or 404 their root, which is fine). Not running -> 502.
check_staging_vhosts() {
	if [ ! -f "$CADDY_DIR/conf.d/staging.caddy" ]; then
		log "staging vhosts not enabled; skipped"
		return 0
	fi
	local nginx_up=0 host code
	[ "$(docker inspect -f '{{.State.Running}}' baja-nginx 2>/dev/null)" = true ] && nginx_up=1
	for host in "$BAJA_DOMAIN" api."$BAJA_DOMAIN" certificado."$BAJA_DOMAIN" fila."$BAJA_DOMAIN" \
		juiz."$BAJA_DOMAIN" resultados."$BAJA_DOMAIN" forum."$BAJA_DOMAIN" "$FORMULA_DOMAIN"; do
		code="$(http_code --resolve "$host:443:127.0.0.1" "https://$host/")"
		if [ "$nginx_up" = 1 ]; then
			case "$code" in
			000 | 502 | 503 | 504) fail "staging $host: HTTP $code with baja-nginx running" ;;
			*) pass "staging $host: HTTP $code (baja-nginx running)" ;;
			esac
		else
			expect_code "staging $host (baja-nginx down)" "$code" 502
		fi
	done
}

main() {
	load_env
	require_vars TAILSCALE_IP EVOLUTION_API_KEY EVOLUTION_INSTANCE
	check_containers
	check_edge_network
	check_caddy_http
	check_evolution_binding
	check_evolution_api
	check_staging_vhosts
	if [ "$FAILURES" -gt 0 ]; then
		log "$FAILURES check(s) failed"
		exit 1
	fi
	log "all checks passed"
}

main "$@"
