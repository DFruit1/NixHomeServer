#!/usr/bin/env bash
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
python3 -B - "$repo" <<'PY'
import importlib.util
import json
from pathlib import Path
import sqlite3
import sys
import tempfile
import unittest
import os
import subprocess
from unittest.mock import patch

source = Path(sys.argv[1]) / 'scripts/hermes/review-verdict-guard.py'
sys.path.insert(0, str(source.parent))
spec = importlib.util.spec_from_file_location('verdict_guard', source)
guard_mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard_mod)

DAY = 86400
NOW = 1_700_000_000
SCHEMA = """
CREATE TABLE tasks (
    id TEXT PRIMARY KEY, title TEXT, body TEXT, assignee TEXT, status TEXT,
    priority INTEGER DEFAULT 0, created_at INTEGER, block_kind TEXT,
    idempotency_key TEXT, consecutive_failures INTEGER DEFAULT 0, tenant TEXT, current_run_id INTEGER,
    workspace_kind TEXT, workspace_path TEXT, project_id TEXT
);
CREATE TABLE task_comments (id INTEGER PRIMARY KEY AUTOINCREMENT, task_id TEXT, body TEXT);
CREATE TABLE task_events (id INTEGER PRIMARY KEY AUTOINCREMENT, task_id TEXT,
    kind TEXT, payload TEXT, created_at INTEGER);
CREATE TABLE task_links (parent_id TEXT, child_id TEXT);
CREATE TABLE task_runs (id INTEGER PRIMARY KEY AUTOINCREMENT, task_id TEXT,
    profile TEXT, status TEXT, outcome TEXT, metadata TEXT,
    started_at INTEGER, ended_at INTEGER);
"""


def accept_run(rid, ended):
    return json.dumps({'verdict': 'accept', 'revision': rid, 'checks': [{'command': 'owning check', 'exit_code': 0}]}), ended


def changes_run(rid, ended):
    return (json.dumps({'verdict': 'request-changes', 'revision': rid,
                        'requested_changes': ['fix x'],
                        'checks': [{'command': 'prior check', 'exit_code': 1}]}),
            ended)


