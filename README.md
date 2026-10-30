# Baja staging VPS: base stack (Caddy + Evolution)

The **always-on** layer of the Baja staging VPS (Ubuntu, 2 vCPU, 4 GB RAM,
70 GB disk). It owns the ports, TLS and the WhatsApp gateway. Everything
else plugs into it:

* **Scoring app staging**: `tiagomartines11/baja-sae-brasil-online`,
  `baja-infra/docker-compose.yml`, nginx container `baja-nginx`.
* **Video pipeline**: `jbresolin/baja-video-pipeline`, `infra/vps/`
  (orchestrator, review UI). Seasonal: it may be absent off-season.

Copy-paste runbook. You run every command yourself, as root on the VPS
(`sudo -i`) unless it says TrueNAS.

| File | What it is |
| --- | --- |
| `docker-compose.yml` | Caddy (custom build), Evolution API v2.3.7, its Postgres and Redis |
| `caddy/Dockerfile` | Caddy 2.11.7 + `caddy-dns/cloudflare` v0.2.4 (DNS-01 for staging) |
| `caddy/cloudflare-ips.env` | Cloudflare's IP ranges: `trusted_proxies` and the staging gate. `caddy/refresh-cloudflare-ips.sh` refreshes it (§5.3) |
| `Caddyfile` | Global options, shared snippets, `import /srv/caddy/conf.d/*.caddy`, the tailnet-only Evolution site |
| `conf.d/staging.caddy` | Scoring staging vhosts, Cloudflare-only → `baja-nginx:80` (installed by `setup.sh --enable-staging`) |
| `.env.example` | Every variable, with comments. Copy to `.env` |
| `setup.sh` | Creates `baja-edge`, the directories, fixes `.env` permissions; switches the staging vhosts |
| `backup.sh`, `systemd/` | Daily Evolution backup, 14-day retention |
| `restore.md` | Restoring a backup |
| `smoke.sh` | Read-only health check of this stack |
| `lib/common.sh` | Helpers shared by the scripts |
| `tests/` | Script tests (`python3 -m unittest discover -s tests`) |

```
  Cloudflare (orange) │  internet (grey)                   tailnet (100.x)
            │ 80/443   │                                :8081 │   │ :8080
   ┌────────▼──────────▼────────── VPS ───────────────────────▼───▼────┐
   │  caddy  (only container with published ports)                     │
   │   ├─ conf.d/staging.caddy  {BAJA_DOMAIN} + 6 subdomains,          │
   │   │   Cloudflare-only      {FORMULA_DOMAIN} ──────► baja-nginx:80 │
   │   ├─ conf.d/<pipeline>.caddy  (open; + :8080) ───► orchestrator   │
   │   └─ http://:8081 (TAILSCALE_IP only) ───────────► evolution:8080 │
   │                                                       │           │
   │  ════════════════ baja-edge (external network) ═══════╪═════════  │
   │                                                       │           │
   │  evolution ── instance webhook ─► orchestrator:8000   │ evolution_db
   │                                                       ├─ postgres │
   │                                                       └─ redis    │
   └───────────────────────────────────────────────────────────────────┘
```

## Conventions (fixed; other stacks rely on them)

| Thing | Value |
| --- | --- |
| Shared Docker network | `baja-edge`, external, created by `setup.sh`, subnet **`10.201.0.0/24`, fixed** (§2.3). All three stacks depend on it |
| Caddy container | `caddy`. Publishes host 80, 443, 443/udp; `TAILSCALE_IP:8080` and `TAILSCALE_IP:8081` |
| Site files | `/srv/caddy/conf.d/*.caddy`, one per stack |
| Evolution | service `evolution`, port 8080, on `baja-edge` (not published) |
| Scoring staging nginx | `baja-nginx:80` on `baja-edge` |
| Tailnet ports | 8080 = pipeline worker API, 8081 = Evolution API/Manager |
| Checkout | `/opt/baja-vps` (the systemd unit points there) |

## Key decisions

* **Evolution has no public route.** The Manager and API are reachable
  only on the VPS's Tailscale IP, port 8081 (plain HTTP over WireGuard,
  same model as the pipeline's worker API). Consumers on the server talk to
  `http://evolution:8080` over `baja-edge`.
* **The WhatsApp session is spread over three stores**: Postgres
  (`"Session"` = `creds`), a Redis hash with every other Signal key, and the
  `/evolution/instances` volume. Migration and backups copy all three, and
  the prefix, DB index, schema and client name must stay identical. Details
  in §4. (Moved unchanged from the pipeline runbook, with its references.)
* **Volume names are pinned** to what the pipeline's combined stack created
  (`baja_postgres_data`, `baja_redis_data`, `baja_evolution_instances`,
  `baja_caddy_data`, `baja_caddy_config`), under a new project name
  `baja-base`. A VPS that ran the old stack keeps its session and
  certificates (§4.10).
* **Staging is Cloudflare-only; the pipeline is open.** The staging
  hostnames are Cloudflare-proxied: Caddy accepts them only from Cloudflare's
  ranges (403 for anyone else), passes `CF-Connecting-IP` through unchanged,
  and gets their certificates with DNS-01 through the Cloudflare API (§5.3).
  The pipeline's hostnames are DNS-only (grey), open to everyone, and use
  ordinary HTTP-01 (§6).
* **`baja-edge` is `10.201.0.0/24`, always.** Staging nginx trusts that range
  for `CF-Connecting-IP`, and the pipeline orchestrator trusts it for
  `X-Forwarded-For`. Both treat it as "the proxy", so it never changes on
  one stack alone.

---

## 1. Fresh VPS preparation

### 1.1 Docker

Install Docker Engine and the Compose plugin from Docker's apt repository,
following https://docs.docker.com/engine/install/ubuntu/ ("Install using the
apt repository"). Then check:

```bash
docker compose version      # must be >= 2.24 (optional env_file, `!reset`)
```

### 1.2 Tailscale

Install from Tailscale's apt repository
(https://tailscale.com/kb/1031/install-linux, "Manual install" → Ubuntu),
and join the Baja tailnet as `tag:server` as described in the pipeline repo,
`infra/tailnet/`. Note the address:

```bash
tailscale ip -4             # -> TAILSCALE_IP in .env
```

### 1.3 Kernel settings, swap, journald

`ip_nonlocal_bind` lets Docker bind Caddy's tailnet ports to the Tailscale
IP even if `tailscaled` has not brought the IP up yet at boot. Without it
Caddy fails to start with "cannot assign requested address".

```bash
printf 'vm.swappiness=10\nnet.ipv4.ip_nonlocal_bind=1\n' | tee /etc/sysctl.d/90-baja.conf
sysctl --system
```

**Swap: 2 GiB.** Containers can't use it (`memswap_limit = mem_limit`, so a
leaking container is OOM-killed and restarted, not slowly swapped). It
absorbs host-side spikes (apt, dockerd, image pulls).

```bash
fallocate -l 2G /swapfile
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile
echo '/swapfile none swap sw 0 0' | tee -a /etc/fstab
```

Cap the system journal:

```bash
mkdir -p /etc/systemd/journald.conf.d
printf '[Journal]\nSystemMaxUse=500M\n' | tee /etc/systemd/journald.conf.d/90-baja.conf
systemctl restart systemd-journald
```

### 1.4 Firewall

