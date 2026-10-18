#!/usr/bin/env bash
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
python3 -B - "$repo" <<'PY'
import importlib.util
import contextlib
import io
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import unittest

source = Path(sys.argv[1]) / 'scripts/hermes/worker-policy.py'
spec = importlib.util.spec_from_file_location('policy', source)
policy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(policy)
sys.path.insert(0, str(source.parent))
spec = importlib.util.spec_from_file_location('installer', source.parent / 'install-worker-policy.py')
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)
from worker_runtime_adapter import adapt, EDITS


class WorkerPolicyTest(unittest.TestCase):
    def setUp(self):
        self.db = sqlite3.connect(':memory:')
        self.db.row_factory = sqlite3.Row
        self.db.executescript('''
          CREATE TABLE tasks(id TEXT, assignee TEXT, body TEXT,
                             max_runtime_seconds INTEGER, max_retries INTEGER);
          CREATE TABLE task_runs(id INTEGER, task_id TEXT, status TEXT,
                                 outcome TEXT, ended_at INTEGER);
          CREATE TABLE task_comments(id INTEGER, task_id TEXT, author TEXT,
                                     body TEXT, created_at INTEGER);
        ''')
        self.addCleanup(self.db.close)

    def task(self, assignee='standard-implementer', body='', cap=600, retries=1):
        self.db.execute('INSERT INTO tasks VALUES(?,?,?,?,?)',
                        ('t_test', assignee, body, cap, retries))

    def test_local_assignment_requires_positive_integer_cap(self):
        for cap in (None, 0, -1, True, 1.5, '600'):
            with self.subTest(cap=cap), self.assertRaises(ValueError):
                policy.creation('local-implementer', '', cap, None)
        self.assertIsNone(policy.creation('local-implementer', '', 600, None))
        self.assertIsNone(policy.creation('standard-implementer', '', None, None))

    def test_evidence_card_uses_native_first_failure_breaker(self):
        body='Recovery mode: evidence-only\nReturn the preserved receipt.'
        self.assertEqual(1, policy.creation('standard-implementer', body, 600, None))
        with self.assertRaises(ValueError):
            policy.creation('standard-implementer', body, 600, 3)
        with self.assertRaises(ValueError):
            policy.creation('standard-implementer', body, None, 1)
        self.assertIsNone(policy.creation('standard-implementer', 'Discuss recovery modes.', None, None))

    def test_dispatch_catches_legacy_and_edited_local_cards(self):
        self.task(assignee='local-implementer', cap=None)
        self.assertIn('runtime', policy.reason(self.db, 't_test'))
        self.db.execute('UPDATE tasks SET max_runtime_seconds=300')
        self.assertIsNone(policy.reason(self.db, 't_test'))

    def test_evidence_retry_requires_new_coordinator_receipt_for_exact_run(self):
        self.task(body='Recovery mode: evidence-only')
        self.assertIsNone(policy.reason(self.db, 't_test'))
        self.db.execute("INSERT INTO task_runs VALUES(7,'t_test','timed_out','timed_out',100)")
        self.assertIn('Recovery run: 7', policy.reason(self.db, 't_test'))
        receipt='Recovery run: 7\nRecovery change: Source receipt is now attached.\nRecovery action: Read only that attachment and return the receipt.'
        for author, timestamp, body in (
            ('standard-implementer', 101, receipt),
            ('head-coordinator', 99, receipt),
            ('head-coordinator', 101, receipt.replace('run: 7','run: 6')),
            ('head-coordinator', 101, 'Recovery run: 7\nRecovery change: \nRecovery action: retry'),
        ):
            self.db.execute('DELETE FROM task_comments')
            self.db.execute('INSERT INTO task_comments VALUES(1,?,?,?,?)',('t_test',author,body,timestamp))
            self.assertIsNotNone(policy.reason(self.db, 't_test'))
        self.db.execute('INSERT INTO task_comments VALUES(2,?,?,?,?)',('t_test','head-coordinator',receipt,101))
        self.assertIsNone(policy.reason(self.db, 't_test'))
        self.db.execute("INSERT INTO task_runs VALUES(8,'t_test','crashed','crashed',102)")
        self.assertIn('Recovery run: 8', policy.reason(self.db, 't_test'))

    def test_normal_tasks_and_completed_evidence_are_unchanged(self):
        self.task()
        self.db.execute("INSERT INTO task_runs VALUES(7,'t_test','timed_out','timed_out',100)")
        self.assertIsNone(policy.reason(self.db, 't_test'))
        self.db.execute("UPDATE tasks SET body='Recovery mode: evidence-only'")
        self.db.execute("UPDATE task_runs SET status='done',outcome='completed'")
        self.assertIsNone(policy.reason(self.db, 't_test'))


