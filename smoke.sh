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
	local members subnet
	subnet="$(docker network inspect -f '{{range .IPAM.Config}}{{.Subnet}} {{end}}' "$EDGE_NETWORK" 2>/dev/null)"
	subnet="${subnet% }"
	if [ "$subnet" = "$EDGE_SUBNET" ]; then
		pass "network $EDGE_NETWORK: subnet $EDGE_SUBNET"
	else
		fail "network $EDGE_NETWORK: subnet '${subnet:-none}' (must be $EDGE_SUBNET)"
	fi
	members="$(docker network inspect -f '{{range .Containers}}{{.Name}} {{end}}' "$EDGE_NETWORK" 2>/dev/null)"
	if [[ " $members " == *" caddy "* ]]; then
		pass "network $EDGE_NETWORK: caddy attached"
	else
		fail "network $EDGE_NETWORK: caddy not attached (members: ${members:-none})"
	fi
}

# The running Caddy must be the custom build (caddy/Dockerfile), or the
# staging vhosts cannot get certificates.
check_caddy_plugin() {
	if docker exec caddy caddy list-modules 2>/dev/null | grep -qx dns.providers.cloudflare; then
		pass "caddy has the Cloudflare DNS plugin"
	else
		fail "caddy lacks dns.providers.cloudflare (stock image? docker compose build caddy, README §3)"
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

# Same hostnames as conf.d/staging.caddy's site address. Keep in step.
staging_hosts() {
	local label
	echo "$BAJA_DOMAIN"
	for label in api certificado fila juiz resultados forum; do
		echo "$label.$BAJA_DOMAIN"
	done
	echo "$FORMULA_DOMAIN"
}

# Staging vhosts are Cloudflare-only (README §5.3). Three checks:
#  1. Straight to this origin: the peer is the Docker gateway, not a
#     Cloudflare address, so every hostname must answer 403, whether or not
#     baja-nginx runs. Anything else means the gate is open.
#  2. Through Cloudflare (public DNS, so a real Cloudflare edge is the peer):
#     baja-nginx running -> nginx answers (any code but 000/403/5xx; vhosts
#     may redirect or 404 their root). Not running -> 502.
#  3. CF-Connecting-IP reaches nginx: one marked request through Cloudflare
#     to the apex, then nginx's access log for it. nginx's realip module puts
#     CF-Connecting-IP in $remote_addr (the first field of the default log
#     format) only if the header arrived and nginx trusts baja-edge (§5.2);
#     otherwise the line shows Caddy's baja-edge address.
check_staging_vhosts() {
	if [ ! -f "$CADDY_DIR/conf.d/staging.caddy" ]; then
		log "staging vhosts not enabled; skipped"
		return 0
	fi
	local nginx_up=0 host code
	[ "$(docker inspect -f '{{.State.Running}}' baja-nginx 2>/dev/null)" = true ] && nginx_up=1

	while read -r host; do
		expect_code "staging $host direct to origin (not Cloudflare)" \
			"$(http_code --resolve "$host:443:127.0.0.1" "https://$host/")" 403
	done < <(staging_hosts)

	while read -r host; do
		code="$(http_code "https://$host/")"
		if [ "$nginx_up" = 1 ]; then
			case "$code" in
			000 | 403 | 5??) fail "staging $host via Cloudflare: HTTP $code with baja-nginx running" ;;
			*) pass "staging $host via Cloudflare: HTTP $code (baja-nginx running)" ;;
			esac
		else
			expect_code "staging $host via Cloudflare (baja-nginx down)" "$code" 502
		fi
	done < <(staging_hosts)

	if [ "$nginx_up" = 1 ]; then
		check_cf_connecting_ip
	else
		log "baja-nginx not running; CF-Connecting-IP check skipped"
	fi
}

check_cf_connecting_ip() {
	local marker line addr
	marker="baja-smoke=$(date +%s)-$$-$RANDOM"
	http_code "https://$BAJA_DOMAIN/?$marker" >/dev/null
	for _ in 1 2 3; do
		line="$(docker logs --since 2m baja-nginx 2>&1 | grep -F "$marker" | tail -n1)"
		[ -n "$line" ] && break
		sleep 1
	done
	addr="${line%% *}"
	if [ -z "$line" ]; then
		fail "CF-Connecting-IP: marked request never reached baja-nginx's log"
	elif [[ "$addr" == "${EDGE_SUBNET%.*/*}."* ]]; then
		fail "CF-Connecting-IP: nginx logged Caddy's address $addr (header missing, or nginx lacks set_real_ip_from $EDGE_SUBNET, README §5.2)"
	else
		pass "CF-Connecting-IP reaches nginx (client $addr)"
	fi
}

main() {
	load_env
	require_vars TAILSCALE_IP EVOLUTION_API_KEY EVOLUTION_INSTANCE
	check_containers
	check_edge_network
	check_caddy_plugin
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