Docker-published ports bypass ufw. That's acceptable because only Caddy
publishes (80/443 public; 8080/8081 on the Tailscale IP only). Close
everything else on the host:

```bash
ufw default deny incoming
ufw allow OpenSSH
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 443/udp
ufw allow in on tailscale0
ufw enable
```

Also allow 80/443 in the VPS provider's firewall, if it has one.

---

## 2. Checkout, `.env`, `setup.sh`

### 2.1 Checkout

```bash
git clone https://github.com/jbresolin/baja-vps.git /opt/baja-vps
cd /opt/baja-vps
```

All later commands run from `/opt/baja-vps`.

### 2.2 `.env`

```bash
cp .env.example .env
chmod 600 .env
openssl rand -hex 24      # once per secret: POSTGRES_PASSWORD
docker run --rm caddy:2.11.7-alpine caddy hash-password --plaintext 'manager-password'
nano .env                 # fill in; the bcrypt hash goes in SINGLE quotes
```

If you are migrating from TrueNAS, the `[MATCH TRUENAS]` values come from
§4.1. If the VPS already runs the pipeline's combined stack, copy them from
its `.env` (§4.10). Validate; this must print nothing:

```bash
docker compose config -q
```

### 2.3 `setup.sh`

```bash
./setup.sh
```

It creates (and on re-runs only checks):

* the `baja-edge` network with subnet **`10.201.0.0/24`**. The subnet is fixed,
  not an `.env` setting, because all three stacks depend on it:
  * staging nginx: `set_real_ip_from 10.201.0.0/24` (§5.2);
  * the pipeline orchestrator: `BVP_TRUSTED_PROXY_CIDRS` includes
    `10.201.0.0/24` (pipeline repo, `infra/vps/README.md` §9). Its own
    `pipeline` network is `10.202.0.0/24`;
  * this stack: Caddy's address on it is what both of them trust.

  Before creating it, `setup.sh` checks `ip -4 route show table all` and
  every Docker network's subnets, and **refuses** if anything overlaps
  `10.201.0.0/24` (it names the clash). Free that range (remove the Docker
  network, or the VPN/route using it); moving `baja-edge` instead would mean
  changing all three stacks together. If `baja-edge` already exists with
  another subnet, it refuses too and leaves it alone (recreating it would
  detach every running stack; §11 has the maintenance-window procedure).
  An old `.env` that still sets `BAJA_EDGE_SUBNET` to anything else is
  refused; delete that line;
* `/srv/caddy/conf.d` (root, 755);
* `/srv/pipeline`, **only if missing**, empty and root-owned, so Caddy's
  read-only mount has a target off-season. The pipeline's own install takes
  it over (uid 10001, mode 750). An existing one is never touched;
* `BACKUP_DIR` (root, 700);
* and sets `.env` to mode 600.

---

## 3. Bring up the stack

```bash
docker compose pull --ignore-buildable
docker compose build caddy        # caddy/Dockerfile: Caddy + Cloudflare DNS plugin
docker compose up -d caddy
docker compose logs caddy | grep -iE 'error|certificate obtained'
```

Caddy is built here, not pulled: the staging certificates need the
`caddy-dns/cloudflare` plugin (§5.3). The image is tagged
`baja-caddy:2.11.7-cf0.2.4`; both versions are pinned in `caddy/Dockerfile`.
To upgrade, bump them there and the tag in `docker-compose.yml`, then
`docker compose build caddy && docker compose up -d caddy`.

Validate the whole config (this file + every conf.d file) with the built
image at any time:

```bash
docker exec caddy caddy validate --config /etc/caddy/Caddyfile
```

Then, depending on where Evolution's data comes from:

* **Migrating from TrueNAS**: do §4 now. It starts Postgres, Redis and
  Evolution itself, in the right order. Do **not** run `docker compose up -d`
  before it: an empty Evolution must not start against the empty databases
  and then get migrated data underneath it.
* **The VPS already runs the pipeline's combined stack**: §4.10.
* **Brand-new bot with no session to keep**: `docker compose up -d`, then
  create the instance and scan the QR in the Manager (§4.8 has the URL).

When everything is up: `./smoke.sh` (§10).

---

## 4. Evolution migration from TrueNAS

Moves the **Baja Bot** Evolution instance from the TrueNAS box at home to
this stack **without re-scanning the QR code**. Ported from the pipeline
repo's `infra/vps/README.md` (§1, §3, §4, §9 there); only paths and URLs
changed.

Before starting: §1–§3 done (Caddy running), SSH access to TrueNAS (shell
with `sudo docker`), and a maintenance window of about 30 minutes. During it
the bot neither receives nor answers. WhatsApp queues incoming messages and
delivers them on reconnect.

> **Golden rule:** the old and the new Evolution must **never run at the same
> time** with the same session, and you must **never call logout or delete**
> on the instance (on either side). Logout unlinks the device in WhatsApp,
> and then a QR scan is unavoidable [R9].

### 4.1 Pre-flight on TrueNAS (read-only, do it days before)

**a. Find the containers and their storage**

```bash
sudo docker ps -a --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}' | grep -Ei 'evolution|postgres|redis'
```

Set these for the rest of the session (use your actual names):

```bash
EVO_C=evolution_api        # Evolution API container
PG_C=evolution_postgres    # its Postgres
REDIS_C=evolution_redis    # its Redis
```

Write down mounts and the restart policy (needed for rollback):

```bash
for c in "$EVO_C" "$PG_C" "$REDIS_C"; do echo "== $c"; sudo docker inspect "$c" --format 'restart={{.HostConfig.RestartPolicy.Name}}{{println}}{{range .Mounts}}{{.Type}} {{.Source}} -> {{.Destination}}{{println}}{{end}}'; done
```

Evolution's instance data is mounted at `/evolution/instances` [R10].
Check whether Postgres/Redis are **shared with other apps**. The procedure
never stops them and only copies Evolution's data, so sharing is fine. Just
know it.

**b. Record the values that must match on the VPS**

The process environment overrides the defaults baked into the image at
`/evolution/.env`. Read both:

```bash
sudo docker inspect "$EVO_C" --format '{{range .Config.Env}}{{println .}}{{end}}' | grep -E '^(SERVER_URL|AUTHENTICATION_API_KEY|DATABASE_|CACHE_|PROVIDER_|CONFIG_SESSION_)' | sort
sudo docker exec "$EVO_C" sh -c 'grep -E "^(DATABASE_CONNECTION_CLIENT_NAME|CACHE_REDIS_PREFIX_KEY|CACHE_REDIS_URI|CACHE_REDIS_SAVE_INSTANCES|PROVIDER_ENABLED)=" /evolution/.env'
```

Copy into the VPS `.env` (marked `[MATCH TRUENAS]` in `.env.example`):

| TrueNAS variable | VPS `.env` |
| --- | --- |
| `AUTHENTICATION_API_KEY` | `EVOLUTION_API_KEY` |
| `DATABASE_CONNECTION_CLIENT_NAME` | `EVOLUTION_CLIENT_NAME` |
| `?schema=` of `DATABASE_CONNECTION_URI` | `EVOLUTION_DB_SCHEMA` |
| `/N` at the end of `CACHE_REDIS_URI` | `EVOLUTION_REDIS_DB` |
| `CACHE_REDIS_PREFIX_KEY` (code default `evolution-cache` [R11]) | `EVOLUTION_REDIS_PREFIX` |
| `CACHE_REDIS_SAVE_INSTANCES` | `EVOLUTION_REDIS_SAVE_INSTANCES` |
| `CONFIG_SESSION_PHONE_CLIENT` / `_NAME` | `EVOLUTION_PHONE_CLIENT` / `_NAME` |

