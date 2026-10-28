"""setup.sh: network, directories, and switching the staging vhosts."""
import stat

from harness import ScriptTestCase

CADDY_RUNNING = {"inspect": {"caddy": "true"}}


CREATE_EDGE = ["network", "create", "--driver", "bridge", "--subnet", "10.201.0.0/24", "baja-edge"]
OTHER_NETWORKS = {"networks": {"bridge": "172.17.0.0/16", "pipeline": "10.202.0.0/24 fd00:1::/64"}}


def created_network(calls):
    return any(c[:2] == ["network", "create"] for c in calls)


class BaseSetupTest(ScriptTestCase):
    def test_creates_network_with_fixed_subnet_and_dirs(self):
        self.set_scenario(OTHER_NETWORKS)
        self.assertSucceeded(self.run_script("setup.sh"))

        calls = self.calls()
        self.assertIn(CREATE_EDGE, calls)
        # Checked for overlaps before creating it.
        self.assertLess(calls.index(["ip", "-4", "route", "show", "table", "all"]), calls.index(CREATE_EDGE))
        self.assertTrue((self.caddy_dir / "conf.d").is_dir())
        self.assertTrue(self.pipeline_dir.is_dir())
        self.assertEqual(stat.S_IMODE(self.backup_dir.stat().st_mode), 0o700)
        self.assertEqual(stat.S_IMODE((self.stack / ".env").stat().st_mode), 0o600)

    def test_existing_network_with_the_fixed_subnet_is_kept(self):
        self.set_scenario({"edge_subnet": "10.201.0.0/24 "})
        self.assertSucceeded(self.run_script("setup.sh"))
        self.assertFalse(created_network(self.calls()))
        self.assertFalse(any(c[:1] == ["ip"] for c in self.calls()))

    def test_existing_network_with_another_subnet_is_refused(self):
        self.set_scenario({"edge_subnet": "10.203.0.0/24 "})
        result = self.run_script("setup.sh")
        self.assertFailed(result)
        self.assertIn("baja-edge exists with subnet '10.203.0.0/24', must be 10.201.0.0/24", result.stderr)
        self.assertFalse(created_network(self.calls()))

    def test_overlapping_docker_network_is_refused(self):
        self.set_scenario({"networks": {"bridge": "172.17.0.0/16", "vpn": "10.200.0.0/15"}})
        result = self.run_script("setup.sh")
        self.assertFailed(result)
        self.assertIn("docker network vpn (10.200.0.0/15)", result.stderr)
        self.assertFalse(created_network(self.calls()))

    def test_overlapping_host_route_is_refused(self):
        cases = {
            "10.201.0.128/25 dev wg0 scope link": "route 10.201.0.128/25",
            "local 10.201.0.9 dev eth1 table local": "route 10.201.0.9",
            "10.0.0.0/8 via 192.168.1.1 dev eth0": "route 10.0.0.0/8",
        }
        for route, expected in cases.items():
            with self.subTest(route=route):
                self.log_file.write_text("")
                self.set_scenario({**OTHER_NETWORKS, "routes": route + "\n"})
                result = self.run_script("setup.sh")
                self.assertFailed(result)
                self.assertIn(expected, result.stderr)
                self.assertFalse(created_network(self.calls()))

    def test_neighbouring_ranges_do_not_count_as_overlap(self):
        routes = "10.200.255.0/24 dev a\n10.202.0.0/24 dev b\n10.201.1.0/24 dev c\ndefault via 10.201.0.1 dev d\n"
        self.set_scenario({**OTHER_NETWORKS, "routes": routes})
        self.assertSucceeded(self.run_script("setup.sh"))
        self.assertIn(CREATE_EDGE, self.calls())

    def test_unreadable_routes_refuse_rather_than_assume_free(self):
        self.set_scenario({**OTHER_NETWORKS, "ip_fails": True})
        result = self.run_script("setup.sh")
        self.assertFailed(result)
        self.assertIn("could not list host routes", result.stderr)
        self.assertFalse(created_network(self.calls()))

    def test_old_subnet_setting_in_env_is_refused(self):
        self.write_env(BAJA_EDGE_SUBNET="10.203.0.0/24")
        result = self.run_script("setup.sh")
        self.assertFailed(result)
        self.assertIn("delete that line", result.stderr)

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

    def test_enable_requires_a_real_cloudflare_token(self):
        for token in (None, "REPLACE_ME"):
            with self.subTest(token=token):
                self.write_env(CLOUDFLARE_API_TOKEN=token)
                result = self.run_script("setup.sh", "--enable-staging")
                self.assertFailed(result)
                self.assertIn("CLOUDFLARE_API_TOKEN", result.stderr)
                self.assertFalse(self.installed.exists())

    def test_disable_removes_and_reloads(self):
        self.installed.write_text("old")
        self.set_scenario(CADDY_RUNNING)
        self.assertSucceeded(self.run_script("setup.sh", "--disable-staging"))
        self.assertFalse(self.installed.exists())
        self.assertTrue(any("reload" in c for c in self.calls()))
