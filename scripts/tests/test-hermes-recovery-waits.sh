#!/usr/bin/env bash
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if [[ "${HERMES_FIXTURE_ACTIVE:-}" != 1 ]]; then
  exec python3 -B "$repo/scripts/hermes/fixture-runner.py" --repo "$repo" \
    --suite "$repo/scripts/tests/test-hermes-recovery-waits.sh"
fi
scratch="$(mktemp -d "${TMPDIR:-/tmp}/hermes-recovery-waits.XXXXXX")"
trap 'rm -rf -- "$scratch"' EXIT
python3 -B - "$repo" "$scratch" <<'PY'
import importlib.util
import json
from pathlib import Path
import sqlite3
import subprocess
import sys
import unittest
from unittest.mock import patch

source = Path(sys.argv[1]) / 'scripts/hermes'
sys.path.insert(0, str(source))
spec = importlib.util.spec_from_file_location('supervisor', source / 'fleet-supervisor.py')
supervisor = importlib.util.module_from_spec(spec)
spec.loader.exec_module(supervisor)
scratch = Path(sys.argv[2])
PREFIX = 'Recovery wait: '


class RecoveryWaitTest(unittest.TestCase):
    def setUp(self):
        self.root = scratch / self.id().rsplit('.', 1)[-1]
        self.board = self.root / 'kanban/boards/project'
        self.board.mkdir(parents=True)
        (self.board / 'board.json').write_text('{}')
        self.db = sqlite3.connect(self.board / 'kanban.db')
        self.db.row_factory = sqlite3.Row
        self.addCleanup(self.db.close)
        self.db.executescript('''
            CREATE TABLE tasks(id TEXT PRIMARY KEY,title TEXT,body TEXT,status TEXT,
                assignee TEXT,tenant TEXT,created_by TEXT,block_kind TEXT,
                current_run_id INTEGER,worker_pid INTEGER,claim_lock TEXT,claim_expires INTEGER,
                consecutive_failures INTEGER DEFAULT 0,block_recurrences INTEGER DEFAULT 0,
                max_retries INTEGER DEFAULT 1,max_runtime_seconds INTEGER DEFAULT 900,
                workspace_path TEXT DEFAULT '/prepared/source');
            CREATE TABLE task_runs(id INTEGER PRIMARY KEY,task_id TEXT,profile TEXT,status TEXT,
                started_at INTEGER,ended_at INTEGER,outcome TEXT);
            CREATE TABLE task_events(id INTEGER PRIMARY KEY AUTOINCREMENT,task_id TEXT,
                run_id INTEGER,kind TEXT,payload TEXT,created_at INTEGER);
            CREATE TABLE task_links(parent_id TEXT,child_id TEXT);
        ''')
        self.db.executemany('INSERT INTO tasks(id,title,status,assignee,tenant,created_by) '
            'VALUES (?,?,?,?,?,?)', [
                ('t_owner', 'Reconcile original result', 'scheduled', 'head-coordinator',
                 'technical-recovery', 'deadlock-recovery-monitor'),
                ('t_original', 'Existing requested work', 'ready', 'feature-reviewer', None, None),
                ('t_gate', 'Original acceptance gate', 'blocked', 'head-coordinator', None, None),
                ('t_consumer', 'Original product consumer', 'todo', 'standard-implementer', None, None)])
        self.db.execute("UPDATE tasks SET block_kind='capability' WHERE id='t_gate'")
        self.db.execute("INSERT INTO task_links VALUES ('t_gate','t_consumer')")
        self.db.execute("INSERT INTO task_runs VALUES (10,'t_owner','head-coordinator',"
                        "'scheduled',100,150,'scheduled')")
        self.wait()
        self.calls = []

    def wait(self, until='terminal', after_run_id=9, task_id='t_original'):
        self.db.execute("DELETE FROM task_events WHERE task_id='t_owner'")
        reason = PREFIX + json.dumps(dict(task_id=task_id, after_run_id=after_run_id, until=until))
        self.event('t_owner', 10, 'scheduled', 150, {'reason': reason})

    def event(self, task_id, run_id, kind, when, payload=None):
        self.db.execute('INSERT INTO task_events(task_id,run_id,kind,payload,created_at) '
            'VALUES (?,?,?,?,?)', (task_id, run_id, kind, json.dumps(payload), when))
        self.db.commit()

    def original(self, *, finished=True, started=160, ended=200, run_id=11, spawn=True,
                 outcome='completed'):
        self.db.execute('INSERT INTO task_runs VALUES (?,?,?,?,?,?,?)',
            (run_id, 't_original', 'feature-reviewer', 'done' if finished else 'running',
             started, ended if finished else None, outcome if finished else None))
        self.db.execute("UPDATE tasks SET status=?,current_run_id=? WHERE id='t_original'",
                        ('done' if finished else 'running', None if finished else run_id))
        self.event('t_original', run_id, 'claimed', started, {'run_id': run_id})
        if spawn:
            self.event('t_original', run_id, 'spawned', started + 1,
                       {'pid': 1234, 'started_at': 'fixture:1234'})
        if finished:
            self.event('t_original', run_id, 'completed', ended)

    def require(self):
        import recovery_wait
        return recovery_wait.require_resume(self.db, 't_owner')

    def native(self, command, **kwargs):
        self.calls.append(command)
        self.assertIn('unblock', command)
        self.assertNotIn('create', command)
        self.assertIn('t_owner', command)
        self.assertEqual('project', command[command.index('--board') + 1])
        self.assertTrue(self.require(), 'Native transaction must recheck the wait')
        self.db.execute("UPDATE tasks SET status='ready' WHERE id='t_owner'")
        self.event('t_owner', None, 'unblocked', 210)
        return subprocess.CompletedProcess(command, 0, '', '')

    def tick(self):
        result = dict(output='', wake_pending=True, exit_code=0)
        supervisor.deliver_wake(self.root, 'project', 'technical-recovery', result, 220)
        return result

    def state(self):
        return [tuple(r) for r in self.db.execute('SELECT * FROM tasks ORDER BY id')]

    def test_recovery_tick_resumes_completed_result_wait_once_without_new_controller(self):
        self.original()
        before = self.state()
        with patch.object(supervisor.subprocess, 'run', side_effect=self.native):
            result = self.tick()
            self.tick()
        self.assertEqual(1, len(self.calls), 'The existing recovery tick must wake the parked owner')
        self.assertFalse(result['wake_pending'])
        expected = [list(row) for row in before]
        next(row for row in expected if row[0] == 't_owner')[3] = 'ready'
        self.assertEqual([tuple(row) for row in expected], self.state())
        self.assertEqual([('t_gate', 't_consumer')],
                         [tuple(r) for r in self.db.execute('SELECT * FROM task_links')])

    def test_queued_and_claimed_workers_do_not_satisfy_start_wait(self):
        self.wait(until='started')
        with self.assertRaises(ValueError):
            self.require()
        self.original(finished=False, spawn=False)
        with self.assertRaises(ValueError):
            self.require()
        self.event('t_original', 11, 'spawned', 170, {'pid': 1234, 'started_at': 'fixture:1234'})
        self.assertTrue(self.require())

    def test_terminal_wait_does_not_resume_from_start_alone(self):
        self.original(finished=False)
        with patch.object(supervisor.subprocess, 'run', side_effect=self.native):
            self.tick()
        self.assertEqual([], self.calls)

    def test_existing_tick_checks_waits_even_when_handler_output_is_empty(self):
        self.original()
        handler = ('technical-recovery', 300, 90, 'python', 'deadlock_recovery.py', ())
        with patch.object(supervisor, 'HANDLERS', (handler,)), \
             patch.object(supervisor.subprocess, 'run', side_effect=self.native):
            self.assertEqual(0, supervisor.tick(self.root, now=220,
                runner=lambda *args, **kwargs: dict(exit_code=0, output='')))
        self.assertEqual(1, len(self.calls))
        journal = json.loads((self.root/'state/fleet/supervisor.json').read_text())
        self.assertEqual(520, journal['handlers']['technical-recovery']['next_due'])

    def test_paused_technical_recovery_does_not_resume_waits(self):
        self.original()
        directory = self.root/'state/fleet'
        directory.mkdir(parents=True)
        (directory/'handlers.json').write_text(json.dumps({'technical-recovery': {'enabled': False}}))
        handler = ('technical-recovery', 300, 90, 'python', 'deadlock_recovery.py', ())
        with patch.object(supervisor, 'HANDLERS', (handler,)), \
             patch.object(supervisor.subprocess, 'run') as native:
            self.assertEqual(0, supervisor.tick(self.root, now=220))
        native.assert_not_called()

    def test_terminal_handoff_survives_assignment_change(self):
        self.original()
        self.db.execute("UPDATE tasks SET assignee='project-auditor' WHERE id='t_original'")
        self.assertTrue(self.require())

    def test_native_recheck_rejects_result_changed_after_supervisor_observation(self):
        self.original()
        def race(command, **kwargs):
            self.db.execute("DELETE FROM task_events WHERE kind='completed'")
            self.db.commit()
            with self.assertRaises(ValueError):
                self.require()
            raise subprocess.CalledProcessError(1, command)
        with patch.object(supervisor.subprocess, 'run', side_effect=race):
            result = self.tick()
        self.assertTrue(result['wake_pending'])
        self.assertEqual('scheduled', self.db.execute("SELECT status FROM tasks WHERE id='t_owner'").fetchone()[0])

    def test_old_results_and_explicit_run_floor_do_not_satisfy_wait(self):
        self.original(started=50, ended=90)
        with self.assertRaises(ValueError):
            self.require()
        self.db.execute('UPDATE task_runs SET started_at=160,ended_at=200 WHERE id=11')
        self.db.execute("UPDATE task_events SET created_at=200 WHERE kind='completed'")
        self.wait(after_run_id=11)
        with self.assertRaises(ValueError):
            self.require()

    def test_result_of_worker_already_running_when_owner_started_can_wake_it(self):
        self.original(started=50, ended=200)
        self.assertTrue(self.require())

    def test_terminal_result_is_observation_and_does_not_require_acceptance(self):
        self.original()
        self.db.execute('UPDATE task_runs SET status=\'blocked\',outcome=\'blocked\' WHERE id=11')
        self.db.execute("UPDATE tasks SET status='blocked',block_kind='capability' WHERE id='t_original'")
        self.db.execute("UPDATE task_events SET kind='blocked' WHERE kind='completed'")
        self.db.commit()
        with patch.object(supervisor.subprocess, 'run', side_effect=self.native):
            self.tick()
        self.assertEqual(1, len(self.calls))
        self.assertEqual('capability', self.db.execute("SELECT block_kind FROM tasks WHERE id='t_original'").fetchone()[0])

    def test_native_dependency_wait_and_rate_limit_results_wake_only_the_owner(self):
        self.original()
        for outcome, kind, status in [('blocked', 'dependency_wait', 'todo'),
                                      ('rate_limited', 'rate_limited', 'ready')]:
            with self.subTest(outcome=outcome):
                self.db.execute('UPDATE task_runs SET status=?,outcome=? WHERE id=11',
                                (outcome, outcome))
                self.db.execute("UPDATE tasks SET status=?,block_kind='dependency' WHERE id='t_original'",
                                (status,))
                self.db.execute("UPDATE task_events SET kind=? WHERE task_id='t_original' AND created_at=200",
                                (kind,))
                self.db.commit()
                before = self.state()
                with patch.object(supervisor.subprocess, 'run', side_effect=self.native):
                    self.tick()
                self.assertEqual('ready', self.db.execute("SELECT status FROM tasks WHERE id='t_owner'").fetchone()[0])
                self.assertEqual([r for r in before if r[0] != 't_owner'],
                                 [r for r in self.state() if r[0] != 't_owner'])
                self.db.execute("UPDATE tasks SET status='scheduled' WHERE id='t_owner'")
                self.wait()
        self.assertEqual(2, len(self.calls))

    def test_native_recovery_terminal_pairs_still_require_the_correlated_event(self):
        self.original()
        pairs = [('crashed', 'protocol_violation'), ('stale', 'stale'),
                 ('reclaimed', 'reclaimed'), ('reclaimed', 'reconciled'),
                 ('reclaimed', 'archived'), ('reclaimed', 'descendant_invalidated')]
        for outcome, kind in pairs:
            with self.subTest(outcome=outcome, kind=kind):
                self.db.execute('UPDATE task_runs SET status=?,outcome=? WHERE id=11',
                                (outcome, outcome))
                self.db.execute("UPDATE task_events SET kind=?,run_id=11 WHERE task_id='t_original' AND created_at=200",
                                (kind,))
                self.assertTrue(self.require())
                self.db.execute("UPDATE task_events SET run_id=99 WHERE task_id='t_original' AND created_at=200")
                with self.assertRaisesRegex(ValueError, 'matching native terminal event'):
                    self.require()

    def test_gate_counters_workers_and_typed_holds_cannot_be_automatically_released(self):
        self.original()
        changes = ["consecutive_failures=1", "block_recurrences=1", "worker_pid=1234",
                   "claim_lock='active'", "claim_expires=999", "current_run_id=12",
                   "block_kind='capability'", "block_kind='needs_input'", "block_kind='transient'",
                   "assignee='standard-implementer'", "tenant='board-progress'",
                   "title='[FEATURE TRACKER] Keep parked'"]
        for change in changes:
            with self.subTest(change=change):
                self.db.execute('SAVEPOINT candidate')
                self.db.execute("UPDATE tasks SET " + change + " WHERE id='t_owner'")
                with self.assertRaises(ValueError):
                    self.require()
                self.db.execute('ROLLBACK TO candidate')
                self.db.execute('RELEASE candidate')
        self.db.execute("UPDATE tasks SET block_kind='dependency' WHERE id='t_owner'")
        self.assertTrue(self.require())

    def test_new_owner_run_and_prior_release_invalidate_schedule(self):
        self.original()
        self.event('t_owner', None, 'unblocked', 205)
        with self.assertRaises(ValueError):
            self.require()
        self.wait()
        self.db.execute("INSERT INTO task_runs VALUES (12,'t_owner','head-coordinator','scheduled',180,190,'scheduled')")
        with self.assertRaises(ValueError):
            self.require()

    def test_no_wake_from_comments_missing_terminal_event_or_mismatched_run(self):
        self.original()
        self.db.execute("DELETE FROM task_events WHERE kind='completed'")
        self.event('t_original', 11, 'commented', 200, {'body': 'Completed successfully'})
        with self.assertRaises(ValueError):
            self.require()
        self.event('t_original', 99, 'completed', 200)
        with self.assertRaises(ValueError):
            self.require()

    def test_attachments_do_not_consume_wait_but_scope_changes_do(self):
        self.original()
        self.event('t_owner', None, 'attached', 205, {'filename': 'receipt.json'})
        self.assertTrue(self.require())
        self.event('t_owner', None, 'coordinator_amended', 206)
        with self.assertRaises(ValueError):
            self.require()

    def test_malformed_self_missing_and_unknown_fields_fail_closed(self):
        self.original()
        invalid = [None, [], {}, {'task_id': 't_owner', 'after_run_id': 9, 'until': 'terminal'},
                   {'task_id': 't_missing', 'after_run_id': 9, 'until': 'terminal'},
                   {'task_id': 'other:t_original', 'after_run_id': 9, 'until': 'terminal'},
                   {'task_id': 't_original', 'after_run_id': True, 'until': 'terminal'},
                   {'task_id': 't_original', 'after_run_id': -1, 'until': 'terminal'},
                   {'task_id': 't_original', 'after_run_id': 9, 'until': 'accepted'},
                   {'task_id': 't_original', 'after_run_id': 9, 'until': 'terminal', 'board': 'other'}]
        for value in invalid:
            with self.subTest(value=value):
                self.db.execute("UPDATE task_events SET payload=? WHERE task_id='t_owner' AND kind='scheduled'",
                    (json.dumps({'reason': PREFIX + json.dumps(value)}),))
                with self.assertRaises(ValueError):
                    self.require()

    def test_legacy_prose_is_observed_but_never_inferred_or_unblocked(self):
        self.original()
        self.db.execute("UPDATE task_events SET payload=? WHERE task_id='t_owner' AND kind='scheduled'",
                        (json.dumps({'reason': 'Wait for t_original to finish'}),))
        self.db.commit()
        with patch.object(supervisor.subprocess, 'run') as native:
            result = self.tick()
        native.assert_not_called()
        self.assertEqual(1, result['recovery_waits']['unregistered'])

    def test_long_unregistered_reasons_remain_outside_the_recovery_guard(self):
        self.original()
        for reason in ('Wait for an ordinary result. '*160, 'Long Unicode prose: '+('\u2603'*5000),
                       'Recovery wait without the registration delimiter. '*100):
            with self.subTest(prefix=reason[:30]):
                self.db.execute("UPDATE task_events SET payload=? WHERE task_id='t_owner' AND kind='scheduled'",
                                (json.dumps({'reason': reason}),))
                self.db.commit()
                self.assertFalse(self.require())
                with patch.object(supervisor.subprocess, 'run') as native:
                    result = self.tick()
                native.assert_not_called()
                self.assertEqual(1, result['recovery_waits']['unregistered'])

    def test_registered_receipts_still_enforce_reason_and_payload_bounds(self):
        self.original()
        reason = PREFIX+json.dumps(dict(task_id='t_original', after_run_id=9, until='terminal'))
        for payload in ({'reason': reason+' '*1100}, {'reason': reason, 'extra': 'x'*4100}):
            with self.subTest(keys=list(payload)):
                self.db.execute("UPDATE task_events SET payload=? WHERE task_id='t_owner' AND kind='scheduled'",
                                (json.dumps(payload),))
                with self.assertRaisesRegex(ValueError, 'bound'):
                    self.require()

    def test_native_rejection_is_reported_without_switching_interfaces(self):
        self.original()
        with patch.object(supervisor.subprocess, 'run', side_effect=subprocess.CalledProcessError(1, ['hermes'])) as native:
            result = self.tick()
        self.assertTrue(result['wake_pending'])
        self.assertEqual(1, native.call_count)
        self.assertEqual('scheduled', self.db.execute("SELECT status FROM tasks WHERE id='t_owner'").fetchone()[0])

    def test_refused_receipt_is_not_retried_unchanged_on_later_ticks(self):
        self.original()
        handler = ('technical-recovery', 300, 90, 'python', 'deadlock_recovery.py', ())
        runner = lambda *args, **kwargs: dict(exit_code=0, output='')
        with patch.object(supervisor, 'HANDLERS', (handler,)), \
             patch.object(supervisor.subprocess, 'run', side_effect=subprocess.CalledProcessError(1, ['hermes'])) as native:
            self.assertEqual(1, supervisor.tick(self.root, now=220, runner=runner))
            supervisor.tick(self.root, now=521, runner=runner)
            supervisor.tick(self.root, now=822, runner=runner)
        self.assertEqual(1, native.call_count)
        journal=json.loads((self.root/'state/fleet/supervisor.json').read_text())
        self.assertEqual(1, len(journal['handlers']['technical-recovery']['recovery_wait_refusals']))


