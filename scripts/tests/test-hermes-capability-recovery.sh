#!/usr/bin/env bash
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
python3 -B - "$repo" <<'PY'
import json
import sqlite3
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(sys.argv[1]) / 'scripts/hermes'))
import capability_recovery as recovery
import cron_stall


class RecoveryTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='hermes-capability-recovery-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.board = self.root / 'kanban/boards/test'
        self.board.mkdir(parents=True)
        (self.board / 'board.json').write_text('{}')
        self.path = self.board / 'kanban.db'
        self.db = sqlite3.connect(self.path)
        self.addCleanup(self.db.close)
        self.db.executescript('''
            CREATE TABLE tasks(id TEXT PRIMARY KEY,status TEXT,assignee TEXT,block_kind TEXT,
                body TEXT,workspace_path TEXT,consecutive_failures INTEGER DEFAULT 0,
                block_recurrences INTEGER DEFAULT 0);
            CREATE TABLE task_events(id INTEGER PRIMARY KEY,task_id TEXT,kind TEXT,payload TEXT);
            CREATE TABLE task_links(parent_id TEXT,child_id TEXT);
            CREATE TABLE task_comments(id INTEGER PRIMARY KEY,task_id TEXT,author TEXT,body TEXT,created_at REAL);
            CREATE TABLE task_runs(id INTEGER PRIMARY KEY,task_id TEXT,status TEXT,outcome TEXT,ended_at REAL,metadata TEXT);
        ''')
        self.task('t_one')
        self.block('t_one', 'Input supplier: agent. Required candidate is absent.')

    def task(self, tid, status='blocked', kind='capability'):
        self.db.execute('INSERT INTO tasks(id,status,assignee,block_kind,body) VALUES(?,?,?,?,?)',
                        (tid, status, 'standard-implementer', kind, 'Approved finite scope.'))

    def block(self, tid, reason, kind='capability'):
        self.db.execute("INSERT INTO task_events(task_id,kind,payload) VALUES(?,'blocked',?)",
                        (tid, json.dumps({'reason': reason, 'kind': kind})))

    def report(self):
        self.db.commit()
        before = self.path.read_bytes()
        report = recovery.report(self.root)
        self.assertEqual(before, self.path.read_bytes())
        self.assertEqual([], report['warnings'])
        return report

    def test_repeated_observation_is_stable_and_never_uses_comment_acknowledgments(self):
        first = self.report()
        self.db.execute("INSERT INTO task_comments VALUES(1,'t_one','head-coordinator','Acknowledged.',1000)")
        self.assertEqual(first, self.report())
        self.block('t_one', 'Input supplier: agent. Required candidate is absent.')
        self.assertEqual(first, self.report())  # event identity alone is not new evidence

    def test_actual_helper_install_changes_version_but_credentials_do_not(self):
        first = self.report()
        scripts = self.root / 'scripts'
        scripts.mkdir()
        (scripts / 'fixture-runner.py').write_text('# installed qualified helper\n')
        second = self.report()
        self.assertNotEqual(first['holds'][0]['version'], second['holds'][0]['version'])
        (self.root / '.env').write_text('DO_NOT_READ=credential\n')
        self.assertEqual(second, self.report())

    def test_prerequisite_delivery_and_attachment_change_wake_only_their_consumer(self):
        self.task('t_two')
        self.task('t_parent', 'todo', None)
        self.db.execute("INSERT INTO task_links VALUES('t_parent','t_one')")
        first = {h['key']: h['version'] for h in self.report()['holds']}
        self.db.execute("UPDATE tasks SET status='done' WHERE id='t_parent'")
        second = {h['key']: h['version'] for h in self.report()['holds']}
        self.assertNotEqual(first['test:t_one'], second['test:t_one'])
        self.assertEqual(first['test:t_two'], second['test:t_two'])
        artifact = self.board / 'attachments/t_one/candidate.patch'
        artifact.parent.mkdir(parents=True)
        artifact.write_text('durable transfer')
        third = {h['key']: h['version'] for h in self.report()['holds']}
        self.assertNotEqual(second['test:t_one'], third['test:t_one'])
        self.assertEqual(second['test:t_two'], third['test:t_two'])

    def test_source_scope_and_workspace_availability_are_material_inputs(self):
        workspace = self.root / 'candidate'
        self.db.execute('UPDATE tasks SET workspace_path=? WHERE id=?', (str(workspace), 't_one'))
        first = self.report()['holds'][0]['version']
        workspace.mkdir()
        second = self.report()['holds'][0]['version']
        self.assertNotEqual(first, second)
        self.db.execute("UPDATE tasks SET body='Approved corrected input boundary.'")
        self.assertNotEqual(second, self.report()['holds'][0]['version'])

    def test_repaired_git_source_wakes_its_consumer_without_a_new_block(self):
        workspace = self.root / 'candidate'
        workspace.mkdir()
        def git(*args):
            return subprocess.run(['git', '-C', str(workspace), *args], check=True,
                                  capture_output=True, text=True).stdout.strip()
        git('init', '-q')
        git('config', 'user.name', 'Fixture')
        git('config', 'user.email', 'fixture@example.invalid')
        (workspace / 'source').write_text('old candidate')
        git('add', 'source')
        git('commit', '-qm', 'old candidate')
        self.db.execute('UPDATE tasks SET workspace_path=?', (str(workspace),))
        first = self.report()['holds'][0]
        (workspace / 'source').write_text('repaired candidate')
        git('commit', '-qam', 'repair candidate')
        second = self.report()['holds'][0]
        self.assertNotEqual(first['version'], second['version'])
        self.assertEqual(git('rev-parse', 'HEAD'), second['workspace_identity']['revision'])
        self.assertEqual('git-root', second['workspace_identity']['state'])

    def test_plain_directory_never_inherits_its_parent_repository_identity(self):
        subprocess.run(['git', 'init', '-q', str(self.root)], check=True)
        workspace = self.root / 'empty-consumer'
        workspace.mkdir()
        self.db.execute('UPDATE tasks SET workspace_path=?', (str(workspace),))
        identity = self.report()['holds'][0]['workspace_identity']
        self.assertEqual({'state': 'directory'}, identity)

    def test_scheduled_historical_capability_holds_are_followed_without_restarting_workers(self):
        self.db.execute("UPDATE tasks SET status='scheduled',block_kind=NULL")
        focus = self.report()['holds']
        self.assertEqual(['test:t_one'], [h['key'] for h in focus])
        for status in ('running', 'ready', 'review', 'done', 'archived'):
            self.db.execute('UPDATE tasks SET status=?', (status,))
            self.assertEqual([], self.report()['holds'], status)

    def test_stall_followthrough_uses_existing_backoff_and_new_evidence_resets_it(self):
        self.db.execute("UPDATE tasks SET status='scheduled',block_kind=NULL")
        self.db.commit()
        state = {}
        focus = cron_stall.collect(self.root, state, 1000)
        self.assertEqual(['test:t_one'], [h['key'] for h in focus])
        self.assertIn('capability_recovery', focus[0])
        cron_stall.processed(state, focus, 1000)
        self.assertEqual([], cron_stall.collect(self.root, state, 1001))
        self.assertEqual(1, len(cron_stall.collect(self.root, state, 1000 + 8 * 3600)))
        self.block('t_one', 'Input supplier: agent. New accepted transfer is now required.')
        self.db.commit()
        changed = cron_stall.collect(self.root, state, 1002)
        self.assertEqual('material_change', changed[0]['reason'])

    def test_supplier_owner_is_reported_without_manufacturing_a_gate(self):
        self.block('t_one', 'Input supplier: owner. Physical device confirmation.')
        hold = self.report()['holds'][0]
        self.assertEqual('owner', hold['supplier'])
        self.assertEqual('blocked', hold['status'])

    def test_a_released_episode_is_not_resurrected_by_later_scheduling(self):
        self.db.execute("INSERT INTO task_events(task_id,kind,payload) VALUES('t_one','unblocked','{}')")
        self.db.execute("UPDATE tasks SET status='scheduled'")
        self.assertEqual([], self.report()['holds'])

    def test_new_explicit_scheduled_agent_wait_remains_visible_with_its_conditions(self):
        self.db.execute("INSERT INTO task_events(task_id,kind,payload) VALUES('t_one','unblocked','{}')")
        self.db.execute("UPDATE tasks SET status='scheduled',block_kind=NULL")
        reason = 'Input supplier: agent. WAIT_EXTERNAL=qualified new runtime receipts only.'
        self.db.execute("INSERT INTO task_events(task_id,kind,payload) VALUES('t_one','scheduled',?)",
                        (json.dumps({'reason': reason}),))
        hold = self.report()['holds'][0]
        self.assertIn('WAIT_EXTERNAL=qualified new runtime receipts', hold['reason'])
        self.assertEqual('scheduled', hold['status'])

    def test_native_scheduling_does_not_release_an_existing_capability_episode(self):
        self.db.execute("UPDATE tasks SET status='scheduled'")
        for payload in ({'reason': None}, {'reason': 'Awaiting prepared artifact'}):
            self.db.execute("INSERT INTO task_events(task_id,kind,payload) VALUES('t_one','scheduled',?)",
                            (json.dumps(payload),))
            hold = self.report()['holds'][0]
            self.assertIn('Required candidate is absent', hold['reason'])

    def test_native_block_loop_routes_to_triage_without_losing_the_current_hold(self):
        self.db.execute("INSERT INTO task_events(task_id,kind,payload) VALUES('t_one','unblocked','{}')")
        reason = 'Input supplier: agent. Repeated capability denial; route a changed remedy.'
        self.db.execute("INSERT INTO task_events(task_id,kind,payload) VALUES('t_one','block_loop_detected',?)",
                        (json.dumps({'kind': 'capability', 'reason': reason}),))
        self.db.execute("UPDATE tasks SET status='triage'")
        hold = self.report()['holds'][0]
        self.assertEqual('triage', hold['status'])
        self.assertEqual(reason, hold['reason'])

    def test_helper_links_and_special_files_are_not_followed_or_opened(self):
        scripts = self.root / 'scripts'
        scripts.mkdir()
        secret = self.root / '.env'
        secret.write_text('never-read')
        (scripts / 'fixture-runner.py').symlink_to(secret)
        first = self.report()
        secret.write_text('changed-credential')
        self.assertEqual(first, self.report())
        (scripts / 'fixture-runner.py').unlink()
        os.mkfifo(scripts / 'fixture-runner.py')
        self.assertEqual(first, self.report())

    def test_completed_parent_acceptance_changes_wake_existing_hold(self):
        self.task('t_review','done',None)
        self.db.execute("INSERT INTO task_links VALUES('t_review','t_one')")
        self.db.execute("INSERT INTO task_runs VALUES(1,'t_review','done','completed',100,?)",
                        (json.dumps({'verdict':'request-changes','revision':'a'*40}),))
        first=self.report()['holds'][0]['version']
        self.db.execute("UPDATE task_runs SET metadata=? WHERE id=1",
                        (json.dumps({'verdict':'accept','revision':'b'*40}),))
        second=self.report()['holds'][0]['version']
        self.assertNotEqual(first,second)
        self.assertEqual(second,self.report()['holds'][0]['version'])

    def test_reclassification_to_another_kind_ends_the_capability_hold(self):
        self.db.execute("INSERT INTO task_events(task_id,kind,payload) VALUES('t_one','block_reclassified',?)",
                        (json.dumps({'old_kind': 'capability', 'new_kind': 'dependency',
                                     'reason': 'Waiting on parent review/approval',
                                     'source': 'owner_directed_audit'}),))
        self.db.commit()
        self.assertEqual([], self.report()['holds'])

    def test_reclassification_back_to_capability_keeps_the_hold_current(self):
        self.db.execute("INSERT INTO task_events(task_id,kind,payload) VALUES('t_one','block_reclassified',?)",
                        (json.dumps({'old_kind': 'dependency', 'new_kind': 'capability',
                                     'reason': 'Input supplier: agent. Restored capability hold.',
                                     'source': 'coordinator'}),))
        self.db.commit()
        hold = self.report()['holds'][0]
        self.assertEqual('agent', hold['supplier'])
        self.assertIn('Restored capability hold.', hold['reason'])

    def test_legacy_reason_only_reclassification_uses_current_native_kind(self):
        # Real pcops/t_56e7f21a historical format omitted new_kind entirely.
        self.db.execute("INSERT INTO task_events(task_id,kind,payload) VALUES('t_one','block_reclassified',?)",
                        (json.dumps({'reason':'Input supplier: agent. Native lifecycle repair.',
                                     'source':'owner_directed_classification'}),))
        hold=self.report()['holds'][0]
        self.assertIn('Native lifecycle repair.',hold['reason'])
        self.db.execute("UPDATE tasks SET block_kind='dependency'")
        self.assertEqual([],self.report()['holds'])

    def test_an_unsupported_reclassification_kind_fails_closed(self):
        self.db.execute("INSERT INTO task_events(task_id,kind,payload) VALUES('t_one','block_reclassified',?)",
                        (json.dumps({'old_kind': 'capability', 'new_kind': 'Needs Input'}),))
        self.db.commit()
        report = recovery.report(self.root)
        self.assertEqual(report['holds'], [])
        self.assertTrue(report['warnings'])

    def test_plain_python_observation_does_not_create_bytecode_or_write_state(self):
        scripts = self.root / 'scripts'
        scripts.mkdir()
        source = Path(sys.argv[1]) / 'scripts/hermes'
        for name in ('capability_recovery.py', 'board_progress.py', 'steward-opportunity-scan.py'):
            shutil.copyfile(source / name, scripts / name)
        for column in ("title TEXT DEFAULT 'Fixture request'", 'priority INTEGER DEFAULT 0',
                       'tenant TEXT', 'created_by TEXT'):
            self.db.execute('ALTER TABLE tasks ADD COLUMN '+column)
        self.db.commit()
        before = {str(p.relative_to(self.root)): p.read_bytes()
                  for p in self.root.rglob('*') if p.is_file()}
        env = {**os.environ, 'HERMES_ROOT': str(self.root), 'STEWARD_REPO': str(self.root / 'missing'),
               'PYTHONDONTWRITEBYTECODE': ''}
        for name in ('capability_recovery.py', 'steward-opportunity-scan.py'):
            result = subprocess.run([sys.executable, str(scripts / name)], env=env,
                                    capture_output=True, text=True, timeout=10)
            self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual(before, {str(p.relative_to(self.root)): p.read_bytes()
                                 for p in self.root.rglob('*') if p.is_file()})

    def test_handoffs_are_per_hold_deterministic_and_refuse_changed_inputs(self):
        requests = {}
        def queue(root, request_id, message):
            old = requests.setdefault(request_id, message)
            self.assertEqual(old, message)
            return {'status': 'queued'}
        hold = self.report()['holds'][0]
        recovery.handoff(self.root, hold['key'], hold['version'], queue)
        self.db.execute("INSERT INTO task_comments VALUES(1,'t_one','head-coordinator','Acknowledged.',1000)")
        self.db.commit()
        recovery.handoff(self.root, hold['key'], hold['version'], queue)
        self.assertEqual(1, len(requests))
        self.block('t_one', 'Input supplier: agent. Changed prerequisite.')
        self.db.commit()
        with self.assertRaises(ValueError):
            recovery.handoff(self.root, hold['key'], hold['version'], queue)
        new = self.report()['holds'][0]
        recovery.handoff(self.root, new['key'], new['version'], queue)
        self.assertEqual(2, len(requests))

    def test_missing_or_broken_board_is_a_coverage_failure_and_creates_nothing(self):
        missing = self.root / 'kanban/boards/missing'
        missing.mkdir()
        (missing / 'board.json').write_text('{}')
        report = recovery.report(self.root)
        self.assertTrue(report['warnings'])
        self.assertFalse((missing / 'kanban.db').exists())
        self.assertIn('CAPABILITY_COVERAGE', '\n'.join(recovery.monitor_lines(report)))
        self.db.execute("UPDATE task_events SET payload='invalid-json'")
        self.db.commit()
        self.assertTrue(recovery.report(self.root)['warnings'])

    def test_output_is_bounded_and_always_lists_omitted_coverage(self):
        for i in range(30):
            self.task('t_extra_' + str(i))
        lines = recovery.monitor_lines(self.report(), limit=3)
        self.assertEqual(4, len(lines))
        self.assertTrue(lines[-1].startswith('CAPABILITY_MORE '))


unittest.main(argv=[sys.argv[0]])
PY
