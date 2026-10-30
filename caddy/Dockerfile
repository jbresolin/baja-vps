# Caddy for the base stack: stock Caddy plus the Cloudflare DNS provider,
# for the DNS-01 challenge on the Cloudflare-proxied staging hostnames
# (README §5.3). Built by `docker compose build caddy`; compose tags it
# baja-caddy:<caddy>-cf<plugin> so a version bump is visible in `docker ps`.
#
# Bump both versions here AND the image tag in docker-compose.yml together.
#   Caddy:            https://github.com/caddyserver/caddy/releases
#   caddy-dns/cloudflare: https://github.com/caddy-dns/cloudflare/tags
#
# No caddy-cloudflare-ip module: it is unmaintained (last commit 2023-11,
# built against Caddy 2.6, no releases), and the staging remote_ip gate needs
# a static list anyway. The ranges live in caddy/cloudflare-ips.env (README §5.3).

FROM caddy:2.11.7-builder AS builder

RUN xcaddy build v2.11.7 \
	--with github.com/caddy-dns/cloudflare@v0.2.4

FROM caddy:2.11.7-alpine

COPY --from=builder /usr/bin/caddy /usr/bin/caddy

# Fail the build if the plugin did not make it in.
RUN caddy list-modules | grep -qx dns.providers.cloudflare