Also note the user/password/db name inside `DATABASE_CONNECTION_URI`
(needed for `pg_dump`):

```bash
PGU=<user from URI>; PGD=<db from URI>; SCHEMA=<schema from URI>
EVO_KEY=<AUTHENTICATION_API_KEY>; EVO_NAME=<instance name>
```

**Stop conditions.** These setups are not covered here. Stop and plan
separately if any applies: `DATABASE_PROVIDER` is not `postgresql`,
`PROVIDER_ENABLED=true`, or the Evolution version (next step) is 1.x.

**c. Versions**

```bash
sudo docker exec "$EVO_C" wget -qO- http://127.0.0.1:8080/ ; echo
sudo docker exec "$PG_C" postgres --version
sudo docker exec "$REDIS_C" redis-server --version
```

* Evolution **2.x older than 2.3.7**: fine. The new container runs Prisma
  migrations on start [R12]. The TrueNAS DB is only *dumped*, never
  migrated, so rollback stays possible.
* Postgres: the VPS major (`postgres:15.19-alpine`) must be **≥** TrueNAS's.
  If TrueNAS is on 16/17, change the image in `docker-compose.yml` first.
* Redis: the VPS (`redis:8.10.2-alpine`) must be **≥** TrueNAS's, so it can
  load the snapshot.

**d. Record the instance and the key counts**

```bash
sudo docker exec "$PG_C" psql -U "$PGU" -d "$PGD" -c "SELECT id, name, \"connectionStatus\", \"clientName\", token FROM \"$SCHEMA\".\"Instance\";"
sudo docker exec "$PG_C" psql -U "$PGU" -d "$PGD" -c "SELECT \"sessionId\", length(creds) FROM \"$SCHEMA\".\"Session\";"
sudo docker exec "$EVO_C" wget -qO- --header "apikey: $EVO_KEY" "http://127.0.0.1:8080/webhook/find/$EVO_NAME" ; echo
```

