#!/usr/bin/env bash
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
python3 -B - "$repo" <<'PY'
import importlib.util
import ast
import types
import contextlib
import io
import os
from unittest.mock import patch
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


class ReviewSkillsTest(unittest.TestCase):
    def setUp(self):
        self.db=sqlite3.connect(':memory:');self.db.row_factory=sqlite3.Row
        self.addCleanup(self.db.close)
        self.db.executescript("""
            CREATE TABLE tasks(id TEXT,assignee TEXT,status TEXT,current_run_id INTEGER);
            CREATE TABLE task_runs(id INTEGER,task_id TEXT,profile TEXT,status TEXT,outcome TEXT,ended_at INTEGER);
            CREATE TABLE task_events(id INTEGER,task_id TEXT,kind TEXT,run_id INTEGER,payload TEXT,created_at INTEGER);
            INSERT INTO tasks VALUES('t_review','feature-reviewer','review',NULL);
            INSERT INTO task_runs VALUES(42,'t_review','head-coordinator','review','review_requested',100);
            INSERT INTO task_events VALUES(10,'t_review','review_requested',42,
                '{"implementer":"head-coordinator","reviewer":"feature-reviewer"}',100);
        """)
        self.skills=['kanban-orchestration','systematic-debugging','unknown-required-skill']

    def effective(self,assignee='feature-reviewer'):
        before=list(self.db.iterdump())
        result=policy.execution_skills(self.db,'t_review',assignee,self.skills)
        self.assertEqual(before,list(self.db.iterdump()))
        self.assertEqual('kanban-orchestration',self.skills[0])
        return result

    def running(self):
        self.db.executescript("""
            UPDATE tasks SET status='running',current_run_id=43;
            INSERT INTO task_runs VALUES(43,'t_review','feature-reviewer','running',NULL,NULL);
            INSERT INTO task_events VALUES(11,'t_review','claimed',43,'{"source_status":"review"}',101);
        """)

    def test_only_coordinator_skill_removed_and_other_requirements_retained(self):
        self.assertEqual(self.skills[1:],self.effective())
        self.assertEqual(self.skills,self.effective('head-coordinator'))
        self.assertEqual(self.skills,self.effective('standard-implementer'))
        self.db.execute("UPDATE task_runs SET status='review_requested' WHERE id=42")
        self.assertEqual(self.skills[1:],self.effective())
        self.running();self.assertEqual(self.skills[1:],self.effective())

    def test_each_intervening_lifecycle_transition_retains_original_pins(self):
        for kind in ['changes_requested','review_reopened','completed','assigned','reclaimed']:
            with self.subTest(kind=kind):
                self.db.execute('INSERT INTO task_events VALUES(11,?,?,?,?,?)',('t_review',kind,42,'{}',101))
                self.assertEqual(self.skills,self.effective())
                self.db.execute('DELETE FROM task_events WHERE id=11')

    def test_invalid_handoff_or_producer_never_drops_a_pin(self):
        for payload in ['broken','[]','null','{}',
                '{"implementer":"head-coordinator","reviewer":"project-auditor"}',
                '{"implementer":"feature-reviewer","reviewer":"feature-reviewer"}']:
            with self.subTest(payload=payload):
                before=self.db.execute('SELECT payload FROM task_events').fetchone()[0]
                self.db.execute('UPDATE task_events SET payload=?',(payload,))
                self.assertEqual(self.skills,self.effective())
                self.db.execute('UPDATE task_events SET payload=?',(before,))
        for clause in ["profile='feature-reviewer'", "task_id='t_other'", "status='done'", "outcome='completed'"]:
            with self.subTest(clause=clause):
                self.db.execute('SAVEPOINT producer')
                self.db.execute('UPDATE task_runs SET '+clause)
                self.assertEqual(self.skills,self.effective())
                self.db.execute('ROLLBACK TO producer');self.db.execute('RELEASE producer')
        self.db.execute('DELETE FROM task_runs')
        self.assertEqual(self.skills,self.effective())

    def test_running_requires_current_native_review_claim(self):
        self.running()
        for clause in ["current_run_id=NULL", "current_run_id=42", "status='ready'", "assignee='head-coordinator'"]:
            with self.subTest(clause=clause):
                self.db.execute('SAVEPOINT task')
                self.db.execute('UPDATE tasks SET '+clause)
                self.assertEqual(self.skills,self.effective())
                self.db.execute('ROLLBACK TO task');self.db.execute('RELEASE task')
        for clause in ["profile='head-coordinator'", "task_id='t_other'", "status='done'", "ended_at=102", "outcome='completed'"]:
            with self.subTest(clause=clause):
                self.db.execute('SAVEPOINT run')
                self.db.execute('UPDATE task_runs SET '+clause+' WHERE id=43')
                self.assertEqual(self.skills,self.effective())
                self.db.execute('ROLLBACK TO run');self.db.execute('RELEASE run')
        for clause in ["payload='{}'", "payload='[]'", "payload='broken'",
                "payload='{"+'"source_status":"ready"'+"}'", "created_at=99", "id=9", "run_id=42"]:
            with self.subTest(clause=clause):
                self.db.execute('SAVEPOINT claim')
                self.db.execute('UPDATE task_events SET '+clause+' WHERE id=11')
                self.assertEqual(self.skills,self.effective())
                self.db.execute('ROLLBACK TO claim');self.db.execute('RELEASE claim')
        self.db.execute('DELETE FROM task_events WHERE id=11')
        self.assertEqual(self.skills,self.effective())


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
                '    try:\n        pid = _call_spawn_fn(spawn)\n'
                '    except Exception:\n        pass\n'
                '    if lane == \"review\":\n'
                '        claimed.skills = list(dict.fromkeys([*(claimed.skills or []), \"sdlc-review\"]))\n'
                '    return True\n'
                'def reservation():\n    for row in rows:\n'
                '        if check_respawn_guard(conn, row["id"], lane="review") is None:\n'
                '            return True\n    return False\n'),
        }

    def test_transformed_native_review_reservation_uses_dispatch_policy(self):
        # Execute the real upstream reservation AND lane-selection functions.
        # Only effects/profile lookups are replaced; no live board is opened.
        native = (Path(os.environ['HERMES_FIXTURE_NATIVE_PYTHON']).parents[2]
                  if os.environ.get('HERMES_FIXTURE_NATIVE_PYTHON')
                  else Path.home()/'.hermes/hermes-agent')
        text = adapt('kanban_db_dispatch.py',
                     (native/'hermes_cli/kanban_db_dispatch.py').read_text())
        names = {'_any_spawnable_review', '_dispatch_ready_and_review_lanes'}
        functions = [node for node in ast.parse(text).body
                     if isinstance(node, ast.FunctionDef) and node.name in names]
        self.assertEqual(names, {node.name for node in functions})
        reasons = {'t_held': 'skill unavailable'}
        calls = []
        def reason(conn, task_id, assignee):
            return reasons.get(task_id)
        def dispatch(conn, row, assignee, result, **kwargs):
            if reason(conn, row['id'], assignee) is not None:
                return False
            calls.append((row['id'], kwargs['lane']))
            return True
        namespace = {
            '_profile_exists_fn': lambda: lambda name: True,
            'per_profile_cap_for': lambda caps, name: None,
            '_cap_accounting_key': lambda name: name,
            'check_respawn_guard': lambda *a, **kw: None,
            '_resolve_default_assignee': lambda name: name,
            '_dispatch_lane_task': dispatch,
        }
        exec('from __future__ import annotations\n' + ast.unparse(
            ast.Module(body=functions, type_ignores=[])), namespace)
        fake = types.ModuleType('hermes_cli')
        fake.nixhomeserver_worker_policy = types.SimpleNamespace(reason=reason)
        db = sqlite3.connect(':memory:')
        self.addCleanup(db.close)
        db.execute('CREATE TABLE evidence(value TEXT)')
        db.execute("INSERT INTO evidence VALUES('unchanged')")
        before = list(db.iterdump())
        ready = [{'id': 't_ready', 'assignee': 'standard-implementer'}]
        held = {'id': 't_held', 'assignee': 'feature-reviewer'}
        admitted = {'id': 't_admitted', 'assignee': 'feature-reviewer'}
        with patch.dict(sys.modules, {'hermes_cli': fake}):
            for reviews, expected in [([held], [('t_ready', 'ready')]),
                    ([admitted], [('t_admitted', 'review')]),
                    ([held, admitted], [('t_admitted', 'review')])]:
                with self.subTest(reviews=reviews):
                    calls.clear()
                    namespace['_dispatch_ready_and_review_lanes'](db, object(),
                        ready_rows=ready, review_rows=reviews, dry_run=True,
                        ttl_seconds=None, board='fixture', failure_limit=2,
                        spawn_fn=None, per_profile_caps=None, per_profile_running={},
                        spawn_budget=1, default_assignee=None)
                    self.assertEqual(expected, calls)
                    self.assertEqual(before, list(db.iterdump()))

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

    def test_block_removal_converges_and_refuses_ambiguous_markers(self):
        # Root scope must converge to the absence of the block, and a damaged
        # section is refused for manual reconciliation rather than guessed at.
        from hermes_common import remove_block
        start,end=installer.START,installer.END
        block=start+'\nOld budget block.\n'+end+'\n'
        for text,expected in (('Routing only.\n\n'+block,'Routing only.\n'),
                              ('Routing only.\n','Routing only.\n'),
                              ('Routing only.\n\n'+block+'\nLater note.\n',
                               'Routing only.\n\nLater note.\n')):
            removed=remove_block(text,start,end,'worker instruction')
            self.assertEqual(expected,removed)
            self.assertEqual(removed,remove_block(removed,start,end,'worker instruction'))
        for text in (start,end,start+end+end,start+start+end,end+start):
            with self.assertRaises(ValueError):remove_block(text,start,end)

    def test_learning_trials_are_opt_in_and_refuse_worker_context(self):
        import os
        script=source.parent/'background-learning-trials.py'
        listed=subprocess.run([sys.executable,'-B',str(script)],capture_output=True,text=True)
        self.assertEqual(0,listed.returncode)
        env=dict(os.environ,HERMES_KANBAN_TASK='t_fixture',HERMES_DELEGATED_CHILD_CONTEXT='fixture')
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
            # The retired default profile only routes: an old budget block is
            # removed, and lane SOULs receive the block.
            (root/'SOUL.md').write_text('Operator instructions\n\n' + installer.START
                                        + '\nOld budget block.\n' + installer.END + '\n')
            for lane in ('head-coordinator', 'project-auditor'):
                (root/'profiles'/lane).mkdir(parents=True)
                (root/'profiles'/lane/'SOUL.md').write_text('# ' + lane + '\n')
            original={p:p.read_bytes() for p in root.rglob('*') if p.is_file()}
            self.assertEqual(1,installer.install(root,True))
            self.assertEqual(original,{p:p.read_bytes() for p in root.rglob('*') if p.is_file()})
            self.assertEqual(0,installer.install(root))
            self.assertEqual(0,installer.install(root,True))
            self.assertEqual('Operator instructions\n', (root/'SOUL.md').read_text())
            for lane in ('head-coordinator', 'project-auditor'):
                self.assertIn(installer.START,
                              (root/'profiles'/lane/'SOUL.md').read_text())
            self.assertEqual(0o640,config.stat().st_mode & 0o777)
            config.write_text('model: {provider: custom, default: local}\n')
            (native/'kanban_db_dispatch.py').write_text('incompatible native source')
            with self.assertRaises(ValueError):installer.install(root)
            self.assertEqual('model: {provider: custom, default: local}\n',config.read_text())


with patch.dict(os.environ):
    os.environ.pop('HERMES_DELEGATED_CHILD_CONTEXT', None)
    os.environ.pop('HERMES_KANBAN_TASK', None)
    unittest.main(argv=[sys.argv[0]])
PY
