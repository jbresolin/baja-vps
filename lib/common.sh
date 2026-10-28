# shellcheck shell=bash
# Shared helpers for setup.sh, backup.sh and smoke.sh. Source it, don't run it.
#
# Callers set STACK_DIR (the checkout holding docker-compose.yml and .env)
# before sourcing. Tests point it at a temporary directory.

# Prefix every line with the calling script's name, so journald output from
# the backup timer reads clearly.
log() {
	printf '[%s] %s\n' "${0##*/}" "$*"
}

die() {
	log "ERROR: $*" >&2
	exit 1
}

require_root() {
	# Tests run unprivileged and set this; nothing else should.
	[ "${BAJA_SKIP_ROOT_CHECK:-}" = 1 ] && return 0
	[ "$(id -u)" -eq 0 ] || die "run as root (sudo -i first)"
}

# Load $STACK_DIR/.env into the environment, the same way the runbook does.
load_env() {
	local env_file="$STACK_DIR/.env"
	[ -r "$env_file" ] || die "cannot read $env_file (copy .env.example and fill it in)"
	set -a
	# shellcheck disable=SC1090
	. "$env_file"
	set +a
}

# Fail early, naming every missing variable at once.
require_vars() {
	local name missing=()
	for name in "$@"; do
		[ -n "${!name:-}" ] || missing+=("$name")
	done
	[ "${#missing[@]}" -eq 0 ] || die "set in .env: ${missing[*]}"
}

# `docker compose` for this stack, from any working directory.
compose() {
	docker compose --project-directory "$STACK_DIR" -f "$STACK_DIR/docker-compose.yml" "$@"
}