* `id` = the instance id (`INSTANCE_ID=<id>`). `name` → `EVOLUTION_INSTANCE`
  in this `.env` (and `BVP_EVOLUTION_INSTANCE` in the pipeline's).
* `token` = the instance token. The pipeline needs it as
  `BVP_EVOLUTION_API_KEY` in its own `.env`; this stack doesn't use it.
* The webhook JSON [R13] is the old consumer's config. It comes over with
  Postgres and gets replaced in §4.7. Just keep a copy.

Count the Redis keys for this instance (compare after the restore):

```bash
REDIS_DB=<N>; REDIS_PREFIX=<prefix>
sudo docker exec "$REDIS_C" redis-cli -n "$REDIS_DB" --scan --pattern "*$INSTANCE_ID*" | wc -l
sudo docker exec "$REDIS_C" redis-cli -n "$REDIS_DB" HLEN "$REDIS_PREFIX:instance:$INSTANCE_ID"
```

(Add `-a <password>` to `redis-cli` if TrueNAS's Redis has one.) With
`CACHE_REDIS_ENABLED=true` and `SAVE_INSTANCES=false`, `HLEN` should be in
the hundreds. Zero means the keys are in files under
`/evolution/instances/<id>/` (Redis disabled), and those are copied too.

### 4.2 Cutover starts. TrueNAS: stop the old Evolution for good

Expected downtime: about 15 minutes. Run §4.2–§4.7 back to back.

```bash
sudo docker update --restart=no "$EVO_C"
sudo docker stop "$EVO_C"
sudo docker ps --filter "name=$EVO_C"      # must list nothing
```

If Evolution is a TrueNAS **App**, also stop the app in the UI, so the
middleware doesn't restart it. If that stops its Postgres/Redis too, start
just those two again: `sudo docker start "$PG_C" "$REDIS_C"`. Only the API
container must stay down.

### 4.3 TrueNAS: export the three stores and transfer them

```bash
mkdir -p ~/evo-migration
cd ~/evo-migration
# (a) Postgres: logical dump of Evolution's DB (Session, Instance, Webhook, ... tables)
sudo docker exec "$PG_C" pg_dump -U "$PGU" -d "$PGD" -Fc --no-owner --no-privileges -f /tmp/evolution.dump
sudo docker cp "$PG_C":/tmp/evolution.dump ./evolution.dump
# (b) Redis: consistent RDB snapshot over the replication protocol (doesn't stop Redis)
sudo docker exec "$REDIS_C" redis-cli --rdb /tmp/evolution.rdb
sudo docker cp "$REDIS_C":/tmp/evolution.rdb ./evolution.rdb
# (c) Instances volume (works on a stopped container)
sudo docker cp "$EVO_C":/evolution/instances ./instances
sudo tar -C ./instances -czf evolution_instances.tgz .
sha256sum evolution.dump evolution.rdb evolution_instances.tgz | tee SHA256SUMS
scp evolution.dump evolution.rdb evolution_instances.tgz SHA256SUMS root@<vps>:/root/evo-migration/
```

(Create `/root/evo-migration` on the VPS first: `mkdir -m 700 /root/evo-migration`.)
These files contain the WhatsApp private keys. Treat them like a password.

### 4.4 VPS: verify and restore Postgres

```bash
cd /root/evo-migration
sha256sum -c SHA256SUMS
cd /opt/baja-vps
set -a; . ./.env; set +a
INSTANCE_ID=<id from §4.1d>
docker compose up -d postgres
docker compose cp /root/evo-migration/evolution.dump postgres:/tmp/evolution.dump
docker compose exec postgres sh -c 'pg_restore -U "$POSTGRES_USER" -d "$POSTGRES_DB" --no-owner --no-privileges /tmp/evolution.dump'
docker compose exec postgres sh -c "psql -U \"\$POSTGRES_USER\" -d \"\$POSTGRES_DB\" -c 'SELECT id, name, \"clientName\" FROM \"$EVOLUTION_DB_SCHEMA\".\"Instance\";'"
```

Keep this shell open until §4.8; later steps use the loaded variables. The
row must show the same `id` and `clientName` as in §4.1d. If `pg_restore`
only complains that `schema "public" already exists`, that is harmless.

### 4.5 VPS: restore Redis (RDB → AOF the safe way)

Our Redis runs with `appendonly yes`. If Redis starts with AOF enabled and
no AOF files present, it ignores `dump.rdb`. So load the RDB with AOF off,
then switch AOF on *live*. That's the procedure Redis documents [R15]:

```bash
docker run --rm -v baja_redis_data:/data -v /root/evo-migration:/backup alpine:3.22 cp /backup/evolution.rdb /data/dump.rdb
docker run -d --name redis-import -v baja_redis_data:/data redis:8.10.2-alpine redis-server --appendonly no
docker exec redis-import redis-cli -n "$EVOLUTION_REDIS_DB" HLEN "$EVOLUTION_REDIS_PREFIX:instance:$INSTANCE_ID"
docker exec redis-import redis-cli CONFIG SET appendonly yes
docker exec redis-import redis-cli INFO persistence | grep -E 'aof_rewrite_in_progress|aof_rewrite_scheduled|aof_last_bgrewrite_status'
```

Repeat the last command until both `*_in_progress` and `*_scheduled` are `0`
and the status is `ok`. Then:

```bash
docker exec redis-import redis-cli SHUTDOWN
docker rm redis-import
docker compose up -d redis
docker compose exec redis redis-cli -n "$EVOLUTION_REDIS_DB" HLEN "$EVOLUTION_REDIS_PREFIX:instance:$INSTANCE_ID"
```

The `HLEN` must equal the TrueNAS number from §4.1d.

### 4.6 VPS: restore the instances volume

```bash
docker run --rm -v baja_evolution_instances:/evolution/instances -v /root/evo-migration:/backup alpine:3.22 tar -C /evolution/instances -xzf /backup/evolution_instances.tgz
docker run --rm -v baja_evolution_instances:/evolution/instances alpine:3.22 ls -la /evolution/instances
```

### 4.7 VPS: start Evolution, retire the old webhook

```bash
docker compose up -d evolution
docker compose logs -f evolution
```

Expect the Prisma migrations (if TrueNAS was older), then the instance
loading. **Do not open the Manager and do not click "connect"/QR.**

The instance webhook came over in Postgres, still pointing at the old
consumer. Nothing listens there any more, and Evolution would retry every
event against it. If the pipeline's orchestrator is **already running** on
`baja-edge`, skip this and point the webhook at it (§7.2). Otherwise disable
it until it is:

```bash
curl -sS -X POST "http://$TAILSCALE_IP:8081/webhook/set/$EVOLUTION_INSTANCE" \
  -H "apikey: $EVOLUTION_API_KEY" -H 'content-type: application/json' \
  -d '{"webhook":{"enabled":false,"url":"http://orchestrator:8000/intake/evolution-webhook","byEvents":false,"base64":false,"events":[]}}'
```

The body is **nested under `"webhook"`** with `byEvents`/`base64`. That's
what v2.3.7 validates [R16]. The docs page shows a flat body [R13], which is
wrong for this version. `url` is required even when disabled.

(`http://$TAILSCALE_IP:8081` works from the VPS itself and from any tailnet
device.)

### 4.8 Verify: connected without a QR

```bash
curl -sS -H "apikey: $EVOLUTION_API_KEY" "http://$TAILSCALE_IP:8081/instance/connectionState/$EVOLUTION_INSTANCE" ; echo
```

Must be `{"instance":{"instanceName":"…","state":"open"}}` [R17]. Then:

1. Phone of the Baja Bot number → *Linked devices*. The **same** device
   entry as before ("Evolution API"/Chrome), with recent activity and **no
   new device**.
2. Send a test message from the bot [R18]:
   ```bash
   curl -sS -X POST "http://$TAILSCALE_IP:8081/message/sendText/$EVOLUTION_INSTANCE" \
     -H "apikey: $EVOLUTION_API_KEY" -H 'content-type: application/json' \
     -d '{"number":"55XXXXXXXXXXX","text":"VPS migration test"}'
   ```
3. Reply to the bot from that phone, then check that the reply was received
   **and decrypted**. It is stored, because `DATABASE_SAVE_DATA_NEW_MESSAGE=true`:
   ```bash
   docker compose exec postgres sh -c "psql -U \"\$POSTGRES_USER\" -d \"\$POSTGRES_DB\" -c 'SELECT \"messageType\", \"pushName\", to_timestamp(\"messageTimestamp\") FROM \"$EVOLUTION_DB_SCHEMA\".\"Message\" ORDER BY \"messageTimestamp\" DESC LIMIT 3;'"
   ```
   Your reply should be the top row with a real type (`conversation`,
   `extendedTextMessage`), and Evolution's logs should show no `Bad MAC`.
4. Reachability: tailnet only.
   ```bash
   curl -sS -o /dev/null -w '%{http_code}\n' "http://$TAILSCALE_IP:8081/"                 # 401 (no apikey header)
   curl -sS -o /dev/null -w '%{http_code}\n' "http://$TAILSCALE_IP:8081/manager"          # 401 (basic auth)
   curl -sS -m 5 -o /dev/null -w '%{http_code}\n' "http://<vps-public-ip>:8081/"          # must time out / refuse
   ```
   Manager UI, from a tailnet device: `http://<TAILSCALE_IP>:8081/manager`.
   First the basic auth, then Evolution's own login with the API key.
5. `./smoke.sh` (§10).

**If the state is not `open` (`close`/`connecting`, or a QR appears):**

* `fetchInstances` [R19] is empty → `EVOLUTION_CLIENT_NAME` or
  `EVOLUTION_DB_SCHEMA` doesn't match. Fix `.env`, `docker compose up -d evolution`.
* The instance exists but the keys are missing → `EVOLUTION_REDIS_DB`/`_PREFIX`
  mismatch, or §4.5 skipped. Fix it and restart.
* Make sure the TrueNAS container is really down (§4.2). Two live copies
  conflict.
* After 15 minutes without progress → rollback (§4.9). Scanning a new QR is
  the last resort, not a fix. It also works with the same number, but it
  creates a new linked device.

### 4.9 Rollback

Keep the TrueNAS stack **stopped, not deleted**, for at least two weeks. Its
database was only dumped, never migrated, so the old image still matches it.

**Clean rollback** (VPS never reached `open`, or only for minutes):

```bash
# VPS
docker compose stop evolution
# TrueNAS (restore the restart policy you recorded in §4.1a)
sudo docker update --restart=unless-stopped "$EVO_C"
sudo docker start "$EVO_C"
sudo docker exec "$EVO_C" wget -qO- --header "apikey: $EVO_KEY" "http://127.0.0.1:8080/instance/connectionState/$EVO_NAME" ; echo
```

Restart the TrueNAS app in the UI if it is one.

**Late rollback** (VPS ran connected for hours or days): the Signal session
state on TrueNAS is now stale. It usually reconnects, because the identity
(`creds`) didn't change, but some chats may show "waiting for this message"
until keys renegotiate. Prefer fixing forward on the VPS. If you must go
back and it won't connect, re-link with a QR on TrueNAS. Same number, new
linked device.

Never do either rollback while both sides are running, and never use
`logout`/`delete` to "reset" (golden rule).

**Cleanup after success** (after the two-week window): delete
`~/evo-migration` on TrueNAS and `/root/evo-migration` on the VPS. They
contain the session keys.

### 4.10 Handover from the pipeline's combined stack

Only if this VPS already runs Evolution from the pipeline repo
(`/opt/baja/infra/vps`, compose project `baja`). The data stays in the same
volumes; only the containers move. Do it **together with** deploying the
pipeline's split compose (the one that joins `baja-edge` and no longer
defines Evolution/Caddy), because the old orchestrator sits on the old
project's network and can't reach the new Evolution.

1. Fill this stack's `.env` from the old one. Same names: `TAILSCALE_IP`,
   `ACME_EMAIL`, `MANAGER_BASIC_AUTH_*`, `EVOLUTION_*`, `POSTGRES_*`. Plus
   `EVOLUTION_INSTANCE` = the old `BVP_EVOLUTION_INSTANCE`. Then §2.3
   (`./setup.sh`).
2. Stop and remove the old containers. Named volumes are not removed by
   this:
   ```bash
   cd /opt/baja/infra/vps
   docker compose --profile orchestrator stop
   docker compose --profile orchestrator rm -f
   ```
3. Start this stack:
   ```bash
   cd /opt/baja-vps
   docker compose up -d
   ```
   Compose warns once per volume: `volume "baja_postgres_data" already
   exists but was created for project "baja" (expected "baja-base")`. That is
   expected; the existing volume is used.
4. Deploy the pipeline's split stack (its runbook), then check the instance
   webhook still points at `http://orchestrator:8000/…` (§7.2).
5. `./smoke.sh`. The old public `EVO_DOMAIN` site no longer exists; remove
   its DNS record.

The golden rule holds here too: step 2 stops the old Evolution before step 3
starts the new one.

---

## 5. Scoring staging vhosts

`conf.d/staging.caddy` serves every hostname the scoring repo's nginx
templates define (`server_name` in `baja-infra/nginx/templates/`), and
proxies them to `baja-nginx:80`:

`BAJA_DOMAIN`, `api.`, `certificado.`, `fila.`, `juiz.`, `resultados.`,
`forum.` + `BAJA_DOMAIN`, and `FORMULA_DOMAIN` (a whole hostname). Eight in
all.

No `www.`: no template has a `server_name` for it (it appears only in
`API_CORS_ORIGINS`). If the scoring repo adds one, add it to `staging.caddy`
and `smoke.sh` too.

All eight are **Cloudflare-proxied and Cloudflare-only** (§5.3). Caddy
terminates TLS; nginx sees plain HTTP. If `baja-nginx` is down, those
hostnames answer 502. That is accepted: nothing here depends on staging.

### 5.1 What the staging stack must change first

These are changes in the scoring repo (`baja-infra/`), not here. Until they
are made, enabling the vhosts gives 502s or redirect loops.

1. **Stop publishing host ports 80/443.** Its base compose publishes
   `80:80` on `nginx` (the prod overlay adds `443:443` and
   `/etc/letsencrypt`). Caddy owns 80/443 on this box. In a staging overlay:
   ```yaml
   services:
     nginx:
       ports: !reset []          # Compose >= 2.24
       networks: [baja, edge]
   networks:
     edge:
       name: baja-edge
       external: true
   ```
   `container_name: baja-nginx` is already set. Only nginx joins `baja-edge`.
2. **`LISTEN_MODE=listen-http`** in its `.env`. With `listen-tls`, nginx
   redirects port 80 to https and Caddy's proxied requests loop. Caveat:
   `LISTEN_MODE` also tells `Baja\Url` which scheme to put in links, so
   `listen-http` makes the app generate `http://` links. They still work
   (Caddy and Cloudflare redirect to https), but it is not right. The clean
   fix is a scoring-repo mode for "plain HTTP behind a TLS proxy" (listen 80,
   `https` links, `fastcgi_param HTTPS on`). Needs the owner's call.
3. **Trust Caddy for the client IP**: §5.2.

### 5.2 Client IP

The scoring nginx restores the client IP with its realip module: it reads
`CF-Connecting-IP`, but only from Cloudflare's address ranges
(`00-cloudflare-realip.conf.template`). Behind Caddy, nginx's TCP peer is
Caddy's address on `baja-edge`, so today it would ignore the header and see
**Caddy's IP for every visitor**: the API rate limiter would share one bucket
between everyone, and logs/bans would be useless.

What Caddy sends. Only Cloudflare can reach the proxy (the gate, §5.3), and
Caddy trusts Cloudflare's ranges (`trusted_proxies`), so `{client_ip}` is
the visitor. All of this is Caddy's default `reverse_proxy` behaviour;
`staging.caddy` only adds `X-Real-IP`:

| Header | What nginx gets |
| --- | --- |
| `Host` | unchanged |
| `CF-Connecting-IP` | **passed through unchanged**, as Cloudflare set it (the visitor). Nothing rewrites it |
| `X-Forwarded-For` | the full chain: Cloudflare's value with the Cloudflare edge address appended |
| `X-Forwarded-Proto` | Cloudflare's value (`https`) |
| `X-Real-IP` | overwritten with `{client_ip}`, so a client-sent value never arrives |

Verified locally with a Docker network inside a Cloudflare range: a request
from `173.245.48.10` with `CF-Connecting-IP: 198.51.100.7` reached the
upstream with that header unchanged, `X-Forwarded-For: 198.51.100.7,
173.245.48.10`, `X-Forwarded-Proto: https`. `./smoke.sh` checks on the box
that the header arrives (§10).

What nginx needs: one more line in `00-cloudflare-realip.conf.template`,
next to the Cloudflare ranges:

```nginx
# Caddy on the staging VPS (baja-edge, fixed subnet; base stack README §2.3).
set_real_ip_from 10.201.0.0/24;
```

Nothing else changes there: same header, and the Cloudflare ranges stay
for production. This is why `baja-edge` has a fixed subnet.

### 5.3 Cloudflare

**What I found** (public DNS, 2026-10-27): `bajasaebrasil.com.br` uses
Cloudflare nameservers, and the apex and `resultados.` resolve to Cloudflare
anycast addresses. So staging is **proxied by Cloudflare** ("orange cloud").
Every staging hostname, including `FORMULA_DOMAIN`, is treated as proxied.

**The gate.** On the staging vhosts only, a `remote_ip` matcher accepts
connections whose TCP peer is in Cloudflare's ranges; everything else gets
`403 Forbidden`, whatever headers it sends. `remote_ip` is the real peer,
not the header-derived client IP, so it can't be spoofed. Port 80 is
Caddy's automatic redirect to HTTPS for everyone; the gate applies on 443,
where the redirect leads.

**The ranges** are one list, `caddy/cloudflare-ips.env`
(`CLOUDFLARE_IPS=…`), loaded into the Caddy container and used both by the
gate and by the global `trusted_proxies`, so the two can't drift apart.
It's a static list on purpose. The `caddy-cloudflare-ip` module (which
fetches the ranges) is unmaintained: last commit 2023-11, built against
Caddy 2.6, no releases. And a `remote_ip` matcher can only take a static
list anyway. If the list is ever empty the gate matches nothing and every
staging request gets 403 (fails closed).

