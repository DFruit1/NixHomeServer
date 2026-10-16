#!/usr/bin/env bash
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
python3 -B - "$repo" <<'PY'
from contextlib import closing
import importlib.util
import json
from pathlib import Path
import sqlite3
import sys
import tempfile
import unittest

ROOT = Path(sys.argv[1])
def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'scripts/hermes' / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

guard = load('verdict_guard', 'review-verdict-guard.py')
monitor = load('idle_monitor', 'idle-recovery-monitor.py')

class CoordinationTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='nixhomeserver-hermes-coordination-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.board = self.root / 'kanban/boards/one'
        self.board.mkdir(parents=True)
        (self.board / 'board.json').write_text('{}')
        self.path = self.board / 'kanban.db'
        with closing(sqlite3.connect(self.path)) as db:
            db.executescript('''CREATE TABLE tasks (id TEXT PRIMARY KEY, title TEXT, body TEXT,
                status TEXT, assignee TEXT, tenant TEXT, priority INTEGER DEFAULT 0,
                block_kind TEXT, result TEXT, current_run_id INTEGER, last_heartbeat_at INTEGER);
                CREATE TABLE task_links (parent_id TEXT, child_id TEXT);
                CREATE TABLE task_runs (id INTEGER, task_id TEXT, status TEXT, outcome TEXT, metadata TEXT,
                    profile TEXT DEFAULT 'feature-reviewer');
                CREATE TABLE task_comments (id INTEGER, task_id TEXT, author TEXT, body TEXT);
                CREATE TABLE task_events (id INTEGER, task_id TEXT, kind TEXT, payload TEXT);''')
            db.execute("INSERT INTO tasks (id,title,body,status,assignee) VALUES ('t_review','Verify change','Goal: Verify','running','feature-reviewer')")
            db.commit()
        self.valid = {'verdict': 'accept', 'revision': 'a' * 40,
                      'checks': [{'command': 'bash owning-test.sh', 'exit_code': 0}]}

    def sql(self, statement, params=()):
        with closing(sqlite3.connect(self.path)) as db:
            db.execute(statement, params); db.commit()

    def complete(self, metadata, task='t_review', profile='feature-reviewer'):
        return guard.guard({'profile': profile, 'tool_name': 'kanban_complete',
                            'tool_input': {'board': 'one', 'task_id': task, 'metadata': metadata}}, self.root)

    def test_verification_requires_canonical_verdict_revision_and_real_checks(self):
        self.assertEqual({}, self.complete(self.valid))
        for invalid in ({}, {**self.valid, 'verdict': 'ACCEPT'}, {**self.valid, 'revision': ''},
                        {**self.valid, 'checks': []}, {**self.valid, 'checks': [{'command':'test','exit_code':False}]},
                        {**self.valid, 'checks': [{'command':'test','exit_code':1}]}):
            with self.subTest(metadata=invalid):
                self.assertEqual('block', self.complete(invalid)['action'])

    def test_bounded_questions_do_not_masquerade_as_acceptance_reviews(self):
        self.sql("UPDATE tasks SET tenant='review-question'")
        self.assertEqual({}, self.complete({'answer':'The source uses the existing option'}))

    def test_audits_keep_their_report_contract(self):
        self.sql("UPDATE tasks SET tenant='continuous-improvement'")
        self.assertEqual({}, self.complete({'outcome':'clean'}))

    def test_rejection_needs_fixes_and_cannot_release_implementation(self):
        rejection = {**self.valid, 'verdict':'request-changes', 'requested_changes':['Fix the failing case']}
        self.assertEqual('block', self.complete({**rejection,'requested_changes':[]})['action'])
        self.assertEqual({}, self.complete(rejection))
        self.sql("INSERT INTO tasks (id,status,assignee) VALUES ('t_next','todo','standard-implementer')")
        self.sql("INSERT INTO task_links VALUES ('t_review','t_next')")
        self.assertEqual('block', self.complete(rejection)['action'])
        self.sql("UPDATE tasks SET assignee='head-coordinator' WHERE id='t_next'")
        self.assertEqual({}, self.complete(rejection))

    def test_native_rejection_uses_native_lifecycle(self):
        self.sql("UPDATE tasks SET status='review'")
        self.assertEqual('block', self.complete({**self.valid,'verdict':'request-changes',
                                               'requested_changes':['Fix it']})['action'])
        # A claimed native review is running; provenance is on the claim event.
        self.sql("UPDATE tasks SET status='running'")
        self.sql("INSERT INTO task_events VALUES (1,'t_review','claimed',?)",
                 (json.dumps({'source_status':'review'}),))
        self.assertEqual('block', self.complete({**self.valid,'verdict':'request-changes',
                                               'requested_changes':['Fix it']})['action'])


    def test_done_review_does_not_mean_accepted_for_consumer_completion(self):
        self.sql("UPDATE tasks SET status='done'")
        self.sql("INSERT INTO tasks (id,status,assignee) VALUES ('t_route','running','head-coordinator')")
        self.sql("INSERT INTO task_links VALUES ('t_review','t_route')")
        self.sql("INSERT INTO task_runs (id,task_id,status,outcome,metadata) VALUES (1,'t_review','done','completed',?)", (json.dumps({**self.valid,'verdict':'request-changes'}),))
        self.assertEqual('block', self.complete({}, 't_route', 'head-coordinator')['action'])
        self.sql('UPDATE task_runs SET metadata=?', (json.dumps(self.valid),))
        self.assertEqual({}, self.complete({}, 't_route', 'head-coordinator'))
        self.sql("UPDATE task_runs SET metadata='{}'")
        self.assertEqual('block', self.complete({}, 't_route', 'head-coordinator')['action'])

    def test_consumer_cannot_reuse_acceptance_before_a_newer_failed_review(self):
        self.sql("UPDATE tasks SET status='done'")
        self.sql("INSERT INTO tasks (id,status,assignee) VALUES ('t_route','running','head-coordinator')")
        self.sql("INSERT INTO task_links VALUES ('t_review','t_route')")
        self.sql("INSERT INTO task_runs VALUES (1,'t_review','done','completed',?,'feature-reviewer')",
                 (json.dumps(self.valid),))
        self.sql("INSERT INTO task_runs VALUES (2,'t_review','crashed','crashed','{}','feature-reviewer')")
        self.assertEqual('block', self.complete({}, 't_route', 'head-coordinator')['action'])
        self.sql("UPDATE task_runs SET status='done',outcome='completed',metadata=?,profile='head-coordinator' WHERE id=2",
                 (json.dumps(self.valid),))
        self.assertEqual('block', self.complete({}, 't_route', 'head-coordinator')['action'])

    def test_missing_board_fails_closed_for_completion_but_other_tools_pass(self):
        self.assertEqual('block', guard.guard({'profile':'feature-reviewer','tool_name':'kanban_complete','tool_input':{}},self.root)['action'])
        self.assertEqual({}, guard.guard({'tool_name':'kanban_show'},self.root))

    def test_monitor_changes_only_for_meaningful_idle_state(self):
        self.sql("UPDATE tasks SET status='todo'")
        initial = monitor.snapshot(self.root)
        self.assertEqual(initial, monitor.snapshot(self.root))
        self.sql('UPDATE tasks SET last_heartbeat_at=123')
        self.assertEqual(initial, monitor.snapshot(self.root))
        self.sql("INSERT INTO task_comments VALUES (1,'t_review','head-coordinator','Still waiting')")
        self.assertEqual(initial, monitor.snapshot(self.root))
        self.sql("INSERT INTO task_comments VALUES (2,'t_review','desktop','Approved exact scope')")
        self.assertNotEqual(initial, monitor.snapshot(self.root))
        idle = monitor.snapshot(self.root)
        self.sql("UPDATE tasks SET status='running'")
        busy = monitor.snapshot(self.root)
        self.assertNotEqual(idle, busy)
        self.sql("UPDATE tasks SET result='Unfinished work changed'")
        self.assertEqual(busy, monitor.snapshot(self.root))
        self.sql("UPDATE tasks SET status='todo'")
        self.assertNotEqual(idle, monitor.snapshot(self.root))

    def test_monitor_detects_receipts_on_completed_sources_without_raw_content(self):
        self.sql("UPDATE tasks SET status='scheduled'")
        self.sql("INSERT INTO tasks (id,status,assignee,result) VALUES ('t_source','done','standard-implementer','private old receipt')")
        before = monitor.snapshot(self.root)
        self.sql("UPDATE tasks SET result='private new receipt' WHERE id='t_source'")
        after = monitor.snapshot(self.root)
        self.assertNotEqual(before, after)
        self.assertNotIn('private', after)

    def test_monitor_unknown_schema_and_missing_database_are_errors(self):
        self.path.unlink()
        with self.assertRaises((OSError,sqlite3.Error,ValueError)):
            monitor.snapshot(self.root)

unittest.main(argv=['coordination'], verbosity=2)
PY
