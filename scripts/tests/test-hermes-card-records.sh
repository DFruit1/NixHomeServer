#!/usr/bin/env bash
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if [[ "${HERMES_FIXTURE_ACTIVE:-}" != 1 ]]; then
  export PATH="/usr/bin:$PATH"
  exec python3 -B "$repo/scripts/hermes/fixture-runner.py" --repo "$repo" \
    --suite "$repo/scripts/tests/test-hermes-card-records.sh"
fi
python3 -B - "$repo" <<'PY'
import contextlib
import json
from pathlib import Path
import sqlite3
import sys
import time
import unittest

sys.path.insert(0, str(Path(sys.argv[1]) / 'scripts/hermes'))
import card_records as records


class Native:
    @staticmethod
    @contextlib.contextmanager
    def write_txn(db):
        with db:
            yield

    @staticmethod
    def _append_event(db, tid, kind, payload):
        db.execute('INSERT INTO task_events(task_id,kind,payload,created_at) VALUES(?,?,?,?)',
                   (tid, kind, json.dumps(payload), int(time.time())))


class RecordsTest(unittest.TestCase):
    def setUp(self):
        self.db = sqlite3.connect(':memory:')
        self.db.row_factory = sqlite3.Row
        self.db.executescript('''
            CREATE TABLE tasks(id TEXT PRIMARY KEY, body TEXT, status TEXT);
            CREATE TABLE task_comments(id INTEGER PRIMARY KEY,task_id TEXT,author TEXT,body TEXT,created_at INTEGER);
            CREATE TABLE task_events(id INTEGER PRIMARY KEY,task_id TEXT,kind TEXT,payload TEXT,created_at INTEGER);
            CREATE TABLE task_runs(id INTEGER PRIMARY KEY,task_id TEXT,status TEXT,outcome TEXT,ended_at INTEGER);
            INSERT INTO tasks VALUES('t_a','Goal: test','blocked');
            INSERT INTO task_runs VALUES(7,'t_a','failed','failed',0);
        ''')

    def tearDown(self):
        self.db.close()

    def write(self, kind, value, **kwargs):
        return records.write(Native, self.db, 't_a', kind, value,
            actor='head-coordinator', expected_version=records.inspect(self.db, 't_a')['version'], **kwargs)

    def test_record_is_native_state_without_comment_or_status_change(self):
        self.write('decision_owner', {'owner': 'head-coordinator'})
        state = records.inspect(self.db, 't_a')
        self.assertEqual(state['records']['decision_owner']['value'], {'owner': 'head-coordinator'})
        self.assertEqual(self.db.execute('SELECT COUNT(*) FROM task_comments').fetchone()[0], 0)
        self.assertEqual(self.db.execute('SELECT status FROM tasks').fetchone()[0], 'blocked')

    def test_stale_update_and_non_coordinator_refuse_without_effect(self):
        before = records.inspect(self.db, 't_a')['version']
        self.write('decision_owner', {'owner': 'head-coordinator'})
        for actor, version in [('head-coordinator', before), ('standard-implementer', records.inspect(self.db, 't_a')['version'])]:
            with self.assertRaises(ValueError):
                records.write(Native, self.db, 't_a', 'decision_owner', {'owner': 'pending-assessment'},
                              actor=actor, expected_version=version)
        self.assertEqual(self.db.execute('SELECT COUNT(*) FROM task_events').fetchone()[0], 1)

    def test_legacy_and_native_protocol_order_in_same_second(self):
        now = int(time.time())
        self.db.execute('INSERT INTO task_comments VALUES(1,?,?,?,?)',
                        ('t_a', 'owner', 'old owner response', now))
        self.write('delegated_execution_decision', {'approved': True, 'request_sha256': 'a'*64,
                   'executor': 'head-coordinator', 'review_task_id': 't_review'})
        self.db.execute('INSERT INTO task_comments VALUES(2,?,?,?,?)',
                        ('t_a', 'owner', 'withdraw permission', now))
        entries = records.protocol_entries(self.db, 't_a')
        self.assertEqual([r['author'] for r in entries], ['owner', 'head-coordinator', 'owner'])
        self.assertEqual(json.loads(entries[1]['body'])['delegated_execution_decision']['request_sha256'], 'a'*64)

    def test_recovery_binds_exact_failed_run_and_requires_changed_input(self):
        self.write('recovery', {'run_id': 7, 'change': 'Delivered missing input', 'action': 'Read supplied attachment'})
        self.assertEqual(records.inspect(self.db, 't_a')['records']['recovery']['value']['run_id'], 7)
        for value in ({'run_id': 6, 'change': 'Delivered input', 'action': 'Read it'},
                      {'run_id': 7, 'change': '', 'action': 'Retry'}):
            with self.assertRaises(ValueError):
                self.write('recovery', value)

    def test_repeated_decision_and_owner_withdrawal_survive_intervening_evidence(self):
        decision = {'approved': True, 'request_sha256': 'a'*64,
                    'executor': 'head-coordinator', 'review_task_id': 't_review'}
        reply = {'text': 'stop', 'origin': 'interactive-owner'}
        self.write('delegated_execution_decision', decision)
        self.write('owner_reply', reply)
        self.write('delegated_execution_decision', decision)
        self.assertEqual(records.protocol_entries(self.db, 't_a')[-1]['record_kind'], 'delegated_execution_decision')
        self.write('owner_reply', reply)
        self.assertEqual(records.protocol_entries(self.db, 't_a')[-1]['author'], 'owner')
        self.assertEqual(self.db.execute('SELECT COUNT(*) FROM task_events').fetchone()[0], 4)
        self.assertTrue(self.write('owner_reply', reply)['unchanged'])

    def test_new_contract_cannot_be_overridden_by_legacy_feature_binding(self):
        self.db.execute('INSERT INTO task_events(task_id,kind,payload,created_at) VALUES(?,?,?,?)',
                        ('t_a', 'created', json.dumps({'workflow': {'version': 1}}), 0))
        with self.assertRaises(ValueError):
            self.write('feature', {'tracker': 'nixhomeserver:t_tracker', 'role': 'delivery'})

    def test_closed_schema_rejects_unknown_or_unbounded_content(self):
        for kind, value in [('unknown', {}), ('decision_owner', {'owner': 'owner'}),
                            ('decision_owner', {'owner': 'head-coordinator', 'note': 'extra'}),
                            ('recovery', {'run_id': True, 'change': 'fixed', 'action': 'read'})]:
            with self.assertRaises(ValueError):
                self.write(kind, value)

    def test_corrupt_native_record_does_not_fall_back_to_old_comment(self):
        self.db.execute('INSERT INTO task_events(task_id,kind,payload,created_at) VALUES(?,?,?,?)',
                        ('t_a', 'task_record', '{broken', 0))
        with self.assertRaises(ValueError):
            records.inspect(self.db, 't_a')

    def test_typed_feature_replaces_all_old_role_markers(self):
        import importlib.util
        source=Path(sys.argv[1])/'scripts/hermes/review-verdict-guard.py'
        spec=importlib.util.spec_from_file_location('record_review_guard',source)
        guard=importlib.util.module_from_spec(spec);spec.loader.exec_module(guard)
        self.db.execute("UPDATE tasks SET body='Goal: work\nFeature handoff: delivery\nFeature role: documentary-closure'")
        self.write('feature', {'tracker': 'nixhomeserver:t_tracker', 'role': 'producer'})
        self.db.execute('INSERT INTO task_comments VALUES(1,?,?,?,0)',
                        ('t_a','head-coordinator','Feature tracker: nixhomeserver:t_stale'))
        text=guard._feature_contract(self.db,self.db.execute("SELECT * FROM tasks WHERE id='t_a'").fetchone())
        self.assertIn('Feature tracker: nixhomeserver:t_tracker',text)
        self.assertNotIn('Feature handoff:',text)
        self.assertNotIn('Feature role:',text)
        self.assertNotIn('t_stale',text)

    def test_typed_owner_summary_reuses_the_existing_wording_validator(self):
        valid={'blocking':'Repair is waiting for your approval. Nothing proceeds until you decide.',
               'why_owner':'The repair changes a setting you previously chose. Only you can confirm it is wanted.',
               'unblock':'Approve the repair or keep the current setting.'}
        self.write('owner_summary',valid)
        with self.assertRaises(ValueError):
            self.write('owner_summary',{**valid,'why_owner':'Only you can clear this'})


unittest.main(argv=[sys.argv[0]])
PY
"$HERMES_FIXTURE_NATIVE_PYTHON" -B "$repo/scripts/tests/hermes-card-records-native.py"
