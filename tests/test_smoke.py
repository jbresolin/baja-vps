"""smoke.sh: each check passes on a healthy stack and catches its failure."""
from harness import ScriptTestCase

TS = "100.64.0.7"
STAGING_HOSTS = [
    "https://staging.test/", "https://api.staging.test/", "https://certificado.staging.test/",
    "https://fila.staging.test/", "https://juiz.staging.test/", "https://resultados.staging.test/",
    "https://forum.staging.test/", "https://forum.formula.test/",
]


def healthy(**overrides):
    """Scenario for a fully healthy base stack (staging vhosts not enabled)."""
    scenario = {
        "ids": {s: f"id-{s}" for s in ("postgres", "redis", "evolution", "caddy")},
        "inspect": {f"id-{s}": "healthy" for s in ("postgres", "redis", "evolution", "caddy")},
        "network": "baja-base-evolution-1 caddy baja-nginx ",
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
        self.assertIn("staging vhosts not enabled; skipped", result.stdout)

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

    def test_staging_down_expects_502_everywhere(self):
        self.enable_staging()
        scenario = healthy()
        scenario["curl"] = [{"url": "https://", "code": "502"}] + scenario["curl"]
        result = self.smoke(scenario)
        self.assertSucceeded(result)
        self.assertEqual(result.stdout.count("(baja-nginx down) -> 502"), len(STAGING_HOSTS))
        for url in STAGING_HOSTS:
            host = url.split("/")[2]
            self.assertTrue(any(f"{host}:443:127.0.0.1" in c for c in self.calls()), host)

    def test_staging_up_but_502_fails(self):
        self.enable_staging()
        scenario = healthy()
        scenario["inspect"]["baja-nginx"] = "true"
        scenario["curl"] = [
            {"url": "https://forum.formula.test/", "code": "502"},
            {"url": "https://", "code": "200"},
        ] + scenario["curl"]
        result = self.smoke(scenario)
        self.assertFailed(result)
        self.assertIn("FAIL  staging forum.formula.test: HTTP 502 with baja-nginx running", result.stdout)
        self.assertEqual(result.stdout.count("PASS  staging"), len(STAGING_HOSTS) - 1)
