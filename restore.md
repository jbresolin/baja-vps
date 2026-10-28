# Restoring Evolution from a backup

How to put a `backup.sh` backup back into this stack, on the same VPS or on
a fresh one. It is the migration procedure (README §4.4–§4.7) with the
backup as the source instead of TrueNAS.

> **Golden rule (same as the migration):** never run two Evolutions with the
> same session at once, and never call `logout` or `delete` on the instance.
> Logout unlinks the device in WhatsApp, and then a QR scan is unavoidable.

## What a backup holds

`/var/backups/baja-evolution/evolution-<UTC timestamp>/` (`BACKUP_DIR`), made
daily by the systemd timer, kept 14 days (`BACKUP_KEEP_DAYS`):

| File | Store | Holds |
| --- | --- | --- |
| `evolution.dump` | Postgres (`pg_dump -Fc --no-owner --no-privileges`) | instance row, `Session` (WhatsApp `creds`), instance webhook, saved messages/contacts |
| `evolution.rdb` | Redis snapshot (all DBs) | every other Signal key (pre-keys, sessions, sender keys) |
| `evolution_instances.tgz` | `baja_evolution_instances` volume | per-instance files (only used when Redis is off) |
| `SHA256SUMS` | | checksums of the three |

These files contain the WhatsApp private keys. Treat them like a password.
Directories starting with `.` are incomplete runs; never restore from one.

**How stale is a restore?** Up to a day (one backup per day). Identity
(`creds`) rarely changes, so the session reconnects, but some chats may show
"waiting for this message" until keys renegotiate. That clears by itself
after messages flow. If you still have the live data, fix forward instead of
restoring.

## 0. Choose the backup and load the environment

As root on the VPS:

```bash
cd /opt/baja-vps
set -a; . ./.env; set +a
ls -1 "$BACKUP_DIR"
B="$BACKUP_DIR/evolution-<timestamp>"      # pick one
(cd "$B" && sha256sum -c SHA256SUMS)       # all three must say OK
```

On a fresh VPS, first do README §1–§3 (prep, `setup.sh`, `.env` with the
**same** `EVOLUTION_*` values as the old one), copy the backup directory to
the new box (`scp -r`), and set `B` to where it landed.

## 1. Stop Evolution

```bash
docker compose stop evolution
docker compose ps evolution        # must show it exited / not running
```

Postgres and Redis keep running for now.

## 2. Postgres: replace the database

The dump replaces everything Evolution stored. Drop and recreate the
database, then restore into it:

```bash
docker compose cp "$B/evolution.dump" postgres:/tmp/evolution.dump
docker compose exec postgres sh -c 'dropdb -U "$POSTGRES_USER" --force "$POSTGRES_DB" && createdb -U "$POSTGRES_USER" "$POSTGRES_DB"'
docker compose exec postgres sh -c 'pg_restore -U "$POSTGRES_USER" -d "$POSTGRES_DB" --no-owner --no-privileges /tmp/evolution.dump'
docker compose exec postgres rm /tmp/evolution.dump
docker compose exec postgres sh -c "psql -U \"\$POSTGRES_USER\" -d \"\$POSTGRES_DB\" -c 'SELECT id, name, \"clientName\" FROM \"$EVOLUTION_DB_SCHEMA\".\"Instance\";'"
```

The last command must show the Baja Bot instance, with `clientName` equal to
`EVOLUTION_CLIENT_NAME`. Note its `id`:

```bash
INSTANCE_ID=<id from the row above>
```

A `schema "public" already exists` complaint from `pg_restore` is harmless.

## 3. Redis: replace the data (RDB, then switch AOF on live)

Our Redis runs with `appendonly yes`. If it starts with AOF on and AOF files
present, it ignores `dump.rdb`. So: stop it, wipe its data, load the RDB with
AOF off, switch AOF on live, then start the normal container. This is the
procedure Redis documents for moving from RDB to AOF.

```bash
docker compose stop redis
docker run --rm -v baja_redis_data:/data -v "$B":/backup:ro alpine:3.22 \
  sh -c 'rm -rf /data/appendonlydir /data/dump.rdb && cp /backup/evolution.rdb /data/dump.rdb'
docker run -d --name redis-import -v baja_redis_data:/data redis:8.10.2-alpine redis-server --appendonly no
docker exec redis-import redis-cli -n "$EVOLUTION_REDIS_DB" HLEN "$EVOLUTION_REDIS_PREFIX:instance:$INSTANCE_ID"
docker exec redis-import redis-cli CONFIG SET appendonly yes
docker exec redis-import redis-cli INFO persistence | grep -E 'aof_rewrite_in_progress|aof_rewrite_scheduled|aof_last_bgrewrite_status'
```

`HLEN` should be in the hundreds (zero means Redis was off on the source and
the keys are in the instances archive, step 4). Repeat the last command until
both `*_in_progress` and `*_scheduled` are `0` and the status is `ok`. Then:

```bash
docker exec redis-import redis-cli SHUTDOWN
docker rm redis-import
docker compose up -d redis
docker compose exec redis redis-cli -n "$EVOLUTION_REDIS_DB" HLEN "$EVOLUTION_REDIS_PREFIX:instance:$INSTANCE_ID"
```

The second `HLEN` must equal the first.

## 4. Instances volume

```bash
docker run --rm -v baja_evolution_instances:/evolution/instances -v "$B":/backup:ro alpine:3.22 \
  sh -c 'find /evolution/instances -mindepth 1 -delete && tar -C /evolution/instances -xzf /backup/evolution_instances.tgz'
docker run --rm -v baja_evolution_instances:/evolution/instances alpine:3.22 ls -la /evolution/instances
```

## 5. Start Evolution and verify

```bash
docker compose up -d evolution
docker compose logs -f evolution         # Ctrl-C once instances have loaded
```

**Do not open the Manager and do not click "connect"/QR.** Then:

```bash
sudo ./smoke.sh
```

`evolution instance …: open` must pass. If it doesn't, work through README
§4.8 ("If the state is not open"). The instance webhook came back with the
dump too; check it still points where it should (README §7):

```bash
curl -sS -H "apikey: $EVOLUTION_API_KEY" "http://$TAILSCALE_IP:8081/webhook/find/$EVOLUTION_INSTANCE" ; echo
```

## 6. Afterwards

If you copied a backup to another machine to do this, delete that copy when
done: it holds the session keys.