class VerdictGuardTest(unittest.TestCase):
    @unittest.skipUnless(os.environ.get('HERMES_REVIEW_GUARD_NATIVE_REPO'),
                         'opt-in real Hermes hook transport requires its Python environment')
    def test_native_hook_requires_explicit_scope_without_donating_worker_identity(self):
        # Run with the native Hermes Python and HERMES_REVIEW_GUARD_NATIVE_REPO.
        # Only synthetic board state is opened; no native mutation is executed.
        import hashlib
        import shlex
        self.card('t_old', assignee='feature-reviewer', tenant='verification')
        self.add_run('t_old', 'request-changes', NOW-1)
        self.card('t_fresh', assignee='feature-reviewer', status='running', tenant='verification')
        self.card('t_route', assignee='head-coordinator', status='todo')
        self.link('t_old', 't_fresh'); self.link('t_fresh', 't_route')
        before = hashlib.sha256(self.db_path.read_bytes()).hexdigest()
        home = self.root / 'profiles/feature-reviewer'; home.mkdir(parents=True)
        env = {'HERMES_ROOT': str(self.root), 'HERMES_HOME': str(home),
               'HERMES_DISABLE_LAZY_INSTALLS': '1',
               'HERMES_KANBAN_BOARD': 'testboard', 'HERMES_KANBAN_DB': str(self.db_path),
               'HERMES_KANBAN_TASK': 't_fresh', 'HERMES_KANBAN_RUN_ID': '1335'}
        with patch.dict(os.environ, env):
            sys.path.insert(0, os.environ['HERMES_REVIEW_GUARD_NATIVE_REPO'])
            import hermes_bootstrap
            from agent import shell_hooks
            from tools import kanban_tools
            from tools.environments.local import build_subprocess_env
            from agent.delegation_context import delegated_child_context
            self.assertEqual('t_fresh', kanban_tools._default_task_id(None))
            with self.assertRaises(kanban_tools._Reject):
                kanban_tools._enforce_worker_task_ownership('t_route')
            with delegated_child_context():
                self.assertIsNone(kanban_tools._default_task_id(None))
            spec = shell_hooks.ShellHookSpec(event='pre_tool_call',
                command=shlex.join([sys.executable, '-B', str(source)]),
                matcher='^kanban_complete$', timeout=10, fail_closed=True)
            callback = shell_hooks._make_callback(spec)
            metadata = json.loads(changes_run('rejected-revision', NOW)[0])
            for multiplex in (False, True):
                with self.subTest(multiplex=multiplex), patch('agent.secret_scope.is_multiplex_active', return_value=multiplex):
                    child_env = build_subprocess_env(scrub_secrets=multiplex)
                    self.assertNotIn('HERMES_KANBAN_TASK', child_env)
                    self.assertNotIn('HERMES_KANBAN_RUN_ID', child_env)
                    self.assertEqual('testboard', child_env['HERMES_KANBAN_BOARD'])
                    self.assertTrue(child_env['HERMES_DELEGATED_CHILD_CONTEXT'])
                    def call(**scope):
                        return callback(tool_name='kanban_complete', session_id='fixture-review',
                            args={'summary': 'Preserved rejection', 'metadata': metadata, 'artifacts': [], **scope})
                    missing = call()
                    self.assertEqual('block', missing['action'])
                    self.assertIn('exact board and task_id', missing['message'])
                    self.assertIsNone(call(board='testboard', task_id='t_fresh'))
                    for scope in ({'board': 'testboard'},
                                  {'board': '../testboard', 'task_id': 't_fresh'},
                                  {'board': 'testboard', 'task_id': 't_unknown'},
                                  {'board': 'wrongboard', 'task_id': 't_fresh'}):
                        self.assertEqual('block', call(**scope)['action'])
                    # Explicit delivery must not turn a previous rejection into acceptance.
                    metadata = json.loads(accept_run('rejected-revision', NOW)[0])
                    self.assertEqual('block', call(board='testboard', task_id='t_fresh')['action'])
                    metadata = json.loads(changes_run('rejected-revision', NOW)[0])
            self.assertEqual('t_fresh', os.environ['HERMES_KANBAN_TASK'])
            self.assertEqual('1335', os.environ['HERMES_KANBAN_RUN_ID'])
        self.assertEqual(before, hashlib.sha256(self.db_path.read_bytes()).hexdigest())

    def feature_create(self, **extra):
        return {'tool_name':'kanban_create','tool_input':{'board':'testboard',
                'title':'Feature slice','assignee':'standard-implementer',
                'body':'Feature tracker: testboard:t_tracker\nChange: custom_apps/app/source.rs only.',**extra}}

    def test_native_review_claims_need_canonical_implementation_marker_at_creation(self):
        for role in ('standard-implementer', 'local-implementer'):
            for claim in ('native-review-v1 lifecycle', 'NATIVE-REVIEW-V1 CONTRACT explicitly on this card'):
                with self.subTest(role=role, claim=claim):
                    payload = self.feature_create(assignee=role, body='Goal: bounded repair\n' + claim)
                    refused = guard_mod.guard(payload, self.root)
                    self.assertEqual('block', refused.get('action'))
                    self.assertIn('Workflow: native-review-v1', refused['message'])
            for body in ('Goal: bounded standalone diagnostic',
                         'Workflow: native-review-v1\nGoal: bounded repair'):
                self.assertEqual({}, guard_mod.guard(self.feature_create(assignee=role, body=body), self.root))
        for role in ('head-coordinator', 'feature-reviewer', 'project-auditor'):
            self.assertEqual({}, guard_mod.guard(self.feature_create(
                assignee=role, body='Discuss native-review-v1 evidence'), self.root))
        # Existing cards remain governed by their original completion contract.
        self.card('t_parent')
        self.card('t_legacy', assignee='standard-implementer', status='todo',
                  body='Historical native-review-v1 discussion')
        self.assertEqual({}, guard_mod.guard({'tool_name':'kanban_link', 'tool_input':{
            'board':'testboard', 'parent_id':'t_parent', 'child_id':'t_legacy'}}, self.root))

    def test_delivery_handoff_cannot_gate_its_own_input_but_decision_and_closure_can(self):
        self.card('t_delivery',assignee='head-coordinator',status='running',body='Feature tracker: testboard:t_tracker\nFeature handoff: delivery')
        for role in ('standard-implementer','feature-reviewer','project-auditor'):
            payload=self.feature_create(assignee=role,parents=['t_delivery'])
            self.assertEqual('block',guard_mod.guard(payload,self.root).get('action'))
        closure=self.feature_create(assignee='project-auditor',parents=['t_delivery'],body='Feature tracker: testboard:t_tracker\nFeature role: documentary-closure')
        self.assertEqual({},guard_mod.guard(closure,self.root))
        self.card('t_decision',assignee='head-coordinator',status='running',body='Feature tracker: testboard:t_tracker\nExact independent approval decision')
        self.assertEqual({},guard_mod.guard(self.feature_create(parents=['t_decision'],project='native-project'),self.root))
        self.card('t_input',assignee='feature-reviewer',status='todo',body='Feature tracker: testboard:t_tracker')
        self.assertEqual('block',guard_mod.guard({'tool_name':'kanban_link','tool_input':{'board':'testboard','parent_id':'t_delivery','child_id':'t_input'}},self.root).get('action'))

    def test_generated_delivery_recovery_requires_inputs_before_handoff(self):
        from deadlock_recovery import recovery_body
        issue = {'kind':'feature-delivery-gap', 'task_id':'t_tracker'}
        self.card('t_recovery', assignee='head-coordinator', status='running',
                  body=recovery_body('testboard', issue))
        self.card('t_plan', assignee='project-auditor', status='done')
        for role in ('standard-implementer', 'local-implementer', 'feature-reviewer', 'project-auditor'):
            with self.subTest(role=role):
                child = 't_' + role.replace('-', '_')
                body = 'Feature tracker: testboard:t_tracker\nDeliverable: bounded input'
                self.card(child, assignee=role, status='todo', body=body)
                payload = self.feature_create(assignee=role, body=body, parents=['t_recovery'])
                refused = guard_mod.guard(payload, self.root)
                self.assertEqual('block', refused.get('action'))
                self.assertIn('unfinished feature delivery handoff', refused['message'])
                payload['tool_input']['parents'] = ['t_plan']
                self.assertEqual({}, guard_mod.guard(payload, self.root))
                for parent, dependent, blocked in (('t_recovery', child, True),
                                                   ('t_plan', child, False),
                                                   (child, 't_recovery', False)):
                    linked = guard_mod.guard({'tool_name':'kanban_link', 'tool_input':{
                        'board':'testboard', 'parent_id':parent, 'child_id':dependent}}, self.root)
                    self.assertEqual('block' if blocked else None, linked.get('action'))
        closure_body = 'Feature tracker: testboard:t_tracker\nFeature role: documentary-closure'
        self.assertEqual({}, guard_mod.guard(self.feature_create(
            assignee='project-auditor', body=closure_body, parents=['t_recovery']), self.root))
        self.card('t_closure', assignee='project-auditor', status='todo', body=closure_body)
        self.assertEqual({}, guard_mod.guard({'tool_name':'kanban_link', 'tool_input':{
            'board':'testboard', 'parent_id':'t_recovery', 'child_id':'t_closure'}}, self.root))

    def test_generated_assessment_and_owner_repair_are_not_delivery_handoffs(self):
        from deadlock_recovery import recovery_body
        issue = {'kind':'feature-delivery-gap', 'task_id':'t_tracker'}
        for task, role, body in (
                ('t_assessment', 'project-auditor', recovery_body('testboard', issue, audit=True)),
                ('t_controller', 'head-coordinator', recovery_body(
                    'testboard', dict(issue, recovery_owner='t_existing')))):
            with self.subTest(task=task):
                self.assertNotIn('Feature handoff: delivery', body)
                self.card(task, assignee=role, status='running', body=body)
                self.assertEqual({}, guard_mod.guard(self.feature_create(
                    parents=[task], project='native-project'), self.root))

    def test_existing_repo_feature_cannot_launch_in_scratch_or_a_mistyped_root(self):
        for kwargs in ({},{'workspace_kind':'scratch','workspace_path':'/home/Projects/NixOS'},
                       {'workspace_kind':'worktree','workspace_path':str(self.root/'missing')},
                       {'workspace_kind':'worktree','workspace_path':str(self.root)}):
            self.assertEqual('block',guard_mod.guard(self.feature_create(**kwargs),self.root).get('action'))
        self.assertEqual({},guard_mod.guard(self.feature_create(body='Feature tracker: testboard:t_tracker\nDeliverable: standalone synthetic Rust prototype',workspace_kind='scratch'),self.root))
        self.assertEqual('block',guard_mod.guard(self.feature_create(body='Feature tracker: testboard:t_tracker. Trailing prose',project='native-project'),self.root).get('action'))

    def test_feature_source_assignment_uses_actual_git_root_exclusive_worktree_or_native_project(self):
        repo=self.root/'repo';repo.mkdir()
        subprocess.run(['git','init',str(repo)],check=True,capture_output=True)
        subprocess.run(['git','-C',str(repo),'-c','user.name=Fixture','-c','user.email=fixture@example.invalid','commit','--allow-empty','-m','Fixture'],check=True,capture_output=True)
        self.assertEqual({},guard_mod.guard(self.feature_create(workspace_kind='worktree',workspace_path=str(repo)),self.root))
        nested=repo/'nested';nested.mkdir()
        self.assertEqual('block',guard_mod.guard(self.feature_create(workspace_kind='worktree',workspace_path=str(nested)),self.root).get('action'))
        self.assertEqual('block',guard_mod.guard(self.feature_create(workspace_kind='dir',workspace_path=str(repo)),self.root).get('action'))
        work=self.root/'prepared'
        subprocess.run(['git','-C',str(repo),'worktree','add','--detach',str(work)],check=True,capture_output=True)
        payload=self.feature_create(workspace_kind='dir',workspace_path=str(work))
        self.assertEqual({},guard_mod.guard(payload,self.root))
        self.card('t_owner',assignee='standard-implementer',status='running')
        self.db.execute('UPDATE tasks SET workspace_path=? WHERE id=?',(str(work),'t_owner'));self.db.commit()
        self.assertEqual('block',guard_mod.guard(payload,self.root).get('action'))
        self.assertEqual({},guard_mod.guard(self.feature_create(project='native-project'),self.root))
        self.card('t_creator',assignee='head-coordinator',status='running')
        self.db.execute("UPDATE tasks SET project_id='native-project' WHERE id='t_creator'");self.db.commit()
        with patch.dict(os.environ,{'HERMES_KANBAN_TASK':'t_creator'}):
            self.assertEqual({},guard_mod.guard(self.feature_create(),self.root))
            for optout in ({'project':''},{'project_id':''}):
                self.assertEqual('block',guard_mod.guard(self.feature_create(**optout),self.root).get('action'))

    def test_feature_source_timeout_and_ambient_git_overrides_fail_closed(self):
        import capability_recovery
        repo=self.root/'repo';repo.mkdir()
        subprocess.run(['git','init',str(repo)],check=True,capture_output=True)
        subprocess.run(['git','-C',str(repo),'-c','user.name=Fixture','-c','user.email=fixture@example.invalid','commit','--allow-empty','-m','Fixture'],check=True,capture_output=True)
        payload=self.feature_create(workspace_kind='worktree',workspace_path=str(repo))
        with patch.object(capability_recovery.subprocess,'run',side_effect=subprocess.TimeoutExpired('git',.5)):
            self.assertEqual('block',guard_mod.guard(payload,self.root).get('action'))
        with patch.dict(os.environ,{'GIT_DIR':str(self.root/'wrong'),'GIT_WORK_TREE':str(self.root/'wrong'),'GIT_COMMON_DIR':str(self.root/'wrong')}):
            self.assertEqual({},guard_mod.guard(payload,self.root))

    def test_feature_comment_contract_survives_chatter_and_explicit_supersession(self):
        self.card('t_route',assignee='head-coordinator',status='running')
        self.db.execute('INSERT INTO task_comments(task_id,body) VALUES(?,?)',('t_route','Feature tracker: testboard:t_tracker\nFeature handoff: delivery'))
        for _ in range(25):self.db.execute('INSERT INTO task_comments(task_id,body) VALUES(?,?)',('t_route','Routine waiting comment'))
        self.db.commit()
        payload=self.feature_create(assignee='feature-reviewer',parents=['t_route'])
        self.assertEqual('block',guard_mod.guard(payload,self.root).get('action'))
        self.db.execute('INSERT INTO task_comments(task_id,body) VALUES(?,?)',('t_route','Feature handoff: approval-decision'));self.db.commit()
        self.assertEqual({},guard_mod.guard(payload,self.root))

    def test_prose_tracker_mentions_cannot_erase_delivery_routing_contract(self):
        self.card('t_route', assignee='head-coordinator', status='running',
                  body='Feature tracker: testboard:t_tracker\nFeature handoff: delivery')
        self.card('t_input', assignee='feature-reviewer', status='todo',
                  body='Feature tracker: testboard:t_tracker')
        self.db.execute('INSERT INTO task_comments(task_id,body) VALUES(?,?)',
                        ('t_route', 'Feature tracker: testboard:t_tracker. No owner input needed; supplier is agent.'))
        self.db.commit()
        for payload in (self.feature_create(assignee='feature-reviewer', parents=['t_route']),
                        {'tool_name':'kanban_link', 'tool_input':{
                            'board':'testboard', 'parent_id':'t_route', 'child_id':'t_input'}}):
            with self.subTest(tool=payload['tool_name']):
                refused = guard_mod.guard(payload, self.root)
                self.assertEqual('block', refused.get('action'))
                self.assertIn('unfinished feature delivery handoff', refused['message'])
        # A later valid marker still supersedes the earlier tracker explicitly.
        self.db.execute('INSERT INTO task_comments(task_id,body) VALUES(?,?)',
                        ('t_route', 'Feature tracker: testboard:t_new_tracker'))
        self.db.commit()
        with sqlite3.connect(self.db_path) as reader:
            reader.row_factory = sqlite3.Row
            contract = guard_mod._feature_contract(reader, reader.execute(
                'SELECT * FROM tasks WHERE id=?', ('t_route',)).fetchone())
        self.assertEqual('t_new_tracker', guard_mod.FEATURE.search(contract).group(2))

    def test_negative_verifier_can_report_despite_rejected_review_parent(self):
        self.card('t_old', assignee='feature-reviewer', tenant='verification')
        self.add_run('t_old', 'request-changes', NOW-1)
        self.card('t_fresh', assignee='feature-reviewer', status='running',
                  tenant='verification', body='First missing input: verdict=unknown')
        self.card('t_route', assignee='head-coordinator', status='todo')
        self.link('t_old', 't_fresh'); self.link('t_fresh', 't_route')
        for metadata in (json.loads(changes_run('fresh', NOW)[0]),
                         {'verdict':'unknown','missing_inputs':['exact source receipt']}):
            with self.subTest(verdict=metadata['verdict']):
                self.assertEqual({}, guard_mod.guard(self.complete_payload('t_fresh', metadata),self.root))
                self.card('t_consumer', assignee='standard-implementer', status='todo')
                self.link('t_fresh', 't_consumer')
                self.assertEqual('block', guard_mod.guard(self.complete_payload('t_fresh',metadata),self.root).get('action'))
                self.db.execute("DELETE FROM task_links WHERE child_id='t_consumer'")
                self.db.execute("DELETE FROM tasks WHERE id='t_consumer'"); self.db.commit()
        self.assertEqual('block', guard_mod.guard(self.complete_payload('t_fresh',json.loads(accept_run('fresh',NOW)[0])),self.root).get('action'))

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='verdict-guard-test-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        board = self.root / 'kanban' / 'boards' / 'testboard'
        board.mkdir(parents=True)
        self.db_path = board / 'kanban.db'
        self.db = sqlite3.connect(self.db_path)
        self.db.executescript(SCHEMA)
        self.addCleanup(self.db.close)

    def card(self, tid, assignee=None, status='done', created=None, tenant=None,
             body=''):
        self.db.execute(
            "INSERT INTO tasks (id, title, assignee, status, created_at, tenant,"
            " body) VALUES (?, 'x', ?, ?, ?, ?, ?)",
            (tid, assignee, status, created if created is not None else NOW - DAY,
             tenant, body))
        self.db.commit()

    def add_run(self, tid, verdict, ended, rid="r0", profile='feature-reviewer', **extra):
        row = accept_run(rid, ended) if verdict == 'accept' else changes_run(rid, ended)
        metadata = {**json.loads(row[0]), **extra}
        self.db.execute(
            "INSERT INTO task_runs (task_id, profile, status, outcome, metadata,"
            " ended_at) VALUES (?, ?, 'done', 'completed', ?, ?)",
            (tid, profile, json.dumps(metadata), row[1]))
        self.db.commit()

    def add_blocked_run(self, tid, ended):
        # An interrupted attempt: no verdict, no acceptance, but a real ended_at.
        self.db.execute(
            "INSERT INTO task_runs (task_id, profile, status, outcome, metadata,"
            " ended_at) VALUES (?, 'feature-reviewer', 'blocked', 'blocked', NULL, ?)",
            (tid, ended))
        self.db.commit()

    def link(self, parent, child):
        self.db.execute("INSERT INTO task_links (parent_id, child_id) VALUES (?,?)",
                        (parent, child))
        self.db.commit()

    def payload(self, parent, child):
        return {'tool_name': 'kanban_unlink',
                'tool_input': {'board': 'testboard', 'parent_id': parent,
                               'child_id': child}}

    def routed_rejection(self, *, source_status='running', route_status='todo', child_role='feature-reviewer'):
        self.card('t_review',assignee='feature-reviewer',status=source_status,tenant='verification')
        self.card('t_route',assignee='head-coordinator',status=route_status)
        self.card('t_consumer',assignee=child_role,status='todo')
        self.link('t_review','t_consumer')
        self.link('t_review','t_route')
        self.link('t_route','t_consumer')
        return self.payload('t_review','t_consumer')

    def test_pending_review_can_be_rerouted_without_dropping_its_gate(self):
        payload=self.routed_rejection()
        rejection={'verdict':'request-changes','revision':'r',
                   'checks':[{'command':'actual failing check','exit_code':1}],
                   'requested_changes':['repair actual failure']}
        self.assertEqual('block',guard_mod.guard(self.complete_payload('t_review',rejection),self.root).get('action'))
        self.assertEqual({},guard_mod.guard(payload,self.root))
        self.db.execute("DELETE FROM task_links WHERE parent_id='t_review' AND child_id='t_consumer'")
        self.db.commit()
        self.assertEqual({},guard_mod.guard(self.complete_payload('t_review',rejection),self.root))
        self.db.execute("UPDATE tasks SET status='done' WHERE id='t_review'")
        self.db.commit()
        self.add_run('t_review','request-changes',NOW)
        self.assertEqual('block',guard_mod.guard(self.complete_payload('t_route',{}),self.root).get('action'))
        self.assertEqual('block',guard_mod.guard(self.payload('t_route','t_consumer'),self.root).get('action'))
        self.assertEqual([('t_route',)],self.db.execute("SELECT parent_id FROM task_links WHERE child_id='t_consumer'").fetchall())

    def test_reroute_requires_both_legs_and_exact_edge(self):
        payload=self.routed_rejection()
        for parent,child in [('t_review','t_route'),('t_route','t_consumer'),('t_review','t_consumer')]:
            self.db.execute('DELETE FROM task_links WHERE parent_id=? AND child_id=?',(parent,child))
            self.db.commit()
            self.assertEqual('block',guard_mod.guard(payload,self.root).get('action'))
            self.link(parent,child)

    def test_reroute_refuses_completed_running_or_dispatchable_intermediary(self):
        payload=self.routed_rejection()
        for status in ('done','archived','running','ready'):
            self.db.execute("UPDATE tasks SET status=? WHERE id='t_route'",(status,))
            self.db.commit()
            self.assertEqual('block',guard_mod.guard(payload,self.root).get('action'))
        self.db.execute("UPDATE tasks SET status='todo' WHERE id='t_route'")
        self.db.execute("INSERT INTO task_runs(task_id,profile,status) VALUES ('t_route','head-coordinator','running')")
        self.db.commit()
        self.assertEqual('block',guard_mod.guard(payload,self.root).get('action'))

    def test_reroute_refuses_wrong_role_and_nested_coordinator_chain(self):
        payload=self.routed_rejection()
        self.db.execute("UPDATE tasks SET assignee='standard-implementer' WHERE id='t_route'")
        self.db.commit()
        self.assertEqual('block',guard_mod.guard(payload,self.root).get('action'))
        self.db.execute("UPDATE tasks SET assignee='head-coordinator' WHERE id='t_route'")
        self.db.execute("UPDATE tasks SET assignee='head-coordinator' WHERE id='t_consumer'")
        self.db.commit()
        self.assertEqual('block',guard_mod.guard(payload,self.root).get('action'))

    def test_inherited_gate_can_be_removed_after_acceptance_or_direct_restoration(self):
        self.routed_rejection(source_status='done')
        self.db.execute("DELETE FROM task_links WHERE parent_id='t_review' AND child_id='t_consumer'")
        self.db.commit()
        self.add_run('t_review','request-changes',NOW)
        payload=self.payload('t_route','t_consumer')
        self.assertEqual('block',guard_mod.guard(payload,self.root).get('action'))
        self.link('t_review','t_consumer')
        self.assertEqual({},guard_mod.guard(payload,self.root))
        self.db.execute("DELETE FROM task_links WHERE parent_id='t_review' AND child_id='t_consumer'")
        self.db.commit()
        self.add_run('t_review','accept',NOW+1)
        self.assertEqual({},guard_mod.guard(payload,self.root))

    def test_ordinary_prerequisite_unlinks_freely(self):
        self.card('t_p1', assignee='standard-implementer')
        self.card('t_c1', assignee='standard-implementer', status='todo')
        self.link('t_p1', 't_c1')
        self.assertEqual({}, guard_mod.guard(self.payload('t_p1', 't_c1'), self.root))

    def test_accepted_review_gate_is_bookkeeping(self):
        self.card('t_rev', assignee='feature-reviewer')
        self.add_run('t_rev', 'accept', NOW - DAY)
        self.card('t_child', assignee='standard-implementer', status='todo')
        self.link('t_rev', 't_child')
        self.assertEqual({}, guard_mod.guard(self.payload('t_rev', 't_child'), self.root))

    def test_done_child_unlinks_freely(self):
        self.card('t_rev', assignee='feature-reviewer')
        self.add_run('t_rev', 'request-changes', NOW - DAY)
        self.card('t_child', assignee='standard-implementer', status='done')
        self.link('t_rev', 't_child')
        self.assertEqual({}, guard_mod.guard(self.payload('t_rev', 't_child'), self.root))

    def test_newer_accepted_review_generation_releases_the_gate(self):
        self.card('t_rev_old', assignee='feature-reviewer', created=NOW - 3 * DAY)
        self.add_run('t_rev_old', 'request-changes', NOW - 2 * DAY)
        self.card('t_rev_new', assignee='feature-reviewer', created=NOW - DAY)
        self.add_run('t_rev_new', 'accept', NOW - 3600)
        self.card('t_child', assignee='standard-implementer', status='running')
        self.link('t_rev_old', 't_child')
        self.link('t_rev_new', 't_child')
        self.assertEqual({}, guard_mod.guard(self.payload('t_rev_old', 't_child'), self.root))

    def test_blocked_attempt_after_an_acceptance_does_not_shut_the_gate(self):
        # A blocked run carries no verdict. Anchoring the supersession window
        # on the parent's latest attempt of any status hid the acceptance that
        # had already landed (live incident: blocked run 1182 ended after
        # accept run 1181).
        self.card('t_rev_old', assignee='feature-reviewer', status='blocked',
                  created=NOW - 4 * DAY)
        self.add_run('t_rev_old', 'request-changes', NOW - 3 * DAY)
        self.card('t_rev_new', assignee='feature-reviewer', created=NOW - 2 * DAY)
        self.add_run('t_rev_new', 'accept', NOW - 2 * DAY)
        self.add_blocked_run('t_rev_old', NOW)
        self.card('t_child', assignee='standard-implementer', status='running')
        self.link('t_rev_old', 't_child')
        self.link('t_rev_new', 't_child')
        self.assertEqual({}, guard_mod.guard(self.payload('t_rev_old', 't_child'), self.root))

    def test_newer_request_changes_does_not_shadow_an_acceptance(self):
        # The window is "any completed accept after the anchor", not "the last
        # completed verdict in the window".
        self.card('t_rev_old', assignee='feature-reviewer', created=NOW - 4 * DAY)
        self.add_run('t_rev_old', 'request-changes', NOW - 3 * DAY)
        self.card('t_rev_accept', assignee='feature-reviewer', created=NOW - 3 * DAY)
        self.add_run('t_rev_accept', 'accept', NOW - 2 * DAY)
        self.card('t_rev_later', assignee='feature-reviewer', created=NOW - 2 * DAY)
        self.add_run('t_rev_later', 'request-changes', NOW - DAY)
        self.card('t_child', assignee='standard-implementer', status='running')
        self.link('t_rev_old', 't_child')
        self.link('t_rev_accept', 't_child')
        self.assertEqual({}, guard_mod.guard(self.payload('t_rev_old', 't_child'), self.root))

    def rejected_gate_with_replacement(self, linked=True, profile='feature-reviewer'):
        self.card('t_old', assignee='feature-reviewer')
        self.add_run('t_old', 'request-changes', NOW - DAY)
        self.card('t_new', assignee=profile, tenant='verification')
        extra = {'independence': {'plan_author': False, 'implementer': False}} if profile == 'project-auditor' else {}
        self.add_run('t_new', 'accept', NOW, profile=profile, **extra)
        self.card('t_child', assignee='standard-implementer', status='running')
        self.link('t_old', 't_child')
        if linked:
            self.link('t_new', 't_child')
        return self.payload('t_old', 't_child')

    def test_unrelated_acceptance_cannot_retire_rejected_review(self):
        payload = self.rejected_gate_with_replacement(linked=False)
        self.assertEqual('block', guard_mod.guard(payload, self.root).get('action'))

    def test_linked_acceptance_requires_valid_checks(self):
        payload = self.rejected_gate_with_replacement()
        self.db.execute("UPDATE task_runs SET metadata=? WHERE task_id='t_new'",
                        (json.dumps({'verdict': 'accept', 'revision': 'r', 'checks': []}),))
        self.db.commit()
        self.assertEqual('block', guard_mod.guard(payload, self.root).get('action'))

    def test_linked_acceptance_is_invalidated_by_newer_failed_run(self):
        payload = self.rejected_gate_with_replacement()
        self.add_blocked_run('t_new', NOW + 1)
        self.assertEqual('block', guard_mod.guard(payload, self.root).get('action'))

    def test_linked_auditor_acceptance_retires_rejected_review(self):
        payload = self.rejected_gate_with_replacement(profile='project-auditor')
        self.assertEqual({}, guard_mod.guard(payload, self.root))

    def test_auditor_verification_needs_verdict_and_independence(self):
        self.card('t_auditor', assignee='project-auditor', tenant='verification')
        for metadata in ({}, {'verdict': 'accept', 'revision': 'r', 'checks': [{'command': 'check', 'exit_code': 0}]},
                         {'verdict': 'accept', 'revision': 'r', 'checks': [{'command': 'check', 'exit_code': 0}],
                          'independence': {'plan_author': True, 'implementer': False}}):
            with self.subTest(metadata=metadata):
                self.assertEqual('block', guard_mod.guard(self.complete_payload('t_auditor', metadata), self.root).get('action'))
        metadata = {'verdict': 'accept', 'revision': 'r', 'checks': [{'command': 'check', 'exit_code': 0}],
                    'independence': {'plan_author': False, 'implementer': False}}
        self.assertEqual({}, guard_mod.guard(self.complete_payload('t_auditor', metadata), self.root))

    def native_auditor(self, source_status='review', implementer='standard-implementer'):
        self.card('t_native', assignee='project-auditor', status='running', tenant='product-work')
        self.db.execute("INSERT INTO task_runs (task_id,profile,status) VALUES ('t_native','project-auditor','running')")
        run_id=self.db.execute('SELECT max(id) FROM task_runs').fetchone()[0]
        self.db.execute("UPDATE tasks SET current_run_id=? WHERE id='t_native'",(run_id,))
        for kind,metadata in [('review_requested',{'implementer':implementer,'reviewer':'project-auditor'}),
                              ('claimed',{'source_status':source_status,'run_id':run_id})]:
            self.db.execute('INSERT INTO task_events(task_id,kind,payload) VALUES (?,?,?)',
                            ('t_native',kind,json.dumps(metadata)))
        self.db.commit()
        return {'verdict':'accept','revision':'a'*40,'checks':[{'command':'owning check','exit_code':0}],
                'independence':{'plan_author':False,'implementer':False}}

    def test_native_auditor_review_requires_verdict_and_independence(self):
        valid=self.native_auditor()
        for invalid in ({},{key:value for key,value in valid.items() if key!='independence'}):
            self.assertEqual('block',guard_mod.guard(self.complete_payload('t_native',invalid),self.root).get('action'))
        self.assertEqual({},guard_mod.guard(self.complete_payload('t_native',valid),self.root))

    def test_native_auditor_rejection_requires_native_request_changes(self):
        valid=self.native_auditor()
        rejection={**valid,'verdict':'request-changes','requested_changes':['Fix it']}
        result=guard_mod.guard(self.complete_payload('t_native',rejection),self.root)
        self.assertEqual('block',result.get('action'))
        self.assertIn('kanban_request_changes',result.get('message',''))

    def test_native_auditor_self_review_cannot_accept(self):
        valid=self.native_auditor(implementer='project-auditor')
        self.assertEqual('block',guard_mod.guard(self.complete_payload('t_native',valid),self.root).get('action'))

    def test_ordinary_auditor_run_after_old_native_review_is_not_verification(self):
        self.native_auditor(source_status='ready')
        self.assertEqual({},guard_mod.guard(self.complete_payload('t_native',{'report':'plan closed'}),self.root))

    def test_native_auditor_claim_must_bind_current_reviewer_run(self):
        valid=self.native_auditor()
        self.db.execute("UPDATE task_runs SET profile='standard-implementer'")
        self.db.commit()
        self.assertEqual('block',guard_mod.guard(self.complete_payload('t_native',valid),self.root).get('action'))

    def test_native_auditor_running_review_cannot_drop_its_current_run(self):
        valid=self.native_auditor()
        self.db.execute("UPDATE tasks SET current_run_id=NULL WHERE id='t_native'")
        self.db.commit()
        self.assertEqual('block',guard_mod.guard(self.complete_payload('t_native',valid),self.root).get('action'))

    def test_native_auditor_parent_acceptance_requires_independence(self):
        valid=self.native_auditor()
        self.db.execute("UPDATE tasks SET status='done',current_run_id=NULL WHERE id='t_native'")
        self.db.execute("UPDATE task_runs SET status='done',outcome='completed',metadata=?",
                        (json.dumps({key:value for key,value in valid.items() if key!='independence'}),))
        self.card('t_child',assignee='head-coordinator',status='running')
        self.link('t_native','t_child')
        self.assertEqual('block',guard_mod.guard(self.complete_payload('t_child',{}),self.root).get('action'))
        self.db.execute('UPDATE task_runs SET metadata=?',(json.dumps(valid),));self.db.commit()
        self.assertEqual({},guard_mod.guard(self.complete_payload('t_child',{}),self.root))

    def test_auditor_planning_and_closure_are_not_verification(self):
        for tenant in (None, 'planning', 'continuous-improvement', 'review-question'):
            tid = 't_' + (tenant or 'none').replace('-', '_')
            self.card(tid, assignee='project-auditor', tenant=tenant)
            self.assertEqual({}, guard_mod.guard(self.complete_payload(tid, {'report': 'clean'}), self.root))

    def test_auditor_review_parent_releases_only_after_independent_acceptance(self):
        self.card('t_auditor', assignee='project-auditor', tenant='verification')
        self.add_run('t_auditor', 'accept', NOW, profile='project-auditor')
        self.card('t_child', assignee='head-coordinator', status='running')
        self.link('t_auditor', 't_child')
        self.assertEqual('block', guard_mod.guard(self.complete_payload('t_child', {}), self.root).get('action'))
        self.db.execute("DELETE FROM task_runs WHERE task_id='t_auditor'")
        self.add_run('t_auditor', 'accept', NOW, profile='project-auditor',
                     independence={'plan_author': False, 'implementer': False})
        self.assertEqual({}, guard_mod.guard(self.complete_payload('t_child', {}), self.root))
        self.db.execute("UPDATE task_runs SET profile='feature-reviewer' WHERE task_id='t_auditor'")
        self.db.commit()
        self.assertEqual('block', guard_mod.guard(self.complete_payload('t_child', {}), self.root).get('action'))

    def test_operation_review_binds_request_and_independent_executor(self):
        self.card('t_operation', assignee='feature-reviewer', tenant='verification')
        valid = {'verdict': 'accept', 'revision': 'a' * 64,
                 'checks': [{'command': 'inspect exact request', 'exit_code': 0}],
                 'operation_scope': {'request_sha256': 'a' * 64, 'executor': 'head-coordinator', 'risk_classes': []}}
        self.assertEqual({}, guard_mod.guard(self.complete_payload('t_operation', valid), self.root))
        for changed in ({**valid, 'revision': 'b' * 64},
                        {**valid, 'operation_scope': {**valid['operation_scope'], 'executor': 'feature-reviewer'}},
                        {**valid, 'operation_scope': {**valid['operation_scope'], 'risk_classes': ['credentials']}}):
            with self.subTest(metadata=changed):
                self.assertEqual('block', guard_mod.guard(self.complete_payload('t_operation', changed), self.root).get('action'))

    def test_operation_rejection_can_report_reserved_effects(self):
        self.card('t_operation', assignee='feature-reviewer', tenant='verification')
        metadata={'verdict':'request-changes','revision':'a'*64,
                  'checks':[{'command':'classify operation effects','exit_code':1}],
                  'requested_changes':['This changes credentials and needs exact owner approval'],
                  'operation_scope':{'request_sha256':'a'*64,'executor':'head-coordinator',
                                     'risk_classes':['credentials']}}
        self.assertEqual({},guard_mod.guard(self.complete_payload('t_operation',metadata),self.root))

    def test_no_acceptance_in_window_still_refuses(self):
        self.card('t_rev_old', assignee='feature-reviewer', created=NOW - 6 * DAY)
        self.add_run('t_rev_old', 'request-changes', NOW - 3 * DAY)
        # An acceptance older than the anchor is outside the window, not evidence.
        self.card('t_rev_stale_accept', assignee='feature-reviewer', created=NOW - 6 * DAY)
        self.add_run('t_rev_stale_accept', 'accept', NOW - 5 * DAY)
        self.card('t_rev_later', assignee='feature-reviewer', created=NOW - 2 * DAY)
        self.add_run('t_rev_later', 'request-changes', NOW - DAY)
        self.card('t_child', assignee='standard-implementer', status='running')
        self.link('t_rev_old', 't_child')
        result = guard_mod.guard(self.payload('t_rev_old', 't_child'), self.root)
        self.assertEqual('block', result.get('action'))
        self.assertIn('live review gate', result.get('message', ''))
        self.assertIn('second parent', result.get('message', ''))

    def test_review_without_a_completed_run_cannot_be_retired(self):
        self.card('t_rev', assignee='feature-reviewer', status='blocked')
        self.add_blocked_run('t_rev', NOW - DAY)
        self.card('t_child', assignee='standard-implementer', status='running')
        self.link('t_rev', 't_child')
        result = guard_mod.guard(self.payload('t_rev', 't_child'), self.root)
        self.assertEqual('block', result.get('action'))
        self.assertIn('cannot be retired', result.get('message', ''))

    def test_retiring_a_live_review_gate_is_refused(self):
        # The catch-22 bypass: unlinking the request-changes review then
        # completing would finish the card unreviewed.
        self.card('t_rev', assignee='feature-reviewer')
        self.add_run('t_rev', 'request-changes', NOW - DAY)
        self.card('t_child', assignee='standard-implementer', status='running')
        self.link('t_rev', 't_child')
        result = guard_mod.guard(self.payload('t_rev', 't_child'), self.root)
        self.assertEqual('block', result.get('action'))
        self.assertIn('live review gate', result.get('message', ''))

    def test_refusal_names_the_lawful_route(self):
        self.card('t_rev', assignee='feature-reviewer')
        self.add_run('t_rev', 'request-changes', NOW - DAY)
        self.card('t_child', assignee='standard-implementer', status='todo')
        self.link('t_rev', 't_child')
        result = guard_mod.guard(self.payload('t_rev', 't_child'), self.root)
        self.assertIn('second parent', result['message'])
        self.assertIn('superseded', result['message'])

    def test_completion_refusal_names_self_service(self):
        # The completion side of the catch-22: the message must point at the
        # native link/unlink route instead of a false coordinator-only claim.
        self.card('t_rev', assignee='feature-reviewer')
        self.add_run('t_rev', 'request-changes', NOW - DAY)
        self.card('t_impl', assignee='standard-implementer', status='running')
        self.link('t_rev', 't_impl')
        payload = {'tool_name': 'kanban_complete',
                   'tool_input': {'board': 'testboard', 'task_id': 't_impl',
                                  'metadata': {'verdict': 'accept', 'revision': 'r',
                                               'checks': [{'command': 'c', 'exit_code': 0}]}}}
        result = guard_mod.guard(payload, self.root)
        self.assertEqual('block', result.get('action'))
        self.assertIn('kanban_link', result['message'])
        self.assertIn('kanban_unlink', result['message'])
        self.assertNotIn('coordinator-only', result['message'])

    def complete_payload(self, tid, metadata, board='testboard'):
        return {'tool_name': 'kanban_complete',
                'tool_input': {'board': board, 'task_id': tid,
                               'metadata': metadata}}

    def test_sanctioned_unknown_verdict_completes(self):
        # Live incident t_cd6d2128: the body permits verdict=unknown for a
        # first-missing-input outcome, but completion refused it, forcing the
        # verifier into a dishonest request-changes and a rework loop.
        self.card('t_ver', assignee='feature-reviewer', status='review',
                  body='Report the prepared packet; a first-missing-input outcome'
                       ' completes with metadata.verdict="unknown" (verdict=unknown).')
        result = guard_mod.guard(self.complete_payload(
            't_ver', {'verdict': 'unknown',
                      'missing_inputs': ['prepared packet absent from its workspace']}),
            self.root)
        self.assertEqual({}, result)

    def test_unknown_verdict_needs_concrete_missing_inputs(self):
        self.card('t_ver', assignee='feature-reviewer', body='verdict=unknown permitted')
        result = guard_mod.guard(self.complete_payload(
            't_ver', {'verdict': 'unknown'}), self.root)
        self.assertEqual('block', result.get('action'))
        self.assertIn('missing_inputs', result.get('message', ''))
        result = guard_mod.guard(self.complete_payload(
            't_ver', {'verdict': 'unknown', 'missing_inputs': ['', ' ']}), self.root)
        self.assertEqual('block', result.get('action'))
        self.assertIn('missing_inputs', result.get('message', ''))

    def test_unsanctioned_unknown_verdict_is_refused(self):
        self.card('t_ver', assignee='feature-reviewer')
        result = guard_mod.guard(self.complete_payload(
            't_ver', {'verdict': 'unknown', 'missing_inputs': ['x']}), self.root)
        self.assertEqual('block', result.get('action'))
        self.assertIn('accept or request-changes', result.get('message', ''))

    def test_unknown_review_does_not_release_a_child_gate(self):
        # An unknown verdict is never an acceptance: a child behind it still
        # needs a real accepted review before it may complete.
        self.card('t_parent_body', assignee='standard-implementer')
        self.card('t_rev', assignee='feature-reviewer',
                  body='verdict=unknown permitted')
        self.db.execute(
            "INSERT INTO task_runs (task_id, profile, status, outcome, metadata,"
            " ended_at) VALUES (?, 'feature-reviewer', 'done', 'completed', ?, ?)",
            ('t_rev', json.dumps({'verdict': 'unknown',
                                  'missing_inputs': ['prepared packet absent']}), NOW))
        self.db.commit()
        self.card('t_impl', assignee='standard-implementer', status='running')
        self.link('t_rev', 't_impl')
        result = guard_mod.guard(self.complete_payload(
            't_impl', {'verdict': 'accept', 'revision': 'r',
                       'checks': [{'command': 'c', 'exit_code': 0}]}), self.root)
        self.assertEqual('block', result.get('action'))


if __name__ == '__main__':
    unittest.main(argv=[sys.argv[0]], verbosity=2)
PY
