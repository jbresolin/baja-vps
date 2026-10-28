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

EDGE_NETWORK=baja-edge
STAGING_FILE="$CADDY_DIR/conf.d/staging.caddy"

# Create baja-edge with the fixed subnet. If it already exists, only warn
# when the subnet differs: recreating it would detach every running stack.
ensure_network() {
	local subnet
	if subnet=$(docker network inspect -f '{{range .IPAM.Config}}{{.Subnet}}{{end}}' "$EDGE_NETWORK" 2>/dev/null); then
		if [ "$subnet" = "$BAJA_EDGE_SUBNET" ]; then
			log "network $EDGE_NETWORK exists ($subnet)"
		else
			log "WARNING: $EDGE_NETWORK has subnet '$subnet', .env says $BAJA_EDGE_SUBNET."
			log "         staging nginx must trust '$subnet' for the client IP (README §5.2)."
		fi
		return 0
	fi
	docker network create --driver bridge --subnet "$BAJA_EDGE_SUBNET" "$EDGE_NETWORK" >/dev/null
	log "created network $EDGE_NETWORK ($BAJA_EDGE_SUBNET)"
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
	require_vars TAILSCALE_IP BAJA_EDGE_SUBNET
	BACKUP_DIR="${BACKUP_DIR:-/var/backups/baja-evolution}"
	chmod 600 "$STACK_DIR/.env"
	ensure_network
	ensure_dirs
	log "done. Next: README §3 (bring up the stack)."
}

enable_staging() {
	require_vars BAJA_DOMAIN FORMULA_DOMAIN
	case "$BAJA_DOMAIN $FORMULA_DOMAIN" in
	*example.*) die "BAJA_DOMAIN / FORMULA_DOMAIN still hold example values" ;;
	esac
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
