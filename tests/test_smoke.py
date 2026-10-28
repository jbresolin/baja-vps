"""smoke.sh: each check passes on a healthy stack and catches its failure."""
from harness import ScriptTestCase

TS = "100.64.0.7"
STAGING_HOSTS = [
    "staging.test", "www.staging.test", "api.staging.test", "certificado.staging.test",
    "fila.staging.test", "juiz.staging.test", "resultados.staging.test",
    "forum.staging.test", "forum.formula.test",
]


def healthy(**overrides):
    """Scenario for a fully healthy base stack (staging vhosts not enabled)."""
    scenario = {
        "ids": {s: f"id-{s}" for s in ("postgres", "redis", "evolution", "caddy")},
        "inspect": {f"id-{s}": "healthy" for s in ("postgres", "redis", "evolution", "caddy")},
        "network": "baja-base-evolution-1 caddy baja-nginx ",
        "edge_subnet": "10.201.0.0/24 ",
        "port": f"{TS}:8081",
        "curl": [
            {"url": "http://127.0.0.1/", "code": "308"},
            {"url": "/instance/connectionState/BajaBot", "header": "apikey: k3y", "code": "200",
             "body": '{"instance":{"instanceName":"BajaBot","state":"open"}}'},
            {"url": f"http://{TS}:8081/", "header": "apikey: k3y", "code": "200"},
            {"url": f"http://{TS}:8081/", "code": "401"},
        ],
    }
    scenario.update(overrides)
    return scenario


def staging(nginx_up, via_cloudflare, direct="403", **overrides):
    """Healthy stack with staging enabled. Direct-to-origin requests answer
    `direct`, requests through Cloudflare `via_cloudflare`."""
    scenario = healthy(**overrides)
    if nginx_up:
        scenario["inspect"]["baja-nginx"] = "true"
        scenario.setdefault("nginx_log_addr", "203.0.113.10")
    scenario["curl"] = [
        {"url": "https://", "direct": True, "code": direct},
        {"url": "https://", "direct": False, "code": via_cloudflare},
    ] + scenario["curl"]
    return scenario


