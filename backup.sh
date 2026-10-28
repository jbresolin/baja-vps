#!/usr/bin/env bash
# Back up the Evolution WhatsApp session: the same three stores the
# migration copies (README §4), taken from the running stack.
#
#   evolution.dump           Postgres, pg_dump custom format (creds, instance, webhook)
#   evolution.rdb            Redis snapshot (every other Signal key)
#   evolution_instances.tgz  the /evolution/instances volume
#   SHA256SUMS
#
# Each run writes $BACKUP_DIR/evolution-<UTC timestamp>/. It is built in a
# hidden .partial directory and renamed only when complete, so a directory
# without the dot is always a whole backup. Backups older than
# BACKUP_KEEP_DAYS are pruned, but only after a successful run.
# Run daily by systemd/baja-evolution-backup.timer. Restore: restore.md.
set -euo pipefail

STACK_DIR="${STACK_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
# shellcheck source=lib/common.sh
. "$STACK_DIR/lib/common.sh"

INSTANCES_VOLUME=baja_evolution_instances
HELPER_IMAGE=alpine:3.22

# Logical dump inside the container, as the DB owner. Same flags as the
# migration, so a backup restores exactly like the TrueNAS dump did.
# The variables expand inside the container, hence the single quotes.
# shellcheck disable=SC2016
dump_postgres() {
	compose exec -T postgres sh -c \
		'pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc --no-owner --no-privileges' >"$1"
}

# Consistent RDB over the replication protocol; Redis keeps serving.
snapshot_redis() {
	compose exec -T redis redis-cli --rdb /tmp/backup.rdb >/dev/null
	compose cp redis:/tmp/backup.rdb "$1"
	compose exec -T redis rm -f /tmp/backup.rdb
}

# Read-only tar of the volume from a throwaway container, so it works even
# while Evolution is stopped.
archive_instances() {
	docker run --rm -v "$INSTANCES_VOLUME:/src:ro" "$HELPER_IMAGE" tar -C /src -czf - . >"$1"
}

# "20260131T033000Z" -> epoch seconds; empty output if the name is not a stamp.
stamp_to_epoch() {
	local s="$1"
	[[ "$s" =~ ^[0-9]{8}T[0-9]{6}Z$ ]] || return 0
	date -u -d "${s:0:4}-${s:4:2}-${s:6:2} ${s:9:2}:${s:11:2}:${s:13:2}" +%s 2>/dev/null || true
}

# Delete complete backups older than $keep_days, and leftovers of crashed
# runs. Anything whose name does not parse is left alone.
prune_backups() {
	local dir="$1" keep_days="$2" now="$3"
	local cutoff=$((now - keep_days * 86400))
	local path name epoch
	for path in "$dir"/evolution-*/; do
		[ -d "$path" ] || continue
		name="$(basename "$path")"
		epoch="$(stamp_to_epoch "${name#evolution-}")"
		if [ -n "$epoch" ] && [ "$epoch" -lt "$cutoff" ]; then
			rm -rf "$path"
			log "pruned $name"
		fi
	done
	# This run's own .partial was already renamed, so any left are stale.
	for path in "$dir"/.evolution-*.partial/; do
		[ -d "$path" ] || continue
		rm -rf "$path"
		log "removed incomplete $(basename "$path")"
	done
}

main() {
	require_root
	load_env
	local backup_dir="${BACKUP_DIR:-/var/backups/baja-evolution}"
	local keep_days="${BACKUP_KEEP_DAYS:-14}"
	[[ "$keep_days" =~ ^[1-9][0-9]*$ ]] || die "BACKUP_KEEP_DAYS must be a whole number of days >= 1"

	# BACKUP_NOW (epoch seconds) is a test hook for the retention maths.
	local now="${BACKUP_NOW:-$(date -u +%s)}"
	local stamp
	stamp="$(date -u -d "@$now" +%Y%m%dT%H%M%SZ)"
	local final="$backup_dir/evolution-$stamp"
	local work="$backup_dir/.evolution-$stamp.partial"
	[ ! -e "$final" ] || die "$final already exists"

	umask 077
	mkdir -p "$work"
	chmod 700 "$backup_dir"
	# On any failure the half-written directory goes; old backups stay.
	# (Expanded now: $work is local and the trap may fire outside main.)
	# shellcheck disable=SC2064
	trap "rm -rf '$work'" EXIT

	log "postgres -> evolution.dump"
	dump_postgres "$work/evolution.dump"
	log "redis -> evolution.rdb"
	snapshot_redis "$work/evolution.rdb"
	log "instances volume -> evolution_instances.tgz"
	archive_instances "$work/evolution_instances.tgz"

	local f
	for f in evolution.dump evolution.rdb evolution_instances.tgz; do
		[ -s "$work/$f" ] || die "$f is empty"
	done
	(cd "$work" && sha256sum evolution.dump evolution.rdb evolution_instances.tgz >SHA256SUMS)

	mv "$work" "$final"
	trap - EXIT
	log "backup complete: $final ($(du -sh "$final" | cut -f1))"

	prune_backups "$backup_dir" "$keep_days" "$now"
}

main "$@"
