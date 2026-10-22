#!/usr/bin/env bash
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
python3 -B - "$repo" <<'PY'
import hashlib
import importlib.util
import json
from pathlib import Path
import sqlite3
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(sys.argv[1]) / 'scripts/hermes'))
spec = importlib.util.spec_from_file_location('evidence', Path(sys.argv[1]) / 'scripts/hermes/fleet-evidence.py')
evidence = importlib.util.module_from_spec(spec)
spec.loader.exec_module(evidence)


class EvidenceTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='fleet-evidence-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.board = self.root / 'kanban/boards/project'
        self.board.mkdir(parents=True)
        self.db = sqlite3.connect(self.board / 'kanban.db')
        self.addCleanup(self.db.close)
        self.db.executescript('''CREATE TABLE tasks(id TEXT, status TEXT, assignee TEXT);
        CREATE TABLE task_runs(id INTEGER,task_id TEXT,profile TEXT,status TEXT,outcome TEXT,
          metadata TEXT,started_at INTEGER,ended_at INTEGER);
        CREATE TABLE task_attachments(id INTEGER,task_id TEXT,stored_path TEXT,size INTEGER);
        CREATE TABLE task_events(id INTEGER,task_id TEXT,kind TEXT,payload TEXT);''')
        self.file = self.board / 'attachments/t_output/result.txt'
        self.file.parent.mkdir(parents=True)
        self.file.write_bytes(b'qualified output')
        self.sha = hashlib.sha256(self.file.read_bytes()).hexdigest()
        self.metadata = {'verdict': 'accept', 'revision': 'a' * 40,
            'checks': [{'command': 'actual check', 'exit_code': 0}],
            'outputs': [{'name': 'result', 'version': 1, 'attachment_id': 1, 'sha256': self.sha}]}
        self.db.execute("INSERT INTO tasks VALUES ('t_output','done','feature-reviewer')")
        self.db.execute("INSERT INTO task_attachments VALUES (1,'t_output',?,16)", (str(self.file),))
        self.save()

    def save(self):
        self.db.execute('DELETE FROM task_runs')
        self.db.execute("INSERT INTO task_runs VALUES (1,'t_output','feature-reviewer','done','completed',?,10,20)",
                        (json.dumps(self.metadata),))
        self.db.commit()

    def test_output_binds_completed_run_revision_and_actual_artifact(self):
        result = evidence.output(self.root, 'project', 't_output', 'result', 1)
        self.assertEqual((1, 'a'*40, self.sha), (result['run_id'], result['revision'], result['sha256']))
        before = (self.board / 'kanban.db').read_bytes()
        evidence.output(self.root, 'project', 't_output', 'result', 1)
        self.assertEqual(before, (self.board / 'kanban.db').read_bytes())
        self.file.write_bytes(b'changed output')
        with self.assertRaises(ValueError):
            evidence.output(self.root, 'project', 't_output', 'result', 1)

    def test_done_and_declared_hash_are_insufficient(self):
        for verdict in ('unknown', 'request-changes', None):
            self.metadata['verdict'] = verdict
            self.save()
            with self.assertRaises(ValueError):
                evidence.output(self.root, 'project', 't_output', 'result', 1)

    def test_collector_is_automatic_idempotent_and_retains_failures(self):
        self.metadata = {'checks': [{'command': 'actual check', 'exit_code': 1}]}
        self.save()
        self.db.execute("UPDATE task_runs SET status='failed',outcome='timed_out'")
        self.db.commit()
        self.assertEqual(1, evidence.collect(self.root))
        self.assertEqual(0, evidence.collect(self.root))
        packet = json.loads((self.root / 'state/fleet/evidence/project/t_output/1.json').read_text())
        self.assertEqual('timed_out', packet['outcome'])
        self.assertEqual(1, packet['checks'][0]['exit_code'])
        self.assertNotIn('verdict', packet)

    def test_paths_and_symlink_escape_are_refused(self):
        for board in ('../project', '/project'):
            with self.assertRaises(ValueError):
                evidence.output(self.root, board, 't_output', 'result', 1)
        self.file.unlink()
        self.file.symlink_to('/etc/hostname')
        with self.assertRaises(ValueError):
            evidence.output(self.root, 'project', 't_output', 'result', 1)

    def test_malformed_historical_metadata_does_not_hide_newer_runs(self):
        self.db.execute("UPDATE task_runs SET metadata='not json'")
        self.db.execute("INSERT INTO task_runs VALUES (2,'t_output','standard-implementer','failed','timed_out','{}',21,22)")
        self.db.commit()
        self.assertEqual(2,evidence.collect(self.root))
        directory=self.root/'state/fleet/evidence/project/t_output'
        self.assertIn('metadata_error',json.loads((directory/'1.json').read_text()))
        self.assertTrue((directory/'2.json').exists())

    def test_reusing_an_output_version_for_changed_source_is_refused(self):
        old={**self.metadata,'revision':'b'*40}
        self.db.execute("INSERT INTO task_runs VALUES (0,'t_output','feature-reviewer','done','completed',?,1,2)",
                        (json.dumps(old),))
        self.db.commit()
        with self.assertRaises(ValueError):
            evidence.output(self.root,'project','t_output','result',1)


unittest.main(argv=[sys.argv[0]])
PY