class SmokeTest(ScriptTestCase):
    def smoke(self, scenario):
        self.set_scenario(scenario)
        return self.run_script("smoke.sh")

    def enable_staging(self):
        (self.caddy_dir / "conf.d").mkdir(parents=True)
        (self.caddy_dir / "conf.d" / "staging.caddy").write_text("")

    def test_healthy_stack_passes(self):
        result = self.smoke(healthy())
        self.assertSucceeded(result)
        self.assertNotIn("FAIL", result.stdout)
        self.assertIn("PASS  network baja-edge: subnet 10.201.0.0/24", result.stdout)
        self.assertIn("PASS  caddy has the Cloudflare DNS plugin", result.stdout)
        self.assertIn("staging vhosts not enabled; skipped", result.stdout)

    def test_wrong_edge_subnet_fails(self):
        result = self.smoke(healthy(edge_subnet="10.203.0.0/24 "))
        self.assertFailed(result)
        self.assertIn("FAIL  network baja-edge: subnet '10.203.0.0/24' (must be 10.201.0.0/24)", result.stdout)

    def test_stock_caddy_image_fails(self):
        result = self.smoke(healthy(modules="http.handlers.reverse_proxy"))
        self.assertFailed(result)
        self.assertIn("FAIL  caddy lacks dns.providers.cloudflare", result.stdout)

    def test_unhealthy_container_fails(self):
        scenario = healthy()
        scenario["inspect"]["id-evolution"] = "starting"
        result = self.smoke(scenario)
        self.assertFailed(result)
        self.assertIn("FAIL  container evolution: starting", result.stdout)

    def test_public_evolution_binding_fails(self):
        result = self.smoke(healthy(port=f"0.0.0.0:8081\n{TS}:8081"))
        self.assertFailed(result)
        self.assertIn("FAIL  evolution listener bindings", result.stdout)

    def test_instance_not_open_fails(self):
        scenario = healthy()
        scenario["curl"][1]["body"] = '{"instance":{"instanceName":"BajaBot","state":"connecting"}}'
        result = self.smoke(scenario)
        self.assertFailed(result)
        self.assertIn("FAIL  evolution instance BajaBot: connecting", result.stdout)

    def test_staging_up_passes_every_check(self):
        self.enable_staging()
        result = self.smoke(staging(nginx_up=True, via_cloudflare="200"))
        self.assertSucceeded(result)
        self.assertEqual(result.stdout.count("direct to origin (not Cloudflare) -> 403"), len(STAGING_HOSTS))
        self.assertEqual(result.stdout.count("via Cloudflare: HTTP 200 (baja-nginx running)"), len(STAGING_HOSTS))
        self.assertIn("PASS  CF-Connecting-IP reaches nginx (client 203.0.113.10)", result.stdout)
        curls = [c for c in self.calls() if c[0] == "curl"]
        for host in STAGING_HOSTS:
            self.assertTrue(any(f"{host}:443:127.0.0.1" in c for c in curls), host)
            self.assertTrue(any(f"https://{host}/" in c and "--resolve" not in c for c in curls), host)

    def test_staging_down_expects_403_direct_and_502_via_cloudflare(self):
        self.enable_staging()
        result = self.smoke(staging(nginx_up=False, via_cloudflare="502"))
        self.assertSucceeded(result)
        self.assertEqual(result.stdout.count("direct to origin (not Cloudflare) -> 403"), len(STAGING_HOSTS))
        self.assertEqual(result.stdout.count("(baja-nginx down) -> 502"), len(STAGING_HOSTS))
        self.assertIn("CF-Connecting-IP check skipped", result.stdout)

    def test_open_gate_fails(self):
        # Direct-to-origin requests reaching nginx = the Cloudflare gate is off.
        self.enable_staging()
        result = self.smoke(staging(nginx_up=True, via_cloudflare="200", direct="200"))
        self.assertFailed(result)
        self.assertEqual(result.stdout.count("direct to origin (not Cloudflare) -> 200 (want 403)"),
                         len(STAGING_HOSTS))

    def test_cloudflare_blocked_by_gate_fails(self):
        # e.g. stale Cloudflare ranges: real Cloudflare traffic gets the 403.
        self.enable_staging()
        result = self.smoke(staging(nginx_up=True, via_cloudflare="403"))
        self.assertFailed(result)
        self.assertIn("FAIL  staging staging.test via Cloudflare: HTTP 403 with baja-nginx running", result.stdout)

    def test_staging_up_but_502_fails(self):
        self.enable_staging()
        scenario = staging(nginx_up=True, via_cloudflare="200")
        scenario["curl"].insert(0, {"url": "https://forum.formula.test/", "direct": False, "code": "502"})
        result = self.smoke(scenario)
        self.assertFailed(result)
        self.assertIn("FAIL  staging forum.formula.test via Cloudflare: HTTP 502 with baja-nginx running",
                      result.stdout)
        self.assertEqual(result.stdout.count("via Cloudflare: HTTP 200"), len(STAGING_HOSTS) - 1)

    def test_nginx_logging_caddys_address_fails(self):
        self.enable_staging()
        result = self.smoke(staging(nginx_up=True, via_cloudflare="200", nginx_log_addr="10.201.0.2"))
        self.assertFailed(result)
        self.assertIn("FAIL  CF-Connecting-IP: nginx logged Caddy's address 10.201.0.2", result.stdout)

    def test_marked_request_missing_from_nginx_log_fails(self):
        self.enable_staging()
        scenario = staging(nginx_up=True, via_cloudflare="200")
        del scenario["nginx_log_addr"]
        scenario["inspect"]["baja-nginx"] = "true"
        result = self.smoke(scenario)
        self.assertFailed(result)
        self.assertIn("FAIL  CF-Connecting-IP: marked request never reached baja-nginx's log", result.stdout)
