"""Static checks on the Caddy files, and caddy/refresh-cloudflare-ips.sh.

`caddy validate` itself needs Docker; README §3 has the command. These
tests catch the drift that validate cannot see.
"""
import ipaddress
import re

from harness import REPO, ScriptTestCase

IPS_FILE = REPO / "caddy" / "cloudflare-ips.env"


def cloudflare_ranges(path=IPS_FILE):
    lines = [l for l in path.read_text().splitlines() if l.startswith("CLOUDFLARE_IPS=")]
    assert len(lines) == 1, lines
    return lines[0].split("=", 1)[1].split()


def staging_site_hosts():
    text = (REPO / "conf.d" / "staging.caddy").read_text()
    site = next(l for l in text.splitlines() if l.startswith("{$BAJA_DOMAIN}"))
    return [h.strip() for h in site.rstrip("{ ").split(",")]


class CaddyFilesTest(ScriptTestCase):
    def test_cloudflare_ranges_are_valid_and_cover_both_families(self):
        nets = [ipaddress.ip_network(r) for r in cloudflare_ranges()]
        self.assertTrue(any(n.version == 4 for n in nets))
        self.assertTrue(any(n.version == 6 for n in nets))
        self.assertIn(ipaddress.ip_network("173.245.48.0/20"), nets)

    def test_staging_hosts_match_smoke_list(self):
        self.assertEqual(staging_site_hosts(), [
            "{$BAJA_DOMAIN}", "api.{$BAJA_DOMAIN}", "certificado.{$BAJA_DOMAIN}",
            "fila.{$BAJA_DOMAIN}", "juiz.{$BAJA_DOMAIN}", "resultados.{$BAJA_DOMAIN}",
            "forum.{$BAJA_DOMAIN}", "{$FORMULA_DOMAIN}",
        ])
        smoke = (REPO / "smoke.sh").read_text()
        labels = re.search(r"for label in ([a-z ]+); do", smoke).group(1).split()
        self.assertEqual([l + ".{$BAJA_DOMAIN}" for l in labels], staging_site_hosts()[1:-1])

    def test_trust_and_gate_use_the_same_list(self):
        caddyfile = (REPO / "Caddyfile").read_text()
        staging = (REPO / "conf.d" / "staging.caddy").read_text()
        self.assertRegex(caddyfile, r"\n\t\ttrusted_proxies static \{\$CLOUDFLARE_IPS\}\n")
        self.assertRegex(staging, r"\n\t@staging_cloudflare remote_ip \{\$CLOUDFLARE_IPS\}\n")

    def test_dns01_and_gate_stay_out_of_the_global_options(self):
        caddyfile = (REPO / "Caddyfile").read_text()
        self.assertNotRegex(caddyfile, r"(?m)^\s*acme_dns\b")
        self.assertNotRegex(caddyfile, r"(?m)^\s*dns cloudflare\b")
        self.assertNotRegex(caddyfile, r"(?m)^\s*@\S+\s+remote_ip\b")

    def test_cf_connecting_ip_is_never_rewritten(self):
        staging = (REPO / "conf.d" / "staging.caddy").read_text()
        self.assertNotRegex(staging, r"(?m)^\s*header_up\s+-?CF-Connecting-IP")


class RefreshCloudflareIpsTest(ScriptTestCase):
    V4 = "173.245.48.0/20\n103.21.244.0/22\n"
    V6 = "2400:cb00::/32\n"

    def refresh(self, v4, v6):
        self.set_scenario({"curl": [
            {"url": "/ips-v4", "code": "200", "body": v4},
            {"url": "/ips-v6", "code": "200", "body": v6},
        ]})
        return self.run_script("caddy/refresh-cloudflare-ips.sh",
                               extra_env={"CADDY_SRC": str(self.stack / "caddy")})

    def test_rewrites_the_list_and_keeps_the_header(self):
        result = self.refresh(self.V4, self.V6)
        self.assertSucceeded(result)
        out = self.stack / "caddy" / "cloudflare-ips.env"
        self.assertEqual(cloudflare_ranges(out), ["173.245.48.0/20", "103.21.244.0/22", "2400:cb00::/32"])
        self.assertIn("# Never hand-edit the line below.", out.read_text())
        self.assertRegex(out.read_text(), r"# Fetched: \d{4}-\d\d-\d\d\n")
        self.assertIn("RANGES CHANGED", result.stdout)

    def test_same_ranges_need_no_action(self):
        current = cloudflare_ranges()
        v4 = "".join(r + "\n" for r in current if ":" not in r)
        v6 = "".join(r + "\n" for r in current if ":" in r)
        result = self.refresh(v4, v6)
        self.assertSucceeded(result)
        self.assertIn("nothing to apply", result.stdout)
        self.assertEqual(cloudflare_ranges(self.stack / "caddy" / "cloudflare-ips.env"), current)

    def test_refuses_a_non_cidr_body(self):
        before = (self.stack / "caddy" / "cloudflare-ips.env").read_text()
        for v4, v6 in (("<html>captive portal</html>\n", self.V6), (self.V4, ""), (self.V4, "2400:cb00::/32; rm\n")):
            with self.subTest(v4=v4, v6=v6):
                self.assertFailed(self.refresh(v4, v6))
                self.assertEqual((self.stack / "caddy" / "cloudflare-ips.env").read_text(), before)
