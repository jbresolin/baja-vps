"""setup.sh: network, directories, and switching the staging vhosts."""
import stat

from harness import ScriptTestCase

CADDY_RUNNING = {"inspect": {"caddy": "true"}}


class BaseSetupTest(ScriptTestCase):
    def test_creates_network_with_fixed_subnet_and_dirs(self):
        self.assertSucceeded(self.run_script("setup.sh"))

        self.assertIn(
            ["network", "create", "--driver", "bridge", "--subnet", "10.203.0.0/24", "baja-edge"],
            self.calls(),
        )
        self.assertTrue((self.caddy_dir / "conf.d").is_dir())
        self.assertTrue(self.pipeline_dir.is_dir())
        self.assertEqual(stat.S_IMODE(self.backup_dir.stat().st_mode), 0o700)
        self.assertEqual(stat.S_IMODE((self.stack / ".env").stat().st_mode), 0o600)

    def test_existing_network_is_kept_and_subnet_mismatch_warns(self):
        self.set_scenario({"network": "172.18.0.0/16"})
        result = self.run_script("setup.sh")
        self.assertSucceeded(result)
        self.assertIn("WARNING: baja-edge has subnet '172.18.0.0/16'", result.stdout)
        self.assertFalse(any(c[:2] == ["network", "create"] for c in self.calls()))

    def test_never_touches_an_existing_pipeline_dir(self):
        self.pipeline_dir.mkdir(mode=0o750)
        (self.pipeline_dir / "reviewers.txt").write_text("ana hash\n")
        self.assertSucceeded(self.run_script("setup.sh"))
        self.assertEqual(stat.S_IMODE(self.pipeline_dir.stat().st_mode), 0o750)
        self.assertEqual((self.pipeline_dir / "reviewers.txt").read_text(), "ana hash\n")

    def test_missing_tailscale_ip_fails(self):
        self.write_env(TAILSCALE_IP=None)
        result = self.run_script("setup.sh")
        self.assertFailed(result)
        self.assertIn("TAILSCALE_IP", result.stderr)


class StagingSwitchTest(ScriptTestCase):
    def setUp(self):
        super().setUp()
        (self.caddy_dir / "conf.d").mkdir(parents=True)
        self.installed = self.caddy_dir / "conf.d" / "staging.caddy"

    def test_enable_installs_file_and_waits_for_caddy_start(self):
        result = self.run_script("setup.sh", "--enable-staging")
        self.assertSucceeded(result)
        self.assertEqual(self.installed.read_text(), (self.stack / "conf.d/staging.caddy").read_text())
        self.assertFalse(any("reload" in c for c in self.calls()))

    def test_enable_recreates_and_reloads_running_caddy(self):
        self.set_scenario(CADDY_RUNNING)
        self.assertSucceeded(self.run_script("setup.sh", "--enable-staging"))
        calls = self.calls()
        up = calls.index(next(c for c in calls if c[-3:] == ["up", "-d", "caddy"]))
        reload = calls.index(["exec", "caddy", "caddy", "reload", "--config", "/etc/caddy/Caddyfile"])
        self.assertLess(up, reload)

    def test_enable_rolls_back_when_caddy_rejects_config(self):
        self.set_scenario({**CADDY_RUNNING, "reload_rc": 1})
        result = self.run_script("setup.sh", "--enable-staging")
        self.assertFailed(result)
        self.assertFalse(self.installed.exists())

    def test_enable_refuses_example_domains(self):
        self.write_env(FORMULA_DOMAIN="forum.formula.example.org")
        self.assertFailed(self.run_script("setup.sh", "--enable-staging"))
        self.assertFalse(self.installed.exists())

    def test_disable_removes_and_reloads(self):
        self.installed.write_text("old")
        self.set_scenario(CADDY_RUNNING)
        self.assertSucceeded(self.run_script("setup.sh", "--disable-staging"))
        self.assertFalse(self.installed.exists())
        self.assertTrue(any("reload" in c for c in self.calls()))