class ComponentReleaseTest(unittest.TestCase):
    def setUp(self):
        spec = importlib.util.spec_from_file_location('release', source/'fleet-release.py')
        self.release = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.release)
        self.root = scratch/self.id().rsplit('.', 1)[-1]
        self.root.mkdir()
        self.checkout = self.root/'source'
        self.files = {
            'scripts/fleet-release.py': 'scripts/hermes/fleet-release.py',
            'scripts/fleet-supervisor.py': 'scripts/hermes/fleet-supervisor.py',
            'scripts/deadlock_recovery.py': 'scripts/hermes/deadlock_recovery.py',
            'scripts/hermes-capability-recovery.md': 'scripts/hermes/instructions/capability-recovery.md',
            'scripts/hermes-coordinator-reference.md': 'scripts/hermes/instructions/coordinator-reference.md',
        }
        self.predecessors = {}
        entries = []
        for target, original in self.files.items():
            before = '# retained predecessor '+target+'\n'
            path = self.root/target
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(before)
            candidate = self.checkout/original
            candidate.parent.mkdir(parents=True, exist_ok=True)
            candidate.write_text(before+'# reviewed recovery change\n')
            self.predecessors[original] = before.encode()
            entries.append(dict(path=target, after_sha256=self.release.sha(path.read_bytes()), mode=path.stat().st_mode&0o777))
        for name, value in [('profiles/head-coordinator/config.yaml', 'model: retained\n'),
                            ('profiles/board-steward/SOUL.md', 'independent instructions\n'),
                            ('hermes-agent/hermes_cli/kanban_db.py', 'native baseline\n')]:
            path = self.root/name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(value)
            entries.append(dict(path=name, after_sha256=self.release.sha(path.read_bytes()), mode=path.stat().st_mode&0o777))
        (self.checkout/'scripts/hermes/recovery_wait.py').write_text('# qualified helper\n')
        current = self.root/'state/fleet/current.json'
        current.parent.mkdir(parents=True)
        current.write_text(json.dumps(dict(status='active', revision='a'*64)))
        manifest = current.parent/'releases'/('a'*64)/'manifest.json'
        manifest.parent.mkdir(parents=True)
        manifest.write_text(json.dumps(dict(status='active', source_revision='b'*40, files=entries,
            retained_external_changes=['profiles/board-steward/SOUL.md'])))

    def plan(self, *, drift=(), during=None):
        import worker_runtime_adapter
        import recovered_resume_adapter
        owners, retained, inputs, schedules = {}, [], {}, []
        def adapt(name, value):
            if during:
                during()
            return value+'# native wait recheck\n'
        with patch.object(self.release, 'check_files', return_value=list(drift)), \
             patch.object(self.release, 'coordinator_schedule_updates', return_value=[]), \
             patch.object(self.release.subprocess, 'run'), \
             patch.object(self.release.subprocess, 'check_output', side_effect=lambda argv: self.predecessors[argv[-1].split(':',1)[1]]), \
             patch.object(worker_runtime_adapter, 'adapt', side_effect=adapt), \
             patch.object(recovered_resume_adapter, 'adapt', side_effect=lambda name, value: value):
            pending = self.release.recovery_wait_component_files(self.root, self.checkout,
                owners=owners, retained=retained, inputs=inputs, schedule_updates=schedules)
        return pending, owners, retained, inputs

    def test_scoped_release_retains_independent_files_and_binds_every_preimage(self):
        before = {str(p.relative_to(self.root)): p.read_bytes() for p in self.root.rglob('*') if p.is_file()}
        pending, owners, retained, inputs = self.plan()
        self.assertEqual('model: retained\n', pending[self.root/'profiles/head-coordinator/config.yaml'])
        self.assertEqual('independent instructions\n', pending[self.root/'profiles/board-steward/SOUL.md'])
        self.assertEqual(['profiles/board-steward/SOUL.md'], retained)
        changed = {str(p.relative_to(self.root)) for p, content in pending.items()
                   if not p.exists() or p.read_text() != content}
        self.assertEqual(set(self.files)|{'hermes-agent/hermes_cli/kanban_db.py',
            'hermes-agent/hermes_cli/nixhomeserver_recovery_wait.py','scripts/recovery_wait.py'}, changed)
        self.assertEqual(set(inputs), {str(p.relative_to(self.root)) for p in pending})
        self.assertIsNone(inputs['scripts/recovery_wait.py']['sha256'])
        self.assertEqual(before, {str(p.relative_to(self.root)): p.read_bytes() for p in self.root.rglob('*') if p.is_file()})

    def test_scoped_release_refuses_drift_and_unknown_target_preimages(self):
        with self.assertRaisesRegex(ValueError, 'drift'):
            self.plan(drift=['scripts/fleet-supervisor.py'])
        (self.root/'scripts/fleet-supervisor.py').write_text('# unrelated newer source\n')
        manifest_path = self.root/'state/fleet/releases'/('a'*64)/'manifest.json'
        manifest = json.loads(manifest_path.read_text())
        next(item for item in manifest['files'] if item['path']=='scripts/fleet-supervisor.py')['after_sha256'] = self.release.sha(b'# unrelated newer source\n')
        manifest_path.write_text(json.dumps(manifest))
        with self.assertRaisesRegex(ValueError, 'current maintained source'):
            self.plan()

    def test_scoped_release_never_adopts_an_unowned_helper(self):
        (self.root/'scripts/recovery_wait.py').write_text('# another owner\n')
        with self.assertRaisesRegex(ValueError, 'outside fleet ownership'):
            self.plan()

    def test_scoped_release_refuses_retained_bytes_changed_during_composition(self):
        path = self.root/'profiles/head-coordinator/config.yaml'
        with self.assertRaisesRegex(ValueError, 'input changed during preparation'):
            self.plan(during=lambda: path.write_text('model: concurrent edit\n'))
        self.assertEqual('model: concurrent edit\n', path.read_text())

    def test_scoped_release_refuses_retained_mode_changed_during_composition(self):
        path = self.root/'profiles/head-coordinator/config.yaml'
        mode = path.stat().st_mode&0o777
        with self.assertRaisesRegex(ValueError, 'input changed during preparation'):
            self.plan(during=lambda: path.chmod(mode ^ 0o100))
        self.assertEqual(mode ^ 0o100, path.stat().st_mode&0o777)

    def test_scoped_release_refuses_new_helper_created_during_composition(self):
        path = self.root/'scripts/recovery_wait.py'
        with self.assertRaises(ValueError):
            self.plan(during=lambda: path.write_text('# concurrent helper\n'))
        self.assertEqual('# concurrent helper\n', path.read_text())


unittest.main(argv=[sys.argv[0]], verbosity=2)
PY
