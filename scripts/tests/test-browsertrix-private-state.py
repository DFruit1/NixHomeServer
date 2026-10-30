#!/usr/bin/env python3
"""WSD-002: prevent private-state disclosure and silent loss of rollback writes.

These focused regression tests are justified by the demonstrated old-worker
mutation of expanded jobs and Search's membership in the rollback service group.
No application build, live state, network, or production services are involved.
"""

import importlib.util
from pathlib import Path
import sqlite3
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
MODULE = Path(__file__).resolve().parents[2] / "modules/browsertrix-downloader/migrate-state.py"
SPEC = importlib.util.spec_from_file_location("private_state", MODULE)
migration = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(migration)


class PrivateStateTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix="browsertrix-private-state-")
        self.addCleanup(self.scratch.cleanup)
        root = Path(self.scratch.name)
        self.source = root / "legacy.sqlite"
        self.destination = root / "v2.sqlite"
        self.legacy = sqlite3.connect(self.source)
        self.addCleanup(self.legacy.close)
        self.legacy.executescript(
            "PRAGMA journal_mode=WAL;"
            "CREATE TABLE jobs(id TEXT PRIMARY KEY,status TEXT,request_json TEXT);"
            "CREATE TABLE job_events(id INTEGER PRIMARY KEY AUTOINCREMENT,message TEXT);"
            "INSERT INTO jobs VALUES('legacy','completed','{}');"
            "INSERT INTO job_events(message) VALUES('original event');"
        )

    def digest(self, path):
        with migration.connection(path, "ro") as db:
            return migration.logical_digest(db)

    def test_import_includes_uncheckpointed_wal_without_mutating_source(self):
        before = self.digest(self.source)
        migration.provision(self.source, self.destination)
        self.assertEqual(self.digest(self.source), before)
        with migration.connection(self.destination, "ro") as db:
            self.assertEqual(db.execute("SELECT * FROM jobs").fetchall(), [("legacy", "completed", "{}")])
            self.assertEqual(db.execute("SELECT message FROM job_events").fetchall(), [("original event",)])
        self.assertEqual(self.destination.stat().st_mode & 0o777, 0o600)
        migration.provision(self.source, self.destination, check=True)

    def test_restart_after_rollback_write_preserves_both_histories_and_refuses(self):
        migration.provision(self.source, self.destination)
        with migration.connection(self.destination, "rw") as db:
            db.execute("INSERT INTO jobs VALUES('new-private','paused','{\"profile\":true}')")
            db.commit()
        self.legacy.execute("INSERT INTO jobs VALUES('rollback-write','queued','{}')")
        self.legacy.commit()
        source_before = self.digest(self.source)
        private_before = self.digest(self.destination)
        # Check is the API/worker ExecStartPre path, independent of the oneshot.
        for check in (True, False):
            with self.assertRaisesRegex(ValueError, "both histories retained"):
                migration.provision(self.source, self.destination, check=check)
        self.assertEqual(self.digest(self.source), source_before)
        self.assertEqual(self.digest(self.destination), private_before)

    def test_deletion_in_rollback_database_is_also_divergence(self):
        migration.provision(self.source, self.destination)
        self.legacy.execute("DELETE FROM jobs")
        self.legacy.commit()
        with self.assertRaisesRegex(ValueError, "Legacy database changed"):
            migration.provision(self.source, self.destination, check=True)

    def test_checkpoint_and_vacuum_are_not_new_legacy_history(self):
        migration.provision(self.source, self.destination)
        self.legacy.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        self.legacy.execute("VACUUM")
        self.legacy.execute("ANALYZE")
        migration.provision(self.source, self.destination, check=True)

    def test_expanded_source_is_preserved_and_refused(self):
        self.legacy.execute("ALTER TABLE jobs ADD COLUMN runtime_json TEXT DEFAULT '{}'")
        self.legacy.commit()
        before = self.digest(self.source)
        with self.assertRaisesRegex(ValueError, "already contains expanded"):
            migration.provision(self.source, self.destination)
        self.assertFalse(self.destination.exists())
        self.assertEqual(self.digest(self.source), before)

    def test_existing_database_without_receipt_is_never_overwritten(self):
        with migration.connection(self.destination, "rwc") as db:
            db.execute("CREATE TABLE irreplaceable(content TEXT)")
        before = self.digest(self.destination)
        with self.assertRaisesRegex(ValueError, "lacks its import receipt"):
            migration.provision(self.source, self.destination)
        self.assertEqual(self.digest(self.destination), before)

    def test_failed_publication_leaves_no_partial_database(self):
        before = self.digest(self.source)
        with patch.object(migration.os, "link", side_effect=OSError("interrupted publication")):
            with self.assertRaises(OSError):
                migration.provision(self.source, self.destination)
        self.assertFalse(self.destination.exists())
        self.assertFalse(list(self.destination.parent.glob(".private-import-*")))
        self.assertEqual(self.digest(self.source), before)
        migration.provision(self.source, self.destination)

    def test_reserved_lock_prevents_old_writer_racing_copy(self):
        real_link = migration.os.link

        def publish(source, destination):
            with sqlite3.connect(self.source, timeout=0) as writer:
                with self.assertRaisesRegex(sqlite3.OperationalError, "locked"):
                    writer.execute("INSERT INTO jobs VALUES('racing','queued','{}')")
            real_link(source, destination)

        with patch.object(migration.os, "link", side_effect=publish):
            migration.provision(self.source, self.destination)
        migration.provision(self.source, self.destination, check=True)

    def test_symlink_and_same_path_are_refused(self):
        with self.assertRaisesRegex(ValueError, "separate paths"):
            migration.provision(self.source, self.source)
        self.destination.symlink_to(self.source)
        with self.assertRaises(ValueError):
            migration.provision(self.source, self.destination)
        self.destination.unlink()
        other = self.source.parent / "linked.sqlite"
        other.symlink_to(self.source)
        with self.assertRaisesRegex(ValueError, "non-regular"):
            migration.provision(other, self.destination)

    def test_fresh_install_detects_legacy_database_created_by_later_rollback(self):
        absent = self.source.parent / "never-existed.sqlite"
        migration.provision(absent, self.destination)
        migration.provision(absent, self.destination, check=True)
        with sqlite3.connect(absent) as db:
            db.execute("CREATE TABLE jobs(id TEXT)")
            db.execute("INSERT INTO jobs VALUES('rollback-write')")
        with self.assertRaisesRegex(ValueError, "Legacy database changed"):
            migration.provision(absent, self.destination, check=True)


if __name__ == "__main__":
    unittest.main()