class InstallerTest(unittest.TestCase):
    @staticmethod
    def native_fixtures():
        return {
            'kanban_db.py': ('def create():\n    assignee = _canonical_assignee(assignee)\n'
                             '    if not title:\n        raise ValueError()\n'
                             'def unblock():\n    with write_txn(conn):\n'
                             '        resume_status = (\n            "ready"\n        )\n'),
            'kanban_db_dispatch.py': ('def dispatch():\n'
                "    # Per-profile cap: one profile's local model / API quota / browser pool\n"
                '    if claimed is None:\n        return False\n    try:\n        resolved_branch_name = None\n'
                '    except Exception:\n        pass\n'
                '    return True\n'),
        }

    def test_title_edit_preserves_all_other_settings_and_comments(self):
        from hermes_config import document
        for text in ('model: {default: test}\n',
                     'auxiliary:\n  approval:\n    model: test\nother: 42\n',
                     'auxiliary:\n  title_generation:\n    # Preserve me\n    model: test\nother: 42\n',
                     'auxiliary:\n  title_generation:\n    model_upgrade_enabled: true # annotation\nother: 42\n'):
            updated = installer.derived_titles(text)
            expected = document(text)
            expected.setdefault('auxiliary', {}).setdefault('title_generation', {})['model_upgrade_enabled'] = False
            self.assertEqual(expected, document(updated))
            self.assertEqual(updated, installer.derived_titles(updated))
            if '# Preserve me' in text:self.assertIn('# Preserve me', updated)
            if '# annotation' in text:self.assertIn('# annotation', updated)

    def test_native_adapter_is_idempotent_and_refuses_incompatible_sources(self):
        for name, text in self.native_fixtures().items():
            updated = adapt(name, text)
            self.assertEqual(updated, adapt(name, updated))
            with self.assertRaises(ValueError):adapt(name, 'def unrelated():\n    pass\n')

    def test_instruction_block_preserves_operator_sections(self):
        text='Operator policy stays.\n'
        updated=installer.instruction(text)
        self.assertTrue(updated.startswith(text))
        self.assertEqual(updated, installer.instruction(updated))

    def test_learning_trials_are_opt_in_and_refuse_worker_context(self):
        import os
        script=source.parent/'background-learning-trials.py'
        listed=subprocess.run([sys.executable,'-B',str(script)],capture_output=True,text=True)
        self.assertEqual(0,listed.returncode)
        env=dict(os.environ,HERMES_KANBAN_TASK='t_fixture')
        refused=subprocess.run([sys.executable,'-B',str(script),'--live'],env=env,capture_output=True,text=True)
        self.assertEqual(2,refused.returncode)
        self.assertIn('worker pins remain binding',refused.stderr)

    def test_install_check_is_readonly_and_install_converges(self):
        with tempfile.TemporaryDirectory(prefix='hermes-worker-policy-') as directory, contextlib.redirect_stdout(io.StringIO()):
            root=Path(directory)
            native=root/'hermes-agent/hermes_cli'; native.mkdir(parents=True)
            for name,text in self.native_fixtures().items():(native/name).write_text(text)
            config=root/'profiles/local-implementer/config.yaml';config.parent.mkdir(parents=True)
            config.write_text('model: {provider: custom, default: local}\n')
            config.chmod(0o640)
            (root/'SOUL.md').write_text('Operator instructions\n')
            original={p:p.read_bytes() for p in root.rglob('*') if p.is_file()}
            self.assertEqual(1,installer.install(root,True))
            self.assertEqual(original,{p:p.read_bytes() for p in root.rglob('*') if p.is_file()})
            self.assertEqual(0,installer.install(root))
            self.assertEqual(0,installer.install(root,True))
            self.assertEqual(0o640,config.stat().st_mode & 0o777)
            config.write_text('model: {provider: custom, default: local}\n')
            (native/'kanban_db_dispatch.py').write_text('incompatible native source')
            with self.assertRaises(ValueError):installer.install(root)
            self.assertEqual('model: {provider: custom, default: local}\n',config.read_text())


unittest.main(argv=[sys.argv[0]])
PY
