"""backup.sh: the backup set, atomic completion, and 14-day retention."""
import hashlib
from datetime import datetime, timedelta, timezone

from harness import ScriptTestCase

NOW = datetime(2026, 10, 27, 3, 30, 0, tzinfo=timezone.utc)
STAMP = "20261027T033000Z"
FILES = ["evolution.dump", "evolution.rdb", "evolution_instances.tgz"]


def stamp(dt):
    return dt.strftime("%Y%m%dT%H%M%SZ")


class BackupTest(ScriptTestCase):
    def run_backup(self):
        return self.run_script("backup.sh", extra_env={"BACKUP_NOW": str(int(NOW.timestamp()))})

    def make_backup_dir(self, name):
        path = self.backup_dir / name
        path.mkdir(parents=True)
        (path / "evolution.dump").write_text("old")
        return path

    def test_writes_complete_backup_with_checksums(self):
        self.set_scenario({"pg_dump": "PGDMP", "rdb": "REDIS", "instances_tgz": "TGZ"})
        self.assertSucceeded(self.run_backup())

        out = self.backup_dir / f"evolution-{STAMP}"
        self.assertEqual(sorted(p.name for p in out.iterdir()), sorted(FILES + ["SHA256SUMS"]))
        self.assertEqual((out / "evolution.dump").read_text(), "PGDMP")
        sums = dict(
            reversed(line.split("  ")) for line in (out / "SHA256SUMS").read_text().splitlines()
        )
        for name in FILES:
            self.assertEqual(sums[name], hashlib.sha256((out / name).read_bytes()).hexdigest())
        self.assertEqual([p.name for p in self.backup_dir.glob(".*")], [])

    def test_dumps_through_compose_with_migration_flags(self):
        self.assertSucceeded(self.run_backup())
        pg = next(c for c in self.calls() if "postgres" in c and "exec" in c)
        self.assertIn("-Fc --no-owner --no-privileges", pg[-1])
        tar = next(c for c in self.calls() if c[0] == "run")
        self.assertIn("baja_evolution_instances:/src:ro", tar)

    def test_prunes_only_expired_complete_backups(self):
        expired = self.make_backup_dir(f"evolution-{stamp(NOW - timedelta(days=15))}")
        recent = self.make_backup_dir(f"evolution-{stamp(NOW - timedelta(days=13))}")
        unknown = self.make_backup_dir("evolution-handmade-copy")
        stale = self.make_backup_dir(".evolution-20261001T000000Z.partial")

        self.assertSucceeded(self.run_backup())

        self.assertFalse(expired.exists())
        self.assertTrue(recent.exists())
        self.assertTrue(unknown.exists(), "names that are not a timestamp are never deleted")
        self.assertFalse(stale.exists())

    def test_failure_keeps_old_backups_and_leaves_nothing_partial(self):
        expired = self.make_backup_dir(f"evolution-{stamp(NOW - timedelta(days=30))}")
        self.set_scenario({"fail_on": ["redis-cli"]})

        self.assertFailed(self.run_backup())

        self.assertTrue(expired.exists(), "no pruning after a failed run")
        self.assertEqual(sorted(p.name for p in self.backup_dir.iterdir()), [expired.name])

    def test_empty_dump_is_a_failure(self):
        self.set_scenario({"pg_dump": ""})
        result = self.run_backup()
        self.assertFailed(result)
        self.assertIn("evolution.dump is empty", result.stderr)
        self.assertFalse((self.backup_dir / f"evolution-{STAMP}").exists())

    def test_rejects_bad_retention(self):
        self.write_env(BACKUP_KEEP_DAYS="0")
        self.assertFailed(self.run_backup())
        self.assertEqual(self.calls(), [], "nothing is dumped with a bad config")
