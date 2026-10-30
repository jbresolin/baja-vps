#!/usr/bin/env bash
# Prepare the host for the base stack, or switch the staging vhosts on/off.
#
#   sudo ./setup.sh                    network, directories, .env permissions
#   sudo ./setup.sh --enable-staging   install conf.d/staging.caddy, reload Caddy
#   sudo ./setup.sh --disable-staging  remove it again, reload Caddy
#
# Safe to re-run: every step checks before it changes anything.
# README §2 (setup) and §5 (staging vhosts).
set -euo pipefail

STACK_DIR="${STACK_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
# Overridable for tests only; the compose file hard-codes these paths.
CADDY_DIR="${CADDY_DIR:-/srv/caddy}"
PIPELINE_DIR="${PIPELINE_DIR:-/srv/pipeline}"
# shellcheck source=lib/common.sh
. "$STACK_DIR/lib/common.sh"

STAGING_FILE="$CADDY_DIR/conf.d/staging.caddy"

# a.b.c.d -> integer.
ip4_to_int() {
	local a b c d
	IFS=. read -r a b c d <<<"$1"
	echo $(((a << 24) | (b << 16) | (c << 8) | d))
}

# cidr4_overlap <a.b.c.d/n> <e.f.g.h/m>: true if the two ranges share an
# address, i.e. they agree on the shorter prefix. A bare address is a /32.
cidr4_overlap() {
	local a="${1%/*}" b="${2%/*}" la lb len mask
	la=32 lb=32
	[[ "$1" == */* ]] && la="${1#*/}"
	[[ "$2" == */* ]] && lb="${2#*/}"
	len=$((la < lb ? la : lb))
	mask=$(((0xFFFFFFFF << (32 - len)) & 0xFFFFFFFF))
	[ $(($(ip4_to_int "$a") & mask)) -eq $(($(ip4_to_int "$b") & mask)) ]
}

# Every IPv4 destination the host routes (all tables, so Tailscale's table
# 52 and local addresses count too), one per line. `default` is skipped: it
# overlaps everything by definition.
host_routes() {
	ip -4 route show table all | while read -r first second _; do
		case "$first" in
		unicast | local | broadcast | multicast | throw | unreachable | prohibit | blackhole | anycast | nat) first="$second" ;;
		esac
		if [[ "$first" =~ ^[0-9]+(\.[0-9]+){3}(/[0-9]+)?$ ]]; then
			echo "$first"
		fi
	done
}

# "<network> <subnet>" for every IPv4 subnet of every Docker network.
docker_subnets() {
	local ids
	ids="$(docker network ls -q)"
	[ -n "$ids" ] || return 0
	# shellcheck disable=SC2086
	docker network inspect -f '{{.Name}}{{range .IPAM.Config}} {{.Subnet}}{{end}}' $ids |
		while read -r name subnets; do
			for subnet in $subnets; do
				if [[ "$subnet" != *:* ]]; then
					echo "$name $subnet"
				fi
			done
		done
}

# Refuse to create baja-edge if 10.201.0.0/24 is already in use anywhere:
# a clash would silently misroute traffic or break the proxy trust.
check_subnet_free() {
	local routes nets route name subnet clashes=()
	# Captured first so a failing `ip` or `docker` stops us, rather than
	# reading as "nothing in use".
	routes="$(host_routes)" || die "could not list host routes (ip -4 route show table all)"
	nets="$(docker_subnets)" || die "could not list Docker networks"
	while read -r route; do
		if [ -n "$route" ] && cidr4_overlap "$route" "$EDGE_SUBNET"; then
			clashes+=("route $route")
		fi
	done <<<"$routes"
	while read -r name subnet; do
		if [ -n "$subnet" ] && cidr4_overlap "$subnet" "$EDGE_SUBNET"; then
			clashes+=("docker network $name ($subnet)")
		fi
	done <<<"$nets"
	if [ "${#clashes[@]}" -gt 0 ]; then
		log "ERROR: $EDGE_SUBNET overlaps:" >&2
		printf '         %s\n' "${clashes[@]}" >&2
		die "not creating $EDGE_NETWORK. Free that range (README §2.3); it cannot be moved without changing all three stacks"
	fi
}

# Create baja-edge with the fixed subnet. An existing one must already have
# it: never recreate it here, that would detach every running stack.
ensure_network() {
	local subnet
	if subnet=$(docker network inspect -f '{{range .IPAM.Config}}{{.Subnet}} {{end}}' "$EDGE_NETWORK" 2>/dev/null); then
		subnet="${subnet% }"
		[ "$subnet" = "$EDGE_SUBNET" ] ||
			die "$EDGE_NETWORK exists with subnet '$subnet', must be $EDGE_SUBNET. Recreate it in a maintenance window (README §11)"
		log "network $EDGE_NETWORK exists ($subnet)"
		return 0
	fi
	check_subnet_free
	docker network create --driver bridge --subnet "$EDGE_SUBNET" "$EDGE_NETWORK" >/dev/null
	log "created network $EDGE_NETWORK ($EDGE_SUBNET)"
}

# Directories the compose file bind-mounts, plus the backup target.
# Run as root, so `install -d` leaves them root-owned.
ensure_dirs() {
	install -d -m 755 "$CADDY_DIR" "$CADDY_DIR/conf.d"
	# The pipeline owns /srv/pipeline (uid 10001, mode 750) and creates it
	# properly when it is installed. Off-season it may not exist; create it
	# empty so Caddy's read-only mount has something to point at, but never
	# touch an existing one.
	if [ ! -d "$PIPELINE_DIR" ]; then
		install -d -m 755 "$PIPELINE_DIR"
		log "created empty $PIPELINE_DIR (the pipeline takes it over later)"
	fi
	# Dumps hold the WhatsApp private keys.
	install -d -m 700 "$BACKUP_DIR"
	log "directories ready: $CADDY_DIR/conf.d, $PIPELINE_DIR, $BACKUP_DIR"
}

caddy_running() {
	[ "$(docker inspect -f '{{.State.Running}}' caddy 2>/dev/null)" = true ]
}

reload_caddy() {
	docker exec caddy caddy reload --config /etc/caddy/Caddyfile
}

base_setup() {
	require_vars TAILSCALE_IP
	# An .env from before the subnet was fixed may still set it.
	[ -z "${BAJA_EDGE_SUBNET:-}" ] || [ "$BAJA_EDGE_SUBNET" = "$EDGE_SUBNET" ] ||
		die "BAJA_EDGE_SUBNET=$BAJA_EDGE_SUBNET in .env: the subnet is fixed at $EDGE_SUBNET now; delete that line"
	BACKUP_DIR="${BACKUP_DIR:-/var/backups/baja-evolution}"
	chmod 600 "$STACK_DIR/.env"
	ensure_network
	ensure_dirs
	log "done. Next: README §3 (bring up the stack)."
}

enable_staging() {
	require_vars BAJA_DOMAIN FORMULA_DOMAIN CLOUDFLARE_API_TOKEN
	case "$BAJA_DOMAIN $FORMULA_DOMAIN" in
	*example.*) die "BAJA_DOMAIN / FORMULA_DOMAIN still hold example values" ;;
	esac
	# Caddy refuses a config whose DNS provider has no usable token, and then
	# would not start at all after a restart (Evolution's route included).
	[ "$CLOUDFLARE_API_TOKEN" != REPLACE_ME ] ||
		die "CLOUDFLARE_API_TOKEN still holds the example value (README §5.3)"
	[ -d "$CADDY_DIR/conf.d" ] || die "$CADDY_DIR/conf.d missing; run ./setup.sh first"

	install -m 644 "$STACK_DIR/conf.d/staging.caddy" "$STAGING_FILE"
	log "installed $STAGING_FILE"

	if ! caddy_running; then
		log "caddy is not running; the vhosts load when it starts."
		return 0
	fi
	# Recreates Caddy only if its environment changed (e.g. BAJA_DOMAIN was
	# just filled in); a reload alone would not see new values.
	compose up -d caddy
	if ! reload_caddy; then
		# Leave the running config as it was, and don't leave a file behind
		# that would stop Caddy on its next restart.
		rm -f "$STAGING_FILE"
		die "Caddy rejected the staging vhosts; file removed, old config still active"
	fi
	log "staging vhosts enabled for $BAJA_DOMAIN and $FORMULA_DOMAIN"
}

disable_staging() {
	rm -f "$STAGING_FILE"
	log "removed $STAGING_FILE"
	if caddy_running; then
		reload_caddy
	fi
}

main() {
	require_root
	load_env
	case "${1:-}" in
	"") base_setup ;;
	--enable-staging) enable_staging ;;
	--disable-staging) disable_staging ;;
	*) die "usage: $0 [--enable-staging | --disable-staging]" ;;
	esac
}

main "$@"
