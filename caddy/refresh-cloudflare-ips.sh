#!/usr/bin/env bash
# Re-fetch Cloudflare's IP ranges into caddy/cloudflare-ips.env.
#
#   ./caddy/refresh-cloudflare-ips.sh
#
# Only rewrites the file (and prints the diff); it does not touch Caddy.
# Applying it, and keeping nginx's list in step: README §5.3.
# Refuses to write anything if either list is empty or holds a line that
# is not a CIDR, so a captive portal or an error page cannot become the
# staging allowlist.
set -euo pipefail

CADDY_SRC="${CADDY_SRC:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
OUT="$CADDY_SRC/cloudflare-ips.env"
V4_URL=https://www.cloudflare.com/ips-v4
V6_URL=https://www.cloudflare.com/ips-v6

die() {
	printf '[%s] ERROR: %s\n' "${0##*/}" "$*" >&2
	exit 1
}

# fetch <url> <cidr-regex>: one range per line, validated.
fetch() {
	local body line ranges=()
	body="$(curl -fsS --max-time 20 "$1")" || die "could not fetch $1"
	while IFS= read -r line; do
		line="${line//$'\r'/}"
		[ -z "$line" ] && continue
		[[ "$line" =~ $2 ]] || die "unexpected line from $1: '${line:0:80}'"
		ranges+=("$line")
	done <<<"$body"
	[ "${#ranges[@]}" -gt 0 ] || die "$1 returned no ranges"
	printf '%s ' "${ranges[@]}"
}

v4="$(fetch "$V4_URL" '^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$')"
v6="$(fetch "$V6_URL" '^[0-9a-fA-F:]+/[0-9]{1,3}$')"
all="${v4}${v6}"
all="${all% }"

new="$(mktemp)"
trap 'rm -f "$new"' EXIT
# Keep the header comments, replace the date and the list.
sed -e "s|^# Fetched: .*|# Fetched: $(date -u +%F)|" -e '/^CLOUDFLARE_IPS=/d' "$OUT" >"$new"
printf 'CLOUDFLARE_IPS=%s\n' "$all" >>"$new"

if grep -qxF "CLOUDFLARE_IPS=$all" "$OUT"; then
	cp "$new" "$OUT"
	echo "ranges unchanged (Fetched: date updated); nothing to apply"
	exit 0
fi
diff -u "$OUT" "$new" || true
cp "$new" "$OUT"
echo "RANGES CHANGED in $OUT. Next: README §5.3 (recreate Caddy, update nginx's list too)."
