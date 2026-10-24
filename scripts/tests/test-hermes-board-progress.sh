#!/usr/bin/env bash
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/hermes-board-progress-tests.XXXXXX")"
trap 'rm -rf -- "$scratch"' EXIT
python3 -B - "$repo" "$scratch" <<'PY'
import importlib.util
import json
from pathlib import Path
import sqlite3
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(sys.argv[1]) / 'scripts/hermes'))
import board_progress

spec = importlib.util.spec_from_file_location('supervisor', Path(sys.argv[1]) / 'scripts/hermes/fleet-supervisor.py')
supervisor = importlib.util.module_from_spec(spec)
spec.loader.exec_module(supervisor)
scratch = Path(sys.argv[2])


class BoardProgressTest(unittest.TestCase):
    def setUp(self):
        self.root = scratch / self.id().rsplit('.', 1)[-1]
        self.board = self.root / 'kanban/boards/project'
        self.board.mkdir(parents=True)
        (self.board / 'board.json').write_text('{}')
        self.path = self.board / 'kanban.db'
        # Native lifecycle columns: a claim opens a run before a worker starts.
        self.db = sqlite3.connect(self.path)
        self.addCleanup(self.db.close)
        self.db.executescript('''
            CREATE TABLE tasks(id TEXT PRIMARY KEY,title TEXT,body TEXT,status TEXT,
                assignee TEXT,priority INTEGER,tenant TEXT,created_by TEXT,block_kind TEXT,
                created_at INTEGER,started_at INTEGER,completed_at INTEGER,current_run_id INTEGER,
                worker_pid INTEGER,worker_started_at INTEGER,last_heartbeat_at INTEGER,
                claim_lock TEXT,claim_expires INTEGER,
                consecutive_failures INTEGER NOT NULL DEFAULT 0,
                block_recurrences INTEGER NOT NULL DEFAULT 0);
            CREATE TABLE task_links(parent_id TEXT,child_id TEXT);
            CREATE TABLE task_runs(id INTEGER PRIMARY KEY AUTOINCREMENT,task_id TEXT,profile TEXT,status TEXT,
                started_at INTEGER,ended_at INTEGER,outcome TEXT,metadata TEXT,worker_pid INTEGER,
                worker_started_at INTEGER,last_heartbeat_at INTEGER);
            CREATE TABLE task_events(id INTEGER PRIMARY KEY AUTOINCREMENT,task_id TEXT,run_id INTEGER,
                kind TEXT,payload TEXT,created_at INTEGER);
            CREATE TABLE task_comments(id INTEGER PRIMARY KEY,task_id TEXT,author TEXT,body TEXT,
                created_at INTEGER);
        ''')
        self.task('t_hold', 'blocked', block_kind='capability')
        self.task('t_consumer', 'todo')
        self.task('t_fix_a', 'todo')
        self.task('t_fix_b', 'todo')
        self.db.execute("INSERT INTO task_links VALUES ('t_hold','t_consumer')")
        self.db.commit()

    def task(self, task_id, status, *, tenant=None, creator=None, block_kind=None, body='Bounded existing requested fix.'):
        self.db.execute('''INSERT INTO tasks(id,title,body,status,assignee,priority,tenant,
            created_by,block_kind,created_at) VALUES (?,?,?,?,?,?,?,?,?,?)''',
            (task_id, task_id, body, status, 'standard-implementer', 10, tenant, creator, block_kind, 10))

    def start_worker(self, task_id, run_id, *, status='in_progress', started=210, registered=True, ended=None):
        pid = 4000 + run_id if registered else None
        fingerprint = 9000 + run_id if registered else None
        self.db.execute('''INSERT INTO task_runs VALUES (?,?,?,?,?,?,?,?,?,?,?)''',
            (run_id, task_id, 'standard-implementer', 'done' if ended else 'running', started,
             ended, 'completed' if ended else None, '{}', pid, fingerprint, None))
        self.db.execute('''UPDATE tasks SET status=?,started_at=?,current_run_id=?,
            worker_pid=?,worker_started_at=?,claim_lock='fixture-host:claim',claim_expires=1000
            WHERE id=?''', (status, started, run_id, pid, fingerprint, task_id))
        self.db.execute('INSERT INTO task_events(task_id,run_id,kind,payload,created_at) VALUES (?,?,?,?,?)',
            (task_id, run_id, 'claimed', json.dumps({'run_id': run_id}), started))
        if registered:
            self.db.execute('INSERT INTO task_events(task_id,run_id,kind,payload,created_at) VALUES (?,?,?,?,?)',
                (task_id, run_id, 'worker_registered', json.dumps({'pid': pid, 'started_at': fingerprint}), started + 1))
        self.db.commit()

    def packet(self):
        packets = board_progress.collect(self.root, 'project')
        self.assertEqual(1, len(packets), 'Blocked delivery or unverified follow-through must stay observable')
        return packets[0]

    def complete_supervision(self, *, dispatched=('t_fix_a', 't_fix_b'), metadata=None):
        self.task('t_supervision', 'done', tenant='board-progress', creator='board-progress-monitor',
                  body='Goal: Advance existing requested work.\nDispatch policy: parallel-v1')
        payload = metadata if metadata is not None else {'board_progress': {'dispatched_task_ids': list(dispatched)}}
        self.db.execute('''INSERT INTO task_runs VALUES
            (10,'t_supervision','head-coordinator','done',100,200,'completed',?,NULL,NULL,NULL)''',
            (json.dumps(payload),))
        self.db.execute("UPDATE tasks SET assignee='head-coordinator',started_at=100,completed_at=200 WHERE id='t_supervision'")
        self.db.commit()

    def follow_through(self):
        observations = self.packet()['follow_through']
        self.assertEqual(1, len(observations))
        self.assertEqual('t_supervision', observations[0]['task_id'])
        return observations[0]

    def require_completion(self, metadata):
        # Native Hermes connections use named rows; the standalone fixture is
        # otherwise kept in tuple mode for direct byte/state assertions.
        self.db.row_factory = sqlite3.Row
        try:
            return board_progress.require_completion(self.db, 't_supervision', metadata)
        finally:
            self.db.row_factory = None

    def new_supervision(self):
        self.task('t_supervision', 'running', tenant='board-progress', creator='board-progress-monitor',
                  body='Goal: Advance existing requested work.\nDispatch policy: parallel-v1')
        self.db.execute('''INSERT INTO task_runs VALUES
            (10,'t_supervision','head-coordinator','running',100,NULL,NULL,'{}',NULL,NULL,NULL)''')
        self.db.execute("UPDATE tasks SET assignee='head-coordinator',started_at=100,current_run_id=10 WHERE id='t_supervision'")
        self.db.commit()

    def schedule_supervision(self):
        self.new_supervision()
        reason = 'Dispatch wait: ' + json.dumps({'dispatched_task_ids': ['t_fix_a', 't_fix_b']})
        self.db.execute("UPDATE tasks SET status='scheduled',current_run_id=NULL WHERE id='t_supervision'")
        self.db.execute("UPDATE task_runs SET status='scheduled',outcome='scheduled',ended_at=180 WHERE id=10")
        self.db.execute("INSERT INTO task_events(task_id,run_id,kind,payload,created_at) VALUES "
                        "('t_supervision',10,'scheduled',?,180)", (json.dumps({'reason': reason}),))
        self.db.commit()
        return reason

    def require_resume(self):
        self.db.row_factory = sqlite3.Row
        try:
            return board_progress.require_resume(self.db, 't_supervision')
        finally:
            self.db.row_factory = None

    def second_dispatch_wait(self, *, dispatched=('t_next_a', 't_next_b'), prior_unblock=True):
        self.schedule_supervision()
        self.start_worker('t_fix_a', 11, started=150, ended=200)
        self.start_worker('t_fix_b', 12, started=210, ended=240)
        if prior_unblock:
            self.db.execute("INSERT INTO task_events(task_id,run_id,kind,payload,created_at) VALUES "
                            "('t_supervision',NULL,'unblocked','{}',250)")
        self.db.execute("INSERT INTO task_runs VALUES "
                        "(30,'t_supervision','head-coordinator','scheduled',300,400,'scheduled','{}',NULL,NULL,NULL)")
        for task_id in dispatched:
            if not self.db.execute('SELECT 1 FROM tasks WHERE id=?', (task_id,)).fetchone():
                self.task(task_id, 'todo')
        reason = 'Dispatch wait: ' + json.dumps({'dispatched_task_ids': list(dispatched)})
        self.db.execute("INSERT INTO task_events(task_id,run_id,kind,payload,created_at) VALUES "
                        "('t_supervision',30,'scheduled',?,400)", (json.dumps({'reason': reason}),))
        self.db.commit()

    def test_queued_ready_and_review_cards_are_not_started_workers(self):
        self.db.execute("UPDATE tasks SET status='ready' WHERE id='t_fix_a'")
        self.db.execute("UPDATE tasks SET status='review' WHERE id='t_fix_b'")
        self.db.commit()
        packet = self.packet()
        self.assertEqual(0, packet['ready_running'], 'A dispatchable queue is not evidence of worker execution')
        self.assertEqual([], packet['worker_starts'])
        self.assertEqual({'t_fix_a', 't_fix_b'},
            {item['id'] for item in packet['candidates'] if item['status'] in ('ready', 'review')})

    def test_claim_without_spawn_is_not_proven_started(self):
        self.start_worker('t_fix_a', 11, status='running', registered=False)
        packet = self.packet()
        self.assertEqual(0, packet['ready_running'])
        self.assertEqual([], packet['worker_starts'])

    def test_legacy_evidence_schema_is_unknown_instead_of_crashing_or_guessing_activity(self):
        self.start_worker('t_fix_a', 11)
        self.db.execute('ALTER TABLE task_runs DROP COLUMN profile')
        self.db.commit()
        before = self.path.read_bytes()
        packet = self.packet()
        self.assertEqual('unavailable', packet['evidence_status'])
        self.assertIsNone(packet['started_workers'])
        self.assertIsNone(packet['ready_running'])
        self.assertEqual([], packet['worker_starts'])
        self.assertEqual(before, self.path.read_bytes())

    def test_empty_legacy_board_needs_no_project_or_execution_columns(self):
        self.db.execute('DROP TABLE tasks')
        self.db.execute('CREATE TABLE tasks(id TEXT,status TEXT,assignee TEXT,block_kind TEXT)')
        self.db.commit()
        before = self.path.read_bytes()
        self.assertEqual([], board_progress.collect(self.root, 'project'))
        self.assertEqual(before, self.path.read_bytes())

    def test_incompatible_collection_projection_is_unavailable_without_native_writes(self):
        for table, column in [('tasks', 'priority'), ('tasks', 'title'),
                              ('tasks', 'status'), ('task_links', 'parent_id')]:
            with self.subTest(table=table, column=column):
                root = self.root / (table + '-' + column)
                board = root / 'kanban/boards/project'
                board.mkdir(parents=True)
                (board / 'board.json').write_text('{}')
                path = board / 'kanban.db'
                with sqlite3.connect(path) as variant:
                    self.db.backup(variant)
                    variant.execute(f'ALTER TABLE {table} DROP COLUMN {column}')
                before = path.read_bytes()
                packets = board_progress.collect(root, 'project')
                self.assertEqual(1, len(packets))
                packet = packets[0]
                self.assertEqual('unavailable', packet['evidence_status'])
                self.assertIsNone(packet['started_workers'])
                self.assertEqual([], packet['candidates'])
                with patch.object(supervisor.subprocess, 'run') as native:
                    supervisor.wake_coordinator(root, 'project', 'board-progress', json.dumps(packet))
                native.assert_not_called()
                self.assertEqual(before, path.read_bytes())

    def test_native_in_progress_worker_is_counted_with_task_and_run_identity(self):
        self.start_worker('t_fix_a', 11)
        packet = self.packet()
        self.assertEqual(1, packet['ready_running'])
        self.assertEqual([('t_fix_a', 11)],
            [(item['task_id'], item['run_id']) for item in packet['worker_starts']])

    def test_matching_native_running_worker_is_supported(self):
        self.start_worker('t_fix_a', 11, status='running')
        packet = self.packet()
        self.assertEqual(1, packet['ready_running'])
        self.assertEqual([('t_fix_a', 11)],
            [(item['task_id'], item['run_id']) for item in packet['worker_starts']])

    def test_worker_evidence_for_another_attempt_or_task_does_not_prove_start(self):
        self.start_worker('t_fix_a', 10, status='running', ended=180, started=150)
        self.start_worker('t_fix_a', 11, status='running', registered=False)
        self.assertEqual(0, self.packet()['ready_running'], 'An old registered attempt cannot prove a new claim started')
        self.start_worker('t_fix_b', 12, status='running')
        self.db.execute("UPDATE tasks SET current_run_id=12 WHERE id='t_fix_a'")
        self.db.commit()
        packet = self.packet()
        self.assertEqual(1, packet['ready_running'])
        self.assertEqual([('t_fix_b', 12)],
            [(item['task_id'], item['run_id']) for item in packet['worker_starts']])

    def test_one_or_two_recovery_controllers_never_supply_project_activity(self):
        self.db.execute("UPDATE tasks SET tenant='technical-recovery',created_by='deadlock-recovery-monitor' "
                        "WHERE id IN ('t_fix_a','t_fix_b')")
        self.start_worker('t_fix_a', 11, status='running')
        self.assertEqual(0, self.packet()['ready_running'])
        self.start_worker('t_fix_b', 12, status='running')
        packet = self.packet()
        self.assertEqual(0, packet['ready_running'])
        self.assertEqual([], packet['worker_starts'])

    def test_readonly_collection_retains_real_gates_and_database_bytes(self):
        self.db.execute("UPDATE tasks SET block_kind='needs_input',body='Input supplier: owner. Exact credential gate.' "
                        "WHERE id='t_hold'")
        self.db.commit()
        before = self.path.read_bytes()
        packet = self.packet()
        candidates = {item['id']: item for item in packet['candidates']}
        self.assertEqual(['t_hold'], candidates['t_consumer']['waiting_on'])
        self.assertEqual('needs_input', candidates['t_hold']['block_kind'])
        self.assertEqual(packet, self.packet())
        self.assertEqual(before, self.path.read_bytes())

    def test_completed_handoff_without_worker_start_remains_visible(self):
        self.complete_supervision()
        observation = self.follow_through()
        self.assertEqual('awaiting_worker_start', observation['state'])
        self.assertEqual([], observation['worker_starts'])
        self.assertEqual(observation, self.follow_through())

    def test_two_independent_workers_start_while_the_original_hold_remains(self):
        self.complete_supervision()
        # First worker starts while the controller is still running, the second afterward.
        self.start_worker('t_fix_a', 11, started=150)
        self.start_worker('t_fix_b', 12, status='running', started=210)
        before = self.path.read_bytes()
        packet = self.packet()
        self.assertEqual(2, packet['started_workers'])
        self.assertEqual(2, packet['ready_running'])
        observation = self.follow_through()
        self.assertEqual('started', observation['state'])
        self.assertEqual({('t_fix_a', 11), ('t_fix_b', 12)},
            {(item['task_id'], item['run_id']) for item in observation['worker_starts']})
        self.assertEqual(('blocked', 'capability'),
            self.db.execute("SELECT status,block_kind FROM tasks WHERE id='t_hold'").fetchone())
        self.assertEqual([('t_hold', 't_consumer')], self.db.execute('SELECT * FROM task_links').fetchall())
        self.assertEqual(before, self.path.read_bytes())

    def test_unrelated_new_run_and_preexisting_target_start_do_not_satisfy_handoff(self):
        self.complete_supervision(dispatched=('t_fix_a',))
        self.start_worker('t_fix_a', 11, started=50)
        self.start_worker('t_fix_b', 12, started=210)
        observation = self.follow_through()
        self.assertEqual('awaiting_worker_start', observation['state'])
        self.assertEqual([], observation['worker_starts'])

    def test_completed_handoff_followup_reuses_owner_and_never_mints_controllers(self):
        self.complete_supervision()
        packet = self.packet()
        calls = []

        def native(command, **kwargs):
            calls.append(command)
            if 'comment' in command:
                at = command.index('comment')
                self.db.execute('INSERT INTO task_comments(task_id,author,body,created_at) VALUES (?,?,?,?)',
                                (command[at + 1], 'fleet-supervisor', command[at + 2], 300))
                self.db.commit()

        with patch.object(supervisor.subprocess, 'run', side_effect=native):
            supervisor.wake_coordinator(self.root, 'project', 'board-progress', json.dumps(packet))
            supervisor.wake_coordinator(self.root, 'project', 'board-progress', json.dumps(packet))
        self.assertFalse(any('create' in command for command in calls), 'Reuse the existing supervision owner')
        self.assertLessEqual(len(calls), 1, 'Unchanged failed follow-through must be deduplicated')
        self.assertEqual(1, self.db.execute("SELECT count(*) FROM tasks WHERE tenant='board-progress'").fetchone()[0])

    def test_no_safe_work_receipt_does_not_create_its_own_new_episode(self):
        self.complete_supervision(dispatched=())
        packet = self.packet()
        packet['follow_through'] = [{'task_id': 't_supervision', 'state': 'no_safe_independent_work'}]
        calls = []
        with patch.object(supervisor.subprocess, 'run', side_effect=lambda command, **kw: calls.append(command)):
            supervisor.wake_coordinator(self.root, 'project', 'board-progress', json.dumps(packet))
            packet['follow_through'][0]['task_id'] = 't_another_receipt'
            supervisor.wake_coordinator(self.root, 'project', 'board-progress', json.dumps(packet))
        keys = [command[command.index('--idempotency-key') + 1] for command in calls]
        self.assertEqual(2, len(keys))
        self.assertEqual(keys[0], keys[1], 'Monitoring receipts must not manufacture material board change')

    def test_terminal_legacy_receipt_allows_one_new_policy_owner_without_rewriting_history(self):
        self.complete_supervision(metadata={})
        self.db.execute("UPDATE tasks SET body='Goal: Preserve legacy supervision contract.' WHERE id='t_supervision'")
        self.db.commit()
        packet = self.packet()
        self.assertEqual('awaiting_worker_start', packet['follow_through'][0]['state'])
        before = self.path.read_bytes()
        calls = []
        with patch.object(supervisor.subprocess, 'run', side_effect=lambda command, **kw: calls.append(command)):
            for _ in range(2):
                supervisor.wake_coordinator(self.root, 'project', 'board-progress', json.dumps(packet))
        self.assertEqual(2, len(calls))
        self.assertTrue(all('create' in command and 'unblock' not in command for command in calls))
        keys = [command[command.index('--idempotency-key') + 1] for command in calls]
        self.assertEqual(keys[0], keys[1], 'The new policy owner must retain native idempotency')
        self.assertIn('Dispatch policy: parallel-v1', calls[0][calls[0].index('--body') + 1])
        self.assertEqual(before, self.path.read_bytes(), 'Legacy history and incident budgets stay untouched')

    def test_completion_refuses_card_creation_claim_only_or_unrelated_worker(self):
        self.new_supervision()
        receipt = {'board_progress': {'dispatched_task_ids': ['t_fix_a']}}
        with self.assertRaises(ValueError):
            self.require_completion(receipt)
        self.start_worker('t_fix_a', 11, registered=False)
        with self.assertRaises(ValueError):
            self.require_completion(receipt)
        self.start_worker('t_fix_b', 12)
        with self.assertRaises(ValueError):
            self.require_completion(receipt)

    def test_completion_accepts_matching_started_work_with_original_hold_preserved(self):
        self.new_supervision()
        self.start_worker('t_fix_a', 11, started=150)
        before = self.path.read_bytes()
        self.require_completion({'board_progress': {'dispatched_task_ids': ['t_fix_a']}})
        self.assertEqual(before, self.path.read_bytes())
        self.assertEqual('blocked', self.db.execute("SELECT status FROM tasks WHERE id='t_hold'").fetchone()[0])

    def test_no_safe_independent_work_requires_supplier_reason_and_wake_condition(self):
        self.new_supervision()
        valid = {'reason': 'All requested slices need the held versioned input.',
                 'supplier': 'agent', 'wake_condition': 'Qualified producer output v2 becomes available.'}
        self.require_completion({'board_progress': {'no_safe_independent_work': valid}})
        for omitted in valid:
            with self.subTest(omitted=omitted), self.assertRaises(ValueError):
                self.require_completion({'board_progress': {
                    'no_safe_independent_work': {key: value for key, value in valid.items() if key != omitted}}})

    def test_legacy_completed_controller_contract_is_not_retroactively_changed(self):
        self.new_supervision()
        self.db.execute("UPDATE tasks SET body='Existing exact acceptance contract.' WHERE id='t_supervision'")
        self.db.commit()
        before = self.path.read_bytes()
        self.require_completion({})
        self.assertEqual(before, self.path.read_bytes())

    def test_completion_requires_every_declared_task_to_start(self):
        self.new_supervision()
        self.start_worker('t_fix_a', 11)
        receipt = {'board_progress': {'dispatched_task_ids': ['t_fix_a', 't_fix_b']}}
        with self.assertRaises(ValueError):
            self.require_completion(receipt)
        self.start_worker('t_fix_b', 12)
        self.require_completion(receipt)

    def test_malformed_completion_receipts_never_supply_evidence(self):
        self.new_supervision()
        self.start_worker('t_fix_a', 11)
        malformed = [None, [], 'metadata is prose', {'board_progress': []},
                     {'board_progress': {'dispatched_task_ids': 't_fix_a'}},
                     {'board_progress': {'dispatched_task_ids': ['t_fix_a', 't_fix_a']}},
                     {'board_progress': {'dispatched_task_ids': ['t_supervision']}},
                     {'board_progress': {'dispatched_task_ids': [None]}},
                     {'board_progress': {'no_safe_independent_work': True}},
                     {'board_progress': {'dispatched_task_ids': ['t_fix_a'],
                                         'no_safe_independent_work': {'reason': 'mixed claims'}}}]
        before = self.path.read_bytes()
        for metadata in malformed:
            with self.subTest(metadata=metadata), self.assertRaises(ValueError):
                self.require_completion(metadata)
        self.assertEqual(before, self.path.read_bytes())

    def test_malformed_spawn_payload_cannot_hide_other_worker_or_prove_start(self):
        self.complete_supervision(dispatched=('t_fix_a',))
        self.start_worker('t_fix_a', 11)
        self.start_worker('t_fix_b', 12)
        malformed = ['{broken', '[]', 'null', 'true', '"prose"',
                     json.dumps({'pid': True, 'started_at': 1}),
                     json.dumps({'pid': 10}), json.dumps({'pid': -1, 'started_at': 1})]
        for payload in malformed:
            with self.subTest(payload=payload):
                self.db.execute("UPDATE task_events SET payload=? WHERE task_id='t_fix_a' AND kind='worker_registered'",
                                (payload,))
                self.db.commit()
                packet = self.packet()
                self.assertEqual([('t_fix_b', 12)],
                    [(item['task_id'], item['run_id']) for item in packet['worker_starts']])
                self.assertEqual('awaiting_worker_start', packet['follow_through'][0]['state'])

    def test_malformed_controller_run_metadata_stays_visible_without_claiming_progress(self):
        self.complete_supervision()
        for metadata in ('{broken', '[]', 'null', 'true', '"prose"', '{"board_progress": []}'):
            with self.subTest(metadata=metadata):
                self.db.execute("UPDATE task_runs SET metadata=? WHERE task_id='t_supervision'", (metadata,))
                self.db.commit()
                before = self.path.read_bytes()
                observation = self.follow_through()
                self.assertEqual('invalid_evidence', observation['state'])
                self.assertTrue(observation.get('error'))
                self.assertEqual([], observation['worker_starts'])
                self.assertEqual(before, self.path.read_bytes())

    def test_monitor_and_tracker_tasks_never_satisfy_delegation(self):
        self.new_supervision()
        self.start_worker('t_fix_a', 11)
        receipt = {'board_progress': {'dispatched_task_ids': ['t_fix_a']}}
        variants = [('technical-recovery', None, 'Ordinary title'),
                    ('board-progress', None, 'Ordinary title'),
                    (None, 'fleet-supervisor', 'Ordinary title'),
                    (None, 'board-progress-monitor', 'Ordinary title'),
                    (None, 'deadlock-recovery-monitor', 'Ordinary title'),
                    (None, 'aging-escalation', 'Ordinary title'),
                    (None, 'cron-loop-monitor', 'Ordinary title'),
                    (None, None, '[FEATURE TRACKER] Synthetic scope')]
        for tenant, creator, title in variants:
            with self.subTest(tenant=tenant, creator=creator, title=title):
                self.db.execute("UPDATE tasks SET tenant=?,created_by=?,title=? WHERE id='t_fix_a'",
                                (tenant, creator, title))
                self.db.commit()
                with self.assertRaises(ValueError):
                    self.require_completion(receipt)
                self.assertEqual([], self.packet()['worker_starts'])

    def test_coordinator_starting_another_routing_worker_cannot_satisfy_delegation(self):
        self.new_supervision()
        self.start_worker('t_fix_a', 11)
        self.db.execute("UPDATE task_runs SET profile='head-coordinator' WHERE id=11")
        self.db.execute("UPDATE tasks SET assignee='head-coordinator' WHERE id='t_fix_a'")
        self.db.commit()
        with self.assertRaises(ValueError):
            self.require_completion({'board_progress': {'dispatched_task_ids': ['t_fix_a']}})
        self.assertEqual([], self.packet()['worker_starts'])

    def test_foreign_task_spawn_and_event_predating_run_cannot_supply_evidence(self):
        self.new_supervision()
        self.start_worker('t_fix_a', 11)
        for task_id, created_at in [('t_fix_b', 211), ('t_fix_a', 209)]:
            with self.subTest(task_id=task_id, created_at=created_at):
                self.db.execute("UPDATE task_events SET task_id=?,created_at=? WHERE run_id=11 AND kind='worker_registered'",
                                (task_id, created_at))
                self.db.commit()
                with self.assertRaises(ValueError):
                    self.require_completion({'board_progress': {'dispatched_task_ids': ['t_fix_a']}})
                self.assertEqual([], self.packet()['worker_starts'])

    def test_scheduled_owner_requires_both_worker_starts_before_readonly_resume_qualification(self):
        self.schedule_supervision()
        with self.assertRaises(ValueError):
            self.require_resume()
        self.start_worker('t_fix_a', 11)
        with self.assertRaises(ValueError):
            self.require_resume()
        self.start_worker('t_fix_b', 12)
        before = self.path.read_bytes()
        self.assertTrue(self.require_resume())
        self.assertEqual(before, self.path.read_bytes(), 'Resume qualification is read-only')
        self.assertEqual('started', self.follow_through()['state'])
        self.assertEqual({'t_fix_a', 't_fix_b'}, set(self.follow_through()['dispatched_task_ids']))

    def test_second_productive_dispatch_batch_allows_same_owner_continuation(self):
        # Real native ordering: prior wait consumed, resumed owner dispatches a
        # new batch, workers start during that attempt and finish before wake.
        self.second_dispatch_wait()
        self.start_worker('t_next_a', 31, started=300, ended=360)
        self.start_worker('t_next_b', 32, started=350, ended=380)
        before = self.path.read_bytes()
        self.assertTrue(self.require_resume())
        self.assertEqual(before, self.path.read_bytes(), 'Qualification never writes or resets budgets')

    def test_native_evidence_attachment_preserves_fresh_dispatch_receipt(self):
        self.second_dispatch_wait()
        self.start_worker('t_next_a', 31, started=320, ended=360)
        self.start_worker('t_next_b', 32, started=350, ended=380)
        # kanban_db's native attachment emitters use `attached`. Documentary
        # input delivery must not consume or supersede the schedule receipt.
        self.db.execute("INSERT INTO task_events(task_id,run_id,kind,payload,created_at) VALUES "
                        "('t_supervision',NULL,'attached',?,410)",
                        (json.dumps({'filename': 'accepted-plan.md', 'size': 123, 'by': 'interactive-operator'}),))
        self.db.commit()
        before = self.path.read_bytes()
        self.assertTrue(self.require_resume())
        self.assertEqual(before, self.path.read_bytes())

    def test_later_wait_cannot_reuse_historical_worker_starts_or_old_receipt(self):
        # Also test without a prior unblock: freshness is independently required,
        # not merely a side effect of rejecting all historical continuations.
        self.second_dispatch_wait(dispatched=('t_fix_a', 't_fix_b'), prior_unblock=False)
        before = self.path.read_bytes()
        with self.assertRaises(ValueError):
            self.require_resume()
        self.assertEqual(before, self.path.read_bytes())
        self.assertEqual('started', self.follow_through()['state'],
                         'Retained follow-through still uses the canonical earliest owner start')

    def test_reused_task_ids_need_new_linked_worker_runs_for_every_batch_member(self):
        self.second_dispatch_wait(dispatched=('t_fix_a', 't_fix_b'))
        self.start_worker('t_fix_a', 31, started=299, ended=350)
        self.start_worker('t_fix_b', 32, started=320, registered=False)
        with self.assertRaises(ValueError):
            self.require_resume()
        self.start_worker('t_fix_a', 33, started=330, ended=360)
        with self.assertRaises(ValueError):
            self.require_resume()
        self.start_worker('t_fix_b', 34, started=350, ended=380)
        self.assertTrue(self.require_resume())

    def test_same_second_historical_runs_cannot_supply_a_new_dispatch_batch(self):
        self.second_dispatch_wait(dispatched=('t_fix_a', 't_fix_b'))
        # Native timestamps have second resolution. Both old workers, the first
        # unblock and the second owner claim can legally share this second.
        self.db.execute('UPDATE task_runs SET started_at=300,ended_at=300 WHERE id IN (11,12)')
        self.db.execute('UPDATE task_events SET created_at=300 WHERE run_id IN (11,12) OR kind=\'unblocked\'')
        self.db.commit()
        before = self.path.read_bytes()
        with self.assertRaises(ValueError):
            self.require_resume()
        self.assertEqual(before, self.path.read_bytes())
        # A later registration event still belongs to an old worker run.
        self.db.execute("INSERT INTO task_events(task_id,run_id,kind,payload,created_at) VALUES "
                        "('t_fix_a',11,'worker_registered',?,350)",
                        (json.dumps({'pid': 4011, 'started_at': 9011}),))
        self.db.commit()
        with self.assertRaises(ValueError):
            self.require_resume()
        self.start_worker('t_fix_a', 31, started=300, ended=360)
        with self.assertRaises(ValueError):
            self.require_resume()
        self.start_worker('t_fix_b', 32, started=300, ended=380)
        self.assertTrue(self.require_resume(), 'New runs in the same second and before owner completion qualify')

    def test_fresh_batch_partial_or_orphan_claim_cannot_continue(self):
        self.second_dispatch_wait(prior_unblock=False)
        self.start_worker('t_next_a', 31, started=320, ended=360)
        with self.assertRaises(ValueError):
            self.require_resume()
        self.start_worker('t_next_b', 32, started=350, registered=False)
        with self.assertRaises(ValueError):
            self.require_resume()
        # Another task's registration cannot be attached to the orphan claim.
        self.db.execute("INSERT INTO task_events(task_id,run_id,kind,payload,created_at) VALUES "
                        "('t_next_a',32,'worker_registered',?,351)",
                        (json.dumps({'pid': 4032, 'started_at': 9032}),))
        self.db.commit()
        with self.assertRaises(ValueError):
            self.require_resume()

    def test_second_dispatch_receipt_is_consumed_once_and_later_lifecycle_invalidates_it(self):
        self.second_dispatch_wait()
        self.start_worker('t_next_a', 31, started=320, ended=360)
        self.start_worker('t_next_b', 32, started=350, ended=380)
        self.assertTrue(self.require_resume())
        for kind in ('unblocked', 'blocked', 'claimed', 'completed'):
            with self.subTest(kind=kind):
                self.db.execute("INSERT INTO task_events(task_id,run_id,kind,payload,created_at) VALUES "
                                "('t_supervision',NULL,?,'{}',410)", (kind,))
                self.db.commit()
                before = self.path.read_bytes()
                with self.assertRaises(ValueError):
                    self.require_resume()
                self.assertEqual(before, self.path.read_bytes())
                self.db.execute("DELETE FROM task_events WHERE task_id='t_supervision' AND kind=? AND created_at=410", (kind,))
                self.db.commit()

    def test_later_owner_run_invalidates_older_schedule_event(self):
        self.second_dispatch_wait(prior_unblock=False)
        self.start_worker('t_next_a', 31, started=320, ended=360)
        self.start_worker('t_next_b', 32, started=350, ended=380)
        self.db.execute("INSERT INTO task_runs VALUES "
                        "(40,'t_supervision','head-coordinator','scheduled',500,550,'scheduled','{}',NULL,NULL,NULL)")
        self.db.commit()
        with self.assertRaises(ValueError):
            self.require_resume()

    def test_schedule_attempt_start_must_be_present_valid_and_before_its_end(self):
        self.schedule_supervision()
        self.start_worker('t_fix_a', 11)
        self.start_worker('t_fix_b', 12)
        for started in (None, 'unknown', 0, -1, 181):
            with self.subTest(started=started):
                self.db.execute('UPDATE task_runs SET started_at=? WHERE id=10', (started,))
                self.db.commit()
                before = self.path.read_bytes()
                with self.assertRaises(ValueError):
                    self.require_resume()
                self.assertEqual(before, self.path.read_bytes())

    def test_scheduled_owner_continuation_rejects_prior_release_typed_hold_and_failure_counters(self):
        self.schedule_supervision()
        self.start_worker('t_fix_a', 11)
        self.start_worker('t_fix_b', 12)
        for field, value in [('status', 'blocked'), ('status', 'triage'), ('block_kind', 'capability'),
                             ('block_kind', 'needs_input'), ('consecutive_failures', 1), ('block_recurrences', 1),
                             ('assignee', 'standard-implementer'), ('current_run_id', 10),
                             ('claim_lock', 'fixture-host:retained'), ('claim_expires', 1000), ('worker_pid', 4010)]:
            with self.subTest(field=field, value=value):
                self.db.execute(f'UPDATE tasks SET {field}=? WHERE id=?', (value, 't_supervision'))
                self.db.commit()
                before = self.path.read_bytes()
                with self.assertRaises(ValueError):
                    self.require_resume()
                self.assertEqual(before, self.path.read_bytes())
                self.db.execute("UPDATE tasks SET status='scheduled',block_kind=NULL,consecutive_failures=0,"
                                "block_recurrences=0,assignee='head-coordinator',current_run_id=NULL,claim_lock=NULL,"
                                "claim_expires=NULL,worker_pid=NULL WHERE id='t_supervision'")
                self.db.commit()
        self.db.execute("INSERT INTO task_events(task_id,run_id,kind,payload,created_at) VALUES "
                        "('t_supervision',10,'unblocked','{}',220)")
        self.db.commit()
        with self.assertRaises(ValueError):
            self.require_resume()

    def test_scheduled_evidence_is_retained_after_controller_followup_starts(self):
        self.schedule_supervision()
        self.start_worker('t_fix_a', 11)
        self.start_worker('t_fix_b', 12)
        self.db.execute("INSERT INTO task_runs VALUES "
                        "(21,'t_supervision','head-coordinator','running',230,NULL,NULL,'{}',NULL,NULL,NULL)")
        self.db.execute("UPDATE tasks SET status='running',current_run_id=21 WHERE id='t_supervision'")
        self.db.execute("INSERT INTO task_events(task_id,run_id,kind,payload,created_at) VALUES "
                        "('t_supervision',10,'unblocked','{}',220)")
        self.db.commit()
        observation = self.follow_through()
        self.assertEqual('started', observation['state'])
        self.assertEqual({'t_fix_a', 't_fix_b'}, set(observation['dispatched_task_ids']))

    def test_scheduled_owner_remains_observable_after_all_project_work_finishes(self):
        self.schedule_supervision()
        self.start_worker('t_fix_a', 11, ended=230)
        self.start_worker('t_fix_b', 12, ended=240)
        self.db.execute("UPDATE tasks SET status='done' WHERE tenant IS NULL")
        self.db.commit()
        packet = self.packet()
        self.assertEqual(0, packet['started_workers'])
        self.assertEqual([], packet['candidates'])
        self.assertEqual('started', packet['follow_through'][0]['state'])
        self.assertTrue(self.require_resume())
        self.db.execute("UPDATE tasks SET status='done' WHERE id='t_supervision'")
        self.db.commit()
        self.assertEqual([], board_progress.collect(self.root, 'project'))

    def test_scheduled_continuation_requires_matching_native_run_role_and_reason(self):
        good_reason = self.schedule_supervision()
        self.start_worker('t_fix_a', 11)
        self.start_worker('t_fix_b', 12)
        for payload in ('{broken', '{}', json.dumps({'reason': 'Wait for workers'}),
                        json.dumps({'reason': 'Dispatch wait: []'}),
                        json.dumps({'reason': 'Dispatch wait: {"dispatched_task_ids": []}'}),
                        json.dumps({'reason': good_reason + '\nProse cannot be part of JSON'})):
            with self.subTest(payload=payload):
                self.db.execute("UPDATE task_events SET payload=? WHERE task_id='t_supervision' AND kind='scheduled'", (payload,))
                self.db.commit()
                with self.assertRaises(ValueError):
                    self.require_resume()
        self.db.execute("UPDATE task_events SET payload=? WHERE task_id='t_supervision' AND kind='scheduled'",
                        (json.dumps({'reason': good_reason}),))
        self.db.execute("UPDATE task_events SET run_id=999 WHERE task_id='t_supervision' AND kind='scheduled'")
        self.db.commit()
        with self.assertRaises(ValueError):
            self.require_resume()
        self.db.execute("UPDATE task_events SET run_id=10 WHERE task_id='t_supervision' AND kind='scheduled'")
        for field, value in [('profile', 'standard-implementer'), ('status', 'blocked'), ('outcome', 'timed_out'), ('ended_at', None)]:
            with self.subTest(field=field, value=value):
                self.db.execute(f'UPDATE task_runs SET {field}=? WHERE id=10', (value,))
                self.db.commit()
                with self.assertRaises(ValueError):
                    self.require_resume()
                self.db.execute("UPDATE task_runs SET profile='head-coordinator',status='scheduled',outcome='scheduled',ended_at=180 WHERE id=10")
                self.db.commit()

    def test_legacy_supervision_is_never_automatically_resumed(self):
        self.schedule_supervision()
        self.start_worker('t_fix_a', 11)
        self.start_worker('t_fix_b', 12)
        self.db.execute("UPDATE tasks SET body='Existing exact acceptance contract.' WHERE id='t_supervision'")
        self.db.commit()
        self.assertFalse(self.require_resume())
        before = self.path.read_bytes()
        with patch.object(supervisor.subprocess, 'run') as native:
            supervisor.wake_coordinator(self.root, 'project', 'board-progress', json.dumps(self.packet()))
        native.assert_not_called()
        self.assertEqual(before, self.path.read_bytes())

    def test_supervisor_resumes_same_scheduled_owner_once_without_new_controller(self):
        self.schedule_supervision()
        calls = []

        def native(command, **kwargs):
            calls.append(command)
            self.assertIn('unblock', command)
            self.assertIn('t_supervision', command)
            self.assertNotIn('create', command)
            self.db.execute("UPDATE tasks SET status='ready' WHERE id='t_supervision'")
            self.db.execute("INSERT INTO task_events(task_id,run_id,kind,payload,created_at) VALUES "
                            "('t_supervision',NULL,'unblocked','{}',230)")
            self.db.commit()

        with patch.object(supervisor.subprocess, 'run', side_effect=native):
            supervisor.wake_coordinator(self.root, 'project', 'board-progress', json.dumps(self.packet()))
            self.assertEqual([], calls, 'Queued workers cannot release supervision')
            self.start_worker('t_fix_a', 11)
            supervisor.wake_coordinator(self.root, 'project', 'board-progress', json.dumps(self.packet()))
            self.assertEqual([], calls, 'Partial starts cannot release supervision')
            self.start_worker('t_fix_b', 12)
            supervisor.wake_coordinator(self.root, 'project', 'board-progress', json.dumps(self.packet()))
            supervisor.wake_coordinator(self.root, 'project', 'board-progress', json.dumps(self.packet()))
        self.assertEqual(1, len(calls))
        self.assertEqual(('blocked', 'capability'), self.db.execute("SELECT status,block_kind FROM tasks WHERE id='t_hold'").fetchone())
        self.assertEqual(('ready', 0, 0), self.db.execute("SELECT status,consecutive_failures,block_recurrences FROM tasks WHERE id='t_supervision'").fetchone())
        self.assertEqual(1, self.db.execute("SELECT count(*) FROM tasks WHERE tenant='board-progress'").fetchone()[0])

    def test_supervisor_continues_each_fresh_batch_once_through_existing_native_unblock_path(self):
        self.second_dispatch_wait()
        calls = []

        def native(command, **kwargs):
            calls.append(command)
            self.assertIn('unblock', command)
            self.assertIn('t_supervision', command)
            self.assertNotIn('create', command)
            # The CLI's ordinary unblock requalifies inside its transaction.
            self.assertTrue(self.require_resume())
            self.db.execute("UPDATE tasks SET status='ready' WHERE id='t_supervision'")
            self.db.execute("INSERT INTO task_events(task_id,run_id,kind,payload,created_at) VALUES "
                            "('t_supervision',NULL,'unblocked','{}',600)")
            self.db.commit()

        with patch.object(supervisor.subprocess, 'run', side_effect=native):
            for command_count, run_id, started in ((1, 30, 300), (2, 40, 500)):
                if run_id == 40:
                    # Reuse task IDs, but no worker starts from this attempt yet.
                    self.db.execute("INSERT INTO task_runs VALUES "
                                    "(40,'t_supervision','head-coordinator','scheduled',500,580,'scheduled','{}',NULL,NULL,NULL)")
                    self.db.execute("UPDATE tasks SET status='scheduled' WHERE id='t_supervision'")
                    reason = 'Dispatch wait: ' + json.dumps({'dispatched_task_ids': ['t_next_a', 't_next_b']})
                    self.db.execute("INSERT INTO task_events(task_id,run_id,kind,payload,created_at) VALUES "
                                    "('t_supervision',40,'scheduled',?,580)", (json.dumps({'reason': reason}),))
                    self.db.commit()
                for task_id, worker_run in (('t_next_a', run_id + 1), ('t_next_b', run_id + 2)):
                    supervisor.wake_coordinator(self.root, 'project', 'board-progress', json.dumps(self.packet()))
                    self.assertEqual(command_count - 1, len(calls), 'Old or partial starts cannot wake the owner')
                    self.start_worker(task_id, worker_run, started=started + 10, ended=started + 30)
                supervisor.wake_coordinator(self.root, 'project', 'board-progress', json.dumps(self.packet()))
                supervisor.wake_coordinator(self.root, 'project', 'board-progress', json.dumps(self.packet()))
                self.assertEqual(command_count, len(calls), 'Each exact receipt is consumed once')
        self.assertEqual(('ready', 0, 0), self.db.execute("SELECT status,consecutive_failures,block_recurrences FROM tasks WHERE id='t_supervision'").fetchone())
        self.assertEqual(('blocked', 'capability'), self.db.execute("SELECT status,block_kind FROM tasks WHERE id='t_hold'").fetchone())
        self.assertEqual([('t_hold', 't_consumer')], self.db.execute('SELECT * FROM task_links').fetchall())
        self.assertEqual(1, self.db.execute("SELECT count(*) FROM tasks WHERE tenant='board-progress'").fetchone()[0])


unittest.main(argv=[sys.argv[0]])
PY