**Refreshing the ranges** (Cloudflare changes them rarely; check every few
months, and whenever `./smoke.sh` shows 403 via Cloudflare):

```bash
./caddy/refresh-cloudflare-ips.sh   # fetches ips-v4/ips-v6, validates, rewrites the file
```

If it says `RANGES CHANGED`:

1. `docker compose up -d caddy` (env changes need a recreate, not a reload),
   then `./smoke.sh`.
2. Commit `caddy/cloudflare-ips.env`.
3. Make the same change to `set_real_ip_from` in the scoring repo's
   `00-cloudflare-realip.conf.template` (production nginx uses that list).

**Certificates: DNS-01.** HTTP-01 doesn't work reliably behind the proxy, so
the staging vhosts use the DNS-01 challenge through the Cloudflare API
(`tls { dns cloudflare … }` in `staging.caddy`; that's why Caddy is a custom
build, §3). Only these vhosts do: the global options set no `acme_dns`, and
the pipeline's hostnames keep ordinary HTTP-01.

What that needs, in the Cloudflare dashboard (owner):

* DNS: one **proxied** (orange) record per staging hostname above → the
  VPS's public IP.
* SSL/TLS mode **Full (strict)** for both zones (`BAJA_DOMAIN`'s and
  `FORMULA_DOMAIN`'s). Caddy has real Let's Encrypt certificates. *Flexible*
  would make Cloudflare speak HTTP to the origin, and Caddy would redirect it
  to HTTPS forever.
* An API token for Caddy: My Profile → API Tokens → Create Token → Custom,
  permissions **Zone / DNS / Edit** and **Zone / Zone / Read**, zone
  resources limited to the two zones. Put it in `.env` as
  `CLOUDFLARE_API_TOKEN`. Caddy reads it at runtime (`{env.…}`), so it never
  appears in the config the admin API serves.
* The results-page cache rule (`baja_staff` cookie) is unchanged; it lives
  at Cloudflare and nginx as before.

### 5.4 Enable

After §5.1–§5.3, with `BAJA_DOMAIN`/`FORMULA_DOMAIN` filled in `.env` (the
same values as the staging stack's `.env`) and `CLOUDFLARE_API_TOKEN` set:

```bash
./setup.sh --enable-staging
```

It copies `conf.d/staging.caddy` to `/srv/caddy/conf.d/`, recreates Caddy if
its environment changed, and reloads. If Caddy rejects the file, it removes
it again and the old config stays active. It refuses to run without a real
`CLOUDFLARE_API_TOKEN`: Caddy rejects a DNS provider without a usable token,
and a rejected file would stop Caddy, Evolution's route included, at its next
restart. Caddy then requests certificates for the eight hostnames over DNS-01
(`docker compose logs -f caddy | grep -i acme`).

Check with `./smoke.sh` (§10): 403 for every hostname straight to the
origin, an nginx answer for each through Cloudflare (502 for all while
`baja-nginx` is down), and `CF-Connecting-IP` arriving at nginx.

Disable: `./setup.sh --disable-staging`.

After pulling a new version of this repo, run `./setup.sh --enable-staging`
again to install the updated file.

---

## 6. How another stack plugs in

1. **Join `baja-edge`** with only the containers Caddy (or Evolution's
   webhook) must reach:
   ```yaml
   services:
     myapp:
       networks: [default, edge]
   networks:
     edge:
       name: baja-edge
       external: true
   ```
   Service and container names are DNS names on the shared network, so pick
   specific ones (`orchestrator`, `baja-nginx`), never `app`, `db` or
   `redis`. Evolution's own Postgres/Redis are not on `baja-edge`.
2. **Publish no ports** of your own on 80/443. Need a tailnet port? 8080
   (pipeline) and 8081 (Evolution) are taken; add a new one here by PR,
   since only Caddy publishes.
3. **Drop one file**, `/srv/caddy/conf.d/<stack>.caddy` (the `*.caddy`
   extension matters). It may use the `(access_log)` snippet. Prefix any
   snippet you define with your stack name, because snippet names are global.
   Hostnames: write them literally, or use `{$VAR}` with a variable Caddy
   has. Caddy has `BAJA_DOMAIN`, `FORMULA_DOMAIN`, `ACME_EMAIL`, plus
   anything in `/opt/baja-vps/caddy.env` (Compose env-file format, e.g.
   `PIPELINE_DOMAIN=review.example.org`). After editing `caddy.env`:
   `docker compose up -d caddy` (a reload doesn't re-read the environment).

   **Grey-cloud (DNS-only) hostnames, e.g. the pipeline's, are open and use
   ordinary HTTP-01.** Such a file must **never** reuse the staging
   Cloudflare-only pieces, not even by copying from `staging.caddy`:
   * no `remote_ip {$CLOUDFLARE_IPS}` matcher (or any matcher built from
     `CLOUDFLARE_IPS`): its visitors connect directly, so it would 403 every
     one of them;
   * no `tls { dns cloudflare … }`: it would need the token for a zone it
     may not be in, and HTTP-01 works fine for a grey record;
   * don't define `staging_*` names (snippets or matchers); that prefix is
     reserved for `staging.caddy`.

   The global `trusted_proxies` (Cloudflare's ranges) does apply to your
   site too, since it is per listener. It is harmless: a direct visitor is
   never a Cloudflare address, so Caddy uses the TCP peer as the client, and
   a `CF-Connecting-IP` it sends is ignored.
4. **Validate, then reload**:
   ```bash
   docker exec caddy caddy validate --config /etc/caddy/Caddyfile
   docker exec caddy caddy reload --config /etc/caddy/Caddyfile
   ```
   A failed reload keeps the old config running, but a broken file stops
   Caddy at its next restart. Remove a file that doesn't validate.
5. **Static files**: Caddy only sees `/srv/pipeline` (read-only). Anything
   else needs a mount here, by PR.
6. **Unplugging**: delete your file, reload. Do this when a stack is shut
   down for the season if its file imports things that live in that stack
   (the pipeline's file imports `/srv/pipeline/reviewers.txt`; if that file
   is missing, Caddy refuses the whole config).

---

## 7. Webhook consumers

Evolution v2 has two webhook slots [R8][R20]:

| Slot | Where it's set | Custom headers | Owner |
| --- | --- | --- | --- |
| **Instance webhook** | Postgres, via `POST /webhook/set/{instance}` | yes | **the video pipeline's orchestrator** |
| **Global webhook** | env `WEBHOOK_GLOBAL_*` in `docker-compose.yml` | **no** | **free**, for one future consumer |

### 7.1 Rules

* The instance webhook belongs to the pipeline. Don't repoint it at
  anything else, and don't let another consumer `webhook/set` it.
* The global slot is free (`WEBHOOK_GLOBAL_ENABLED=false`). A future
  consumer can take it: set `WEBHOOK_GLOBAL_ENABLED`, `WEBHOOK_GLOBAL_URL`
  and the event flags in this compose file (by PR), then
  `docker compose up -d evolution`. It can't carry a secret header, so the
  consumer must sit on `baja-edge` only (no public route) and accept
  webhooks from that network only.
* **A third consumer needs a fan-out**: a small relay on `baja-edge` that
  takes one slot and re-posts every event to its consumers. Evolution's
  retries then only cover the hop to the relay; the relay must do its own
  retries per consumer.
* Delivery is awaited with retries: 10 attempts, exponential backoff capped
  at 300 s, about 20 minutes in total [R21]. 400/401/403/404/422 are not
  retried.
* **`base64` stays off** on every webhook, and S3 is off. With `base64`
  Evolution loads every incoming media into memory [R22]; a 2 GB WhatsApp
  document would OOM-kill it at its 1 GiB limit.

### 7.2 Pointing the instance webhook at the orchestrator

From the pipeline's runbook. Once the orchestrator runs on `baja-edge`:

```bash
set -a; . ./.env; set +a
BVP_WEBHOOK_SECRET=<the pipeline's BVP_WEBHOOK_SECRET>
curl -sS -X POST "http://$TAILSCALE_IP:8081/webhook/set/$EVOLUTION_INSTANCE" \
  -H "apikey: $EVOLUTION_API_KEY" -H 'content-type: application/json' \
  -d '{"webhook":{"enabled":true,"url":"http://orchestrator:8000/intake/evolution-webhook","headers":{"X-Webhook-Secret":"'"$BVP_WEBHOOK_SECRET"'"},"byEvents":false,"base64":false,"events":["MESSAGES_UPSERT","CONNECTION_UPDATE"]}}'
curl -sS -H "apikey: $EVOLUTION_API_KEY" "http://$TAILSCALE_IP:8081/webhook/find/$EVOLUTION_INSTANCE" ; echo
```

The webhook goes from Evolution to `orchestrator:8000` over `baja-edge`; it
never leaves the host. Off-season, when the orchestrator is gone, disable it
with the §4.7 command so Evolution doesn't retry into nothing.

---

## 8. Backups

`backup.sh` saves the three stores of the WhatsApp session (Postgres dump,
Redis snapshot, instances volume, plus `SHA256SUMS`) to
`BACKUP_DIR/evolution-<UTC timestamp>/`. A run that fails leaves no
directory behind and deletes nothing. After a good run, backups older than
`BACKUP_KEEP_DAYS` (14) are deleted. Restoring: [`restore.md`](restore.md).

Install the daily timer (03:30, plus up to 10 minutes' random delay):

```bash
cp systemd/baja-evolution-backup.service systemd/baja-evolution-backup.timer /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now baja-evolution-backup.timer
systemctl start baja-evolution-backup.service        # one run now
journalctl -u baja-evolution-backup -n 20
ls -l /var/backups/baja-evolution
systemctl list-timers baja-evolution-backup.timer
```

Backups stay **on this VPS's disk**. They don't survive losing the VPS.
Copy them somewhere else (for example to TrueNAS with `scp`) if that matters;
they contain the session keys, so the copy must be private.

---

## 9. Memory budget (4 GB box)

| Container | Limit | Notes |
| --- | --- | --- |
| evolution | 1024 MiB | Node + Baileys, one instance. Heap capped at 640 MiB (`NODE_OPTIONS`). Media is never buffered (§7.1). |
| postgres | 512 MiB | `shared_buffers=128MB`, `max_connections=50` (upstream: 1000) |
| redis | 320 MiB | `maxmemory 160mb`, `volatile-lru`, headroom for the AOF-rewrite fork. Session keys have no TTL and are never evicted. |
| caddy | 192 MiB | TLS + static files |
| **Base stack total** | **2048 MiB** | always on |
| pipeline: orchestrator + review-ui | 768 + 160 MiB | in season (limits from its compose) |
| scoring staging | **no limits** in its compose | MySQL 8.4, PHP-FPM, Next.js, 2× phpBB, Redis, TTS |
| Host | ~1.2 GiB | kernel, dockerd/containerd, tailscaled, sshd, journald, page cache |
| Swap | 2 GiB | host only (`memswap_limit = mem_limit`) |

The limits are ceilings, not usage, but base + pipeline + host already add up
to about 4.1 GiB, so **with staging running too, the box is
overcommitted**. Check real usage:

```bash
docker stats --no-stream --format 'table {{.Name}}\t{{.MemUsage}}\t{{.MemPerc}}'
free -m
```

Healthy steady state: Evolution under ~800 MiB, `free -m` showing some
`available` memory, swap use small and stable. If Evolution sits above
~800 MiB, look at `DATABASE_SAVE_*` before raising limits. If the box runs
short in season, stop the scoring staging stack during events, or give its
services `mem_limit`s (scoring repo).

An OOM kill shows as `docker inspect -f '{{.State.OOMKilled}}' <container>`
= `true` and in `journalctl -k | grep -i oom`.

---

## 10. Smoke test

```bash
./smoke.sh
```

Read-only. One `PASS`/`FAIL` line per check, exit code 1 if anything failed:

* `postgres`, `redis`, `evolution`, `caddy` containers are `healthy`;
* `baja-edge` has subnet `10.201.0.0/24` and Caddy is attached to it;
* the running Caddy has the Cloudflare DNS plugin (i.e. is the custom build);
* Caddy answers on port 80;
* the Evolution listener is published on `TAILSCALE_IP:8081` **only**;
* Evolution: 401 without `apikey`, 200 with it, and instance
  `EVOLUTION_INSTANCE` is `open`;
* if the staging vhosts are enabled, for each of the eight hostnames:
  * **straight to this origin** (`curl --resolve …:443:127.0.0.1`; the peer
    Caddy sees is the Docker gateway, not Cloudflare): must be **403**,
    whether or not `baja-nginx` runs. Anything else means the gate is open;
  * **through Cloudflare** (normal public DNS, so a real Cloudflare edge is
    the peer; this is the "Cloudflare source" check): with `baja-nginx`
    running, anything but 000/403/5xx (the apex gives 200; other vhosts may
    redirect or 404 their `/`); with it down, 502. A 403 here means real
    Cloudflare traffic hits the gate: stale ranges (§5.3, refresh);
  * with `baja-nginx` running, one request through Cloudflare to the apex
    with a unique `?baja-smoke=…` marker, then `docker logs baja-nginx`:
    the line's client address (nginx's `$remote_addr`, which realip sets from
    `CF-Connecting-IP`) must not be a `10.201.0.x` address. If it is, the
    header did not arrive or nginx lacks `set_real_ip_from 10.201.0.0/24`
    (§5.2).

The Cloudflare checks need the box to resolve and reach its own public
hostnames through Cloudflare (normal outbound HTTPS). If that is blocked,
run the same request from any other machine and read nginx's log on the
box:

```bash
curl -sI "https://$BAJA_DOMAIN/?baja-smoke=manual"      # elsewhere: not 403/5xx
docker logs --since 2m baja-nginx | grep baja-smoke=manual   # on the box: first field = that machine's IP
```

---

## 11. Troubleshooting

| Symptom | Likely cause → fix |
| --- | --- |
| Caddy won't start: `cannot assign requested address` | `ip_nonlocal_bind` missing (§1.3), or `TAILSCALE_IP` wrong (`tailscale ip -4`) |
| Caddy won't start: `address already in use` on 80/443 | `baja-nginx` (or anything else) still publishes it: `ss -ltnp 'sport = :80'`; §5.1 step 1 |
| Caddy restarting after a conf.d change | `docker logs caddy`; remove or fix the offending `/srv/caddy/conf.d/*.caddy` (§6.4). Pipeline file without `/srv/pipeline/reviewers.txt` is a common one |
| `network baja-edge declared as external, but could not be found` | Run `./setup.sh` |
| `setup.sh`: `baja-edge exists with subnet …, must be 10.201.0.0/24` | The network was created by hand or by an older setup. In a maintenance window: stop every stack on `baja-edge` (staging, pipeline, this one), `docker network rm baja-edge`, re-run `./setup.sh`, start them again |
| `setup.sh`: `10.201.0.0/24 overlaps: …` | Another Docker network or a host route (VPN, provider LAN) uses that range. Remove or renumber *that* (`docker network rm …`, the VPN's config); `baja-edge` can't move on its own (§2.3) |
| Staging hostnames: 403 for real visitors | Request didn't come from Cloudflare (record set to DNS-only/grey?), or Cloudflare added ranges: §5.3, refresh |
| Staging hostnames: 502 | `baja-nginx` down, not on `baja-edge` (`docker network inspect baja-edge`), or renamed |
| Staging hostnames: redirect loop | nginx runs `LISTEN_MODE=listen-tls` (§5.1), or Cloudflare SSL mode is *Flexible* (§5.3) |
| Cloudflare 525/526 | Caddy has no valid certificate yet: `docker compose logs caddy \| grep -i acme`. DNS-01 errors: token missing/wrong scope (`Zone:DNS:Edit` + `Zone:Zone:Read` on both zones), or `expected 1 zone` (the zone isn't in that Cloudflare account); §5.3 |
| `smoke.sh`: `caddy lacks dns.providers.cloudflare` | Caddy runs the stock image: `docker compose build caddy && docker compose up -d caddy` (§3) |
| Every staging visitor has the same IP in nginx logs | nginx lacks `set_real_ip_from 10.201.0.0/24` (§5.2) |
| Evolution unreachable on 8081 from a tailnet device | `ufw allow in on tailscale0` missing; Tailscale ACL doesn't allow you to `tag:server:8081`; `docker port caddy` doesn't show `TAILSCALE_IP:8081` |
| Evolution instance not `open` | §4.8, "If the state is not open" |
| `volume … already exists but was created for project "baja"` | Expected after §4.10; harmless |
| Evolution restarts every so often | OOM (§9): `docker inspect -f '{{.State.OOMKilled}}' $(docker compose ps -q evolution)` |
| Backup failed | `journalctl -u baja-evolution-backup`; each step logs before it runs. Fix and `systemctl start baja-evolution-backup.service` |

---

## 12. Upgrading Evolution and rotating secrets

* Bump the tag in `docker-compose.yml` deliberately. Never use `latest`.
* **2.4.0 requires license activation** against the Evolution Foundation
  licensing server before serving API traffic (business endpoints return 503
  until activated). It is RC-only as of this writing [R3]. Evaluate it
  before upgrading.
* Before any upgrade: `systemctl start baja-evolution-backup.service` and
  check it finished.
* **Evolution API key**: change `EVOLUTION_API_KEY` in `.env`, then
  `docker compose up -d evolution`. The orchestrator uses the instance
  token, so it is not affected.
* **Manager password**: new hash in `MANAGER_BASIC_AUTH_HASH`, then
  `docker compose up -d caddy`.
* **Cloudflare API token**: create the new one (same scope, §5.3), put it in
  `CLOUDFLARE_API_TOKEN`, `docker compose up -d caddy`, check
  `./smoke.sh`, then revoke the old one at Cloudflare.
* **Webhook secret**: the pipeline's runbook, then §7.2 again.

---

## 13. References

Evolution API (official docs live at docs.evolutionfoundation.com.br; doc.evolution-api.com redirects there):

* [R1] Releases (v2.3.7 = Latest; 2.4.0-rc1/rc2 pre-release): https://github.com/EvolutionAPI/evolution-api/releases
* [R2] Docker Hub tags (`v2.3.7` 2025-12-05; `latest` 2026-05-06): https://hub.docker.com/r/evoapicloud/evolution-api/tags
* [R3] 2.4.0-rc1 notes (license activation, "do not deploy to production"): https://github.com/EvolutionAPI/evolution-api/releases/tag/2.4.0-rc1
* [R4] Auth-state selection (provider → Redis `SAVE_INSTANCES` → Prisma): https://github.com/EvolutionAPI/evolution-api/blob/2.3.7/src/api/integrations/channel/whatsapp/whatsapp.baileys.service.ts (`defineAuthState`)
* [R5] Prisma auth state: `creds` in `Session`, other keys in Redis hash or `INSTANCE_DIR` files: https://github.com/EvolutionAPI/evolution-api/blob/2.3.7/src/utils/use-multi-file-auth-state-prisma.ts ; key naming: https://github.com/EvolutionAPI/evolution-api/blob/2.3.7/src/cache/rediscache.ts , https://github.com/EvolutionAPI/evolution-api/blob/2.3.7/src/api/server.module.ts
* [R6] Instances loaded `WHERE clientName = DATABASE_CONNECTION_CLIENT_NAME`: https://github.com/EvolutionAPI/evolution-api/blob/2.3.7/src/api/services/monitor.service.ts
* [R7] Docs index (no backup/migration page): https://docs.evolutionfoundation.com.br/llms.txt
* [R8] Webhook delivery (instance vs global, retries, headers only on instance): https://github.com/EvolutionAPI/evolution-api/blob/2.3.7/src/api/integrations/event/webhook/webhook.controller.ts
* [R9] Logout instance: https://docs.evolutionfoundation.com.br/evolution-api/logout-instance.md
* [R10] Docker install (`evolution_instances:/evolution/instances`): https://docs.evolutionfoundation.com.br/evolution-api/install/docker.md
* [R11] Env vars (docs): https://docs.evolutionfoundation.com.br/evolution-api/configuration/env.md ; defaults in code: https://github.com/EvolutionAPI/evolution-api/blob/2.3.7/src/config/env.config.ts ; upstream example: https://github.com/EvolutionAPI/evolution-api/blob/2.3.7/.env.example
* [R12] Image entrypoint runs DB migrations: https://github.com/EvolutionAPI/evolution-api/blob/2.3.7/Dockerfile
* [R13] Find webhook / set webhook (docs): https://docs.evolutionfoundation.com.br/evolution-api/get-webhook.md , https://docs.evolutionfoundation.com.br/evolution-api/set-webhook.md
* [R15] Redis: switching RDB → AOF on a live server: https://redis.io/docs/latest/operate/oss_and_stack/management/persistence/
* [R16] Set-webhook body schema actually validated in v2.3.7: https://github.com/EvolutionAPI/evolution-api/blob/2.3.7/src/api/integrations/event/webhook/webhook.schema.ts
* [R17] Connection state: https://docs.evolutionfoundation.com.br/evolution-api/get-connection-state.md
* [R18] Send text: https://docs.evolutionfoundation.com.br/evolution-api/send-text-message.md
* [R19] Fetch instances: https://docs.evolutionfoundation.com.br/evolution-api/fetch-all-instances.md
* [R20] Webhooks overview (instance vs global): https://docs.evolutionfoundation.com.br/evolution-api/configuration/webhooks.md
* [R21] Retry settings `WEBHOOK_RETRY_*` and defaults: https://github.com/EvolutionAPI/evolution-api/blob/2.3.7/.env.example
* [R22] Media buffered when `webhookBase64` is on (`messages.upsert`): https://github.com/EvolutionAPI/evolution-api/blob/2.3.7/src/api/integrations/channel/whatsapp/whatsapp.baileys.service.ts

Caddy:

* `trusted_proxies` / `client_ip_headers`: https://caddyserver.com/docs/caddyfile/options#trusted-proxies
* `remote_ip` matcher (TCP peer, vs `client_ip`): https://caddyserver.com/docs/caddyfile/matchers#remote-ip
* `tls` / `dns` (DNS-01 per site): https://caddyserver.com/docs/caddyfile/directives/tls
* Custom builds (`caddy:<v>-builder`, xcaddy): https://hub.docker.com/_/caddy (section "Adding custom Caddy modules")
* `caddy-dns/cloudflare` (token scopes, troubleshooting): https://github.com/caddy-dns/cloudflare
* `caddy-cloudflare-ip`, not used (unmaintained, §5.3): https://github.com/WeidiDeng/caddy-cloudflare-ip
* Cloudflare IP ranges: https://www.cloudflare.com/ips/ ; SSL modes: https://developers.cloudflare.com/ssl/origin-configuration/ssl-modes/full-strict/
* `reverse_proxy` headers (Host, X-Forwarded-*): https://caddyserver.com/docs/caddyfile/directives/reverse_proxy#headers
* `import` with globs: https://caddyserver.com/docs/caddyfile/directives/import
