"""Shared fixture for the shell script tests.

Each test gets a throwaway copy of the repo's scripts (so STACK_DIR, .env and
every path the scripts touch live in a temp dir), plus the fake `docker` and
`curl` from tests/fake-bin first on PATH.

Run all tests from the repo root:  python3 -m unittest discover -s tests
"""
import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
FAKE_BIN = REPO / "tests" / "fake-bin"
COPIED = ["setup.sh", "backup.sh", "smoke.sh", "lib", "conf.d"]

# A complete, valid .env. Tests override single values.
BASE_ENV = {
    "TAILSCALE_IP": "100.64.0.7",
    "BAJA_EDGE_SUBNET": "10.203.0.0/24",
    "BAJA_DOMAIN": "staging.test",
    "FORMULA_DOMAIN": "forum.formula.test",
    "EVOLUTION_API_KEY": "k3y",
    "EVOLUTION_INSTANCE": "BajaBot",
    "POSTGRES_USER": "evolution",
    "POSTGRES_DB": "evolution",
    "BACKUP_KEEP_DAYS": "14",
}


class ScriptTestCase(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="baja-vps-test-"))
        self.addCleanup(shutil.rmtree, self.tmp)
        self.stack = self.tmp / "stack"
        self.stack.mkdir()
        for name in COPIED:
            src = REPO / name
            if src.is_dir():
                shutil.copytree(src, self.stack / name)
            else:
                shutil.copy2(src, self.stack / name)
        self.caddy_dir = self.tmp / "srv-caddy"
        self.pipeline_dir = self.tmp / "srv-pipeline"
        self.backup_dir = self.tmp / "backups"
        self.scenario_file = self.tmp / "scenario.json"
        self.log_file = self.tmp / "calls.log"
        self.log_file.touch()
        self.write_env()
        self.set_scenario({})

    def write_env(self, **overrides):
        env = {**BASE_ENV, "BACKUP_DIR": str(self.backup_dir), **overrides}
        lines = [f"{k}={v}" for k, v in env.items() if v is not None]
        (self.stack / ".env").write_text("\n".join(lines) + "\n")

    def set_scenario(self, scenario):
        self.scenario_file.write_text(json.dumps(scenario))

    def run_script(self, script, *args, extra_env=None):
        env = {
            "PATH": f"{FAKE_BIN}:{os.environ['PATH']}",
            "HOME": str(self.tmp),
            "STACK_DIR": str(self.stack),
            "CADDY_DIR": str(self.caddy_dir),
            "PIPELINE_DIR": str(self.pipeline_dir),
            "BAJA_SKIP_ROOT_CHECK": "1",
            "FAKE_SCENARIO": str(self.scenario_file),
            "FAKE_LOG": str(self.log_file),
            **(extra_env or {}),
        }
        return subprocess.run(
            ["bash", str(self.stack / script), *args],
            env=env, capture_output=True, text=True, timeout=60,
        )

    def calls(self):
        return [json.loads(l) for l in self.log_file.read_text().splitlines()]

    def assertSucceeded(self, result):
        self.assertEqual(result.returncode, 0, msg=result.stdout + result.stderr)

    def assertFailed(self, result):
        self.assertNotEqual(result.returncode, 0, msg=result.stdout + result.stderr)
