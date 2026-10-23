#!/usr/bin/env bash
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
python3 -B - "$repo" <<'PY'
import importlib.util
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import time
import unittest

source = Path(sys.argv[1]) / 'scripts/hermes/cron-loop-monitor.py'
spec = importlib.util.spec_from_file_location('loopmon', source)
mon = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mon)

HOUR = 3600
EXEC_SCHEMA = """
CREATE TABLE executions (
    id TEXT PRIMARY KEY, job_id TEXT NOT NULL, source TEXT NOT NULL,
    process_id TEXT NOT NULL, pid INTEGER NOT NULL, process_started_at INTEGER,
    status TEXT NOT NULL, claimed_at TEXT NOT NULL, started_at TEXT,
    finished_at TEXT, error TEXT, delivery_outcome TEXT,
    scheduled_instant TEXT
);
"""
CONFIG_ERR = 'owner alerts: Owner home channel must be a numeric allowlisted contact'


def iso(epoch):
    return time.strftime('%Y-%m-%dT%H:%M:%S', time.localtime(epoch))


def rows(now, runs, job_id='job_alerts'):
    """runs: (status, error, outcome, hours_ago). Ascending by claimed_at."""
    out = [dict(job_id=job_id, claimed_at=iso(now - int(h * HOUR)),
                status=s, error=e, delivery_outcome=o) for s, e, o, h in runs]
    out.sort(key=lambda r: r['claimed_at'])
    return out


class LoopMonitorTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='cron-loop-test-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.report = []
        self.now = time.time()

    # --- detection ------------------------------------------------------

    def detect(self, job_id='job_alerts', name='kanban owner blocker alerts',
               **kw):
        return mon.detection_for_job(
            job_id, {'name': name}, rows(self.now, kw.pop('runs')),
            kw.pop('window', mon.DEFAULT_WINDOW_HOURS), self.now)

    def test_quiet_non_delivery_job_is_healthy(self):
        # All-suppressed runs are normal idleness for ordinary monitors.
        runs = [('completed', None, 'suppressed', h) for h in (0.2, 1, 2, 3)]
        self.assertEqual([], self.detect(name='kanban retry breaker',
                                         runs=runs))

    def test_quiet_delivery_job_inside_threshold_is_healthy(self):
        runs = [('completed', None, 'suppressed', 0.2),
                ('completed', None, 'suppressed', 4)]
        self.assertEqual([], self.detect(runs=runs))

    def test_persistent_silence_on_delivery_job_trips(self):
        runs = [('completed', None, 'suppressed', 40 + h) for h in range(3)]
        signals = self.detect(runs=runs)
        self.assertEqual(1, len(signals))
        self.assertEqual('persistent-silence', signals[0]['detector'])
        self.assertIn('delivery-class job silent', signals[0]['headline'])
        self.assertIn('no delivery', signals[0]['headline'])

    def test_any_delivery_rearms_silence_detector(self):
        runs = [('completed', None, 'suppressed', 40),
                ('completed', None, 'delivered', 20),
                ('completed', None, 'suppressed', 1)]
        self.assertEqual([], self.detect(runs=runs))

    def test_delivery_pattern_excludes_local_monitors_by_default(self):
        runs = [('completed', None, 'suppressed', h) for h in (0.2, 40, 80)]
        self.assertEqual([], self.detect(name='kanban aging escalation',
                                         runs=runs))

    def test_repeated_same_signature_failures_trip(self):
        runs = [('failed', CONFIG_ERR, 'failed', 3),
                ('failed', CONFIG_ERR, 'failed', 2),
                ('failed', CONFIG_ERR, 'failed', 1),
                ('failed', CONFIG_ERR, 'failed', 0.2),
                ('completed', None, 'suppressed', 60)]
        signals = self.detect(runs=runs)
        self.assertEqual(['failure-loop'],
                         [s['detector'] for s in signals])
        self.assertIn('numeric allowlisted contact',
                      signals[0]['evidence'])

    def test_success_clears_old_execution_failure_episode(self):
        runs = [('failed', CONFIG_ERR, 'failed', h) for h in (50, 45, 40, 35)]
        runs += [('completed', None, 'suppressed', 1)]
        self.assertEqual([], self.detect(runs=runs))

    def test_new_failures_need_their_own_threshold_after_recovery(self):
        runs = [('failed', CONFIG_ERR, 'failed', h) for h in (50, 45, 40, 35)]
        runs += [('completed', None, 'suppressed', 30)]
        runs += [('failed', CONFIG_ERR, 'failed', h) for h in (3, 2, 1)]
        self.assertNotIn('failure-loop', [s['detector'] for s in self.detect(runs=runs)])
        runs += [('failed', CONFIG_ERR, 'failed', .2)]
        signal = next(s for s in self.detect(runs=runs) if s['detector'] == 'failure-loop')
        self.assertIn('4 failures', signal['headline'])
        self.assertEqual(iso(self.now - 3 * HOUR), signal['episode_started_at'])

    def test_suppression_does_not_prove_a_denied_delivery_recovered(self):
        runs = [('completed', CONFIG_ERR, 'failed', h) for h in (4, 3, 2, 1)]
        runs += [('completed', None, 'suppressed', .2)]
        self.assertIn('failure-loop', [s['detector'] for s in self.detect(runs=runs)])
        runs += [('completed', None, 'delivered', .1)]
        self.assertEqual([], self.detect(runs=runs))

    def test_failures_below_repeat_minimum_stay_quiet(self):
        runs = [('failed', CONFIG_ERR, 'failed', 50),
                ('failed', CONFIG_ERR, 'failed', 40),
                ('completed', None, 'suppressed', 30)]
        self.assertEqual([], self.detect(runs=runs))

    def test_different_signatures_do_not_pool_into_a_loop(self):
        # Four diverse signatures never pool into one failure loop; the
        # consecutive-failed *outcomes* may still legitimately read as a
        # delivery-denial streak, which is its own detector.
        runs = [('failed', f'{CONFIG_ERR} alpha', 'failed', 50),
                ('failed', f'{CONFIG_ERR} beta', 'failed', 40),
                ('failed', f'{CONFIG_ERR} gamma', 'failed', 30),
                ('failed', f'{CONFIG_ERR} delta', 'failed', 20)]
        signals = self.detect(runs=runs)
        self.assertNotIn('failure-loop', [s['detector'] for s in signals])

    def test_failures_outside_the_window_do_not_count(self):
        runs = [('failed', CONFIG_ERR, 'failed', 100),
                ('failed', CONFIG_ERR, 'failed', 90),
                ('failed', CONFIG_ERR, 'failed', 80),
                ('failed', CONFIG_ERR, 'failed', 0.2)]
        self.assertEqual([], self.detect(
            runs=runs, window=mon.DEFAULT_WINDOW_HOURS))

    def test_delivery_denial_streak_trips(self):
        runs = [('completed', 'ws://channel refused', 'not_configured', 30),
                ('completed', 'ws://channel refused', 'not_configured', 1)]
        signals = self.detect(runs=runs)
        self.assertEqual(['delivery-denial'],
                         [s['detector'] for s in signals])

    def test_short_denial_streak_stays_quiet(self):
        runs = [('completed', 'refused', 'not_configured', 3),
                ('completed', 'refused', 'not_configured', 1)]
        self.assertEqual([], self.detect(runs=runs))

    def test_running_rows_do_not_break_the_streak(self):
        runs = [('completed', 'refused', 'failed', 26),
                ('running', None, None, 0.01),
                ('completed', 'refused', 'failed', 0.3)]
        signals = self.detect(runs=runs)
        self.assertIn('delivery-denial', [s['detector'] for s in signals])

    def test_empty_history_is_healthy(self):
        self.assertEqual([], self.detect(runs=[]))

    def test_sender_health_requires_fresh_complete_current_run_evidence(self):
        job = {'script': 'kanban-owner-alerts.py', 'no_agent': True}
        history = rows(self.now, [('completed', None, 'suppressed', .1)])
        path = self.root / 'kanban/owner-alerts/health.json'
        path.parent.mkdir(parents=True)
        good = dict(version=1, started_at=self.now - 300, completed_at=self.now - 200,
                    snapshot_complete=True, errors=0, due_unsent=0)
        self.assertFalse(mon.owner_alerts_healthy(self.root, job, history, self.now))
        for change in ({}, {'completed_at': None}, {'snapshot_complete': False},
                       {'errors': 1}, {'due_unsent': 1}, {'completed_at': self.now + 1},
                       {'started_at': self.now - 400}, {'completed_at': self.now - 4000}):
            path.write_text(json.dumps({**good, **change}))
            self.assertEqual(not change,
                             mon.owner_alerts_healthy(self.root, job, history, self.now), change)
        path.write_text('not json')
        self.assertFalse(mon.owner_alerts_healthy(self.root, job, history, self.now))
        path.write_text(json.dumps(good))
        self.assertFalse(mon.owner_alerts_healthy(self.root, {'name': 'alerts'}, history, self.now))

    def test_healthy_self_sender_only_suppresses_silence_not_failures(self):
        runs = [('completed', None, 'suppressed', h) for h in (42, 40, .1)]
        self.assertEqual([], mon.detection_for_job('job_alerts', {'name': 'alerts'},
                         rows(self.now, runs), 72, self.now, sender_healthy=True))
        runs = [('failed', CONFIG_ERR, 'failed', h) for h in (30, 29, 28, .1)]
        signals = mon.detection_for_job('job_alerts', {'name': 'alerts'},
                         rows(self.now, runs), 72, self.now, sender_healthy=True)
        self.assertIn('failure-loop', [s['detector'] for s in signals])
        self.assertIn('delivery-denial', [s['detector'] for s in signals])

    def test_silence_can_recur_after_old_delivery_inside_window(self):
        signals = self.detect(runs=[('completed', None, 'delivered', 60),
                                   ('completed', None, 'suppressed', 42),
                                   ('completed', None, 'suppressed', .1)])
        self.assertEqual(['persistent-silence'], [s['detector'] for s in signals])

    def test_sender_reconciliation_restarts_silence_threshold_and_rearms_later(self):
        history = rows(self.now, [('completed', None, 'delivered', 60),
                                 ('completed', None, 'suppressed', 42),
                                 ('completed', None, 'suppressed', 1),
                                 ('completed', None, 'suppressed', .1)])
        self.assertEqual([], mon.detection_for_job('j', {'name': 'alerts'}, history, 72,
            self.now, sender_recovered_at=iso(self.now - 10 * HOUR)))
        signals = mon.detection_for_job('j', {'name': 'alerts'}, history, 72,
            self.now, sender_recovered_at=iso(self.now - 50 * HOUR))
        self.assertEqual(iso(self.now - 50 * HOUR), signals[0]['recovered_at'])

    # --- commission body ------------------------------------------------

    def test_commission_body_names_job_route_and_stopping_condition(self):
        signal = {'detector': 'persistent-silence',
                  'headline': 'delivery-class job silent 40h with no delivery',
                  'evidence': 'latest at 2026-10-22T20:14:43'}
        body = mon.commission_body(signal, 'kanban owner blocker alerts',
                                   'job_alerts')
        self.assertIn("Goal: Root-cause the repeated cron persistent-silence",
                      body)
        self.assertIn('kanban owner blocker alerts', body)
        self.assertIn('executions.db', body)
        self.assertIn('Stopping condition: that disposition comment exists.',
                      body)
        self.assertIn('Never page the owner directly', body)
        self.assertIn('coordinator authors the owner gate', body)

    def test_commission_key_stable_per_job_and_detector(self):
        self.assertEqual('cron-loop-monitor:failure-loop:job1',
                         mon.commission_key('job1', 'failure-loop'))
        self.assertEqual('cron-loop-monitor:failure-loop:job1:r2',
                         mon.commission_key('job1', 'failure-loop', 2))

    # --- commission dedupe and rotation ---------------------------------

    def make_board(self, cards=()):
        board = self.root / 'kanban' / 'boards' / 'nixhomeserver'
        board.mkdir(parents=True)
        db = sqlite3.connect(board / 'kanban.db')
        db.execute('CREATE TABLE tasks (id TEXT PRIMARY KEY, title TEXT,'
                   ' status TEXT, created_at INTEGER, idempotency_key TEXT,'
                   ' consecutive_failures INTEGER NOT NULL DEFAULT 0)')
        for tid, key, status, failures in cards:
            db.execute('INSERT INTO tasks (id, title, status, created_at,'
                       ' idempotency_key, consecutive_failures)'
                       ' VALUES (?,?,?,?,?,?)',
                       (tid, f'Deep-dive {key}', status, int(self.now),
                        key, failures))
        db.commit()
        db.close()

    def cli_calls(self):
        calls = []

        class FakeResult:
            returncode = 0
            stdout = 'Created task t_abc123'
            stderr = ''

        def fake_cli(args, env):
            calls.append(args)
            return FakeResult()

        self.addCleanup(setattr, mon, 'run_cli', mon.run_cli)
        mon.run_cli = fake_cli
        return calls

    def commission(self):
        signal = {'detector': 'persistent-silence', 'headline': 'silent 41h',
                  'evidence': 'latest at now',
                  'episode_started_at': iso(self.now - 41 * HOUR),
                  'recovered_at': iso(self.now - 42 * HOUR)}
        return mon.create_commission(
            self.root, 'nixhomeserver', signal,
            'kanban owner blocker alerts', 'job_alerts', {}, self.report)

    def test_no_commission_without_a_board(self):
        calls = self.cli_calls()
        self.assertEqual('', self.commission())
        self.assertEqual([], calls)

    def test_creating_commission_uses_native_idempotency_key(self):
        self.make_board()
        calls = self.cli_calls()
        self.assertEqual('t_abc123', self.commission())
        create_args = [a for a in calls if 'create' in a][0]
        self.assertIn('--idempotency-key', create_args)
        self.assertIn('cron-loop-monitor:persistent-silence:job_alerts',
                      create_args)
        self.assertIn('--assignee', create_args)
        self.assertIn('project-auditor', create_args)

    def test_usable_existing_commission_suppresses_refire(self):
        self.make_board([('t_live',
                          'cron-loop-monitor:persistent-silence:job_alerts',
                          'todo', 0)])
        calls = self.cli_calls()
        self.assertEqual('already commissioned', self.commission())
        self.assertEqual([], calls)

    def test_done_commission_keeps_owning_unchanged_episode(self):
        self.make_board([('t_done',
                          'cron-loop-monitor:persistent-silence:job_alerts',
                          'done', 0)])
        calls = self.cli_calls()
        self.assertEqual('already commissioned', self.commission())
        self.assertEqual([], calls)

    def test_recovered_then_recurrent_episode_gets_one_new_commission(self):
        self.make_board([('t_done',
                          'cron-loop-monitor:persistent-silence:job_alerts',
                          'done', 0)])
        db = sqlite3.connect(self.root / 'kanban/boards/nixhomeserver/kanban.db')
        db.execute('UPDATE tasks SET created_at=?', (int(self.now - 50 * HOUR),))
        db.commit()
        db.close()
        calls = self.cli_calls()
        self.assertEqual('t_abc123', self.commission())
        self.assertIn('cron-loop-monitor:persistent-silence:job_alerts:r1', calls[0])

    def test_tripped_commission_does_not_duplicate_unchanged_diagnosis(self):
        self.make_board([('t_dead',
                          'cron-loop-monitor:persistent-silence:job_alerts',
                          'blocked', 3)])
        calls = self.cli_calls()
        self.assertEqual('already commissioned', self.commission())
        self.assertEqual([], calls)

    def test_window_rollover_without_observed_recovery_never_rearms(self):
        self.make_board([('t_done',
                          'cron-loop-monitor:persistent-silence:job_alerts',
                          'done', 0)])
        db = sqlite3.connect(self.root / 'kanban/boards/nixhomeserver/kanban.db')
        db.execute('UPDATE tasks SET created_at=?', (int(self.now - 100 * HOUR),))
        db.commit()
        db.close()
        calls = self.cli_calls()
        signal = {'detector': 'persistent-silence', 'headline': 'silent 41h',
                  'evidence': 'latest at now',
                  'episode_started_at': iso(self.now - 41 * HOUR), 'recovered_at': None}
        self.assertEqual('already commissioned', mon.create_commission(
            self.root, 'nixhomeserver', signal, 'alerts', 'job_alerts', {}, self.report))
        self.assertEqual([], calls)

    def test_duplicate_key_from_a_racing_dispatcher_is_success(self):
        self.make_board()
        calls = []

        class Dup:
            returncode = 1
            stdout = ''
            stderr = 'Error: idempotency key already exists'

        def fake_cli(args, env):
            calls.append(args)
            return Dup()

        self.addCleanup(setattr, mon, 'run_cli', mon.run_cli)
        mon.run_cli = fake_cli
        self.assertEqual('already commissioned', self.commission())
        self.assertEqual(1, len(calls))

    # --- full main() against a synthetic HERMES_ROOT ---------------------

    def main_output(self, argv=('--dry-run',)):
        out = subprocess.run(
            [sys.executable, '-B', str(source), *argv],
            capture_output=True, text=True, timeout=120,
            env={**os.environ, 'HERMES_ROOT': str(self.root)})
        return out

    def test_main_dry_run_reports_signal_without_writing(self):
        self.make_board()
        make_cron(self.root, 'job_alerts', self.now, [
            ('completed', None, 'suppressed', 41),
            ('completed', None, 'suppressed', 40),
        ])
        out = self.main_output()
        self.assertEqual(0, out.returncode, out.stderr)
        self.assertIn('persistent-silence', out.stdout)
        self.assertIn('kanban owner blocker alerts', out.stdout)

    def test_main_all_clear(self):
        make_cron(self.root, 'job_alerts', self.now, [
            ('completed', None, 'suppressed', 1),
        ])
        out = self.main_output()
        self.assertEqual(0, out.returncode, out.stderr)
        self.assertIn('nothing to escalate', out.stdout)

    def test_main_qualifies_fresh_self_sender_health_then_keeps_failure_visible(self):
        make_cron(self.root, 'job_alerts', self.now, [
            ('completed', None, 'suppressed', 42),
            ('completed', None, 'suppressed', .1)])
        jobs = self.root / 'cron/jobs.json'
        data = json.loads(jobs.read_text())
        data['jobs'][0].update(script='kanban-owner-alerts.py', no_agent=True)
        jobs.write_text(json.dumps(data))
        path = self.root / 'kanban/owner-alerts/health.json'
        path.parent.mkdir(parents=True)
        health = dict(version=1, started_at=self.now - 350,
                      completed_at=self.now - 340, snapshot_complete=True,
                      errors=0, due_unsent=0, last_success_at=self.now - 340)
        path.write_text(json.dumps(health))
        before = path.read_bytes()
        out = self.main_output()
        self.assertEqual(0, out.returncode, out.stderr)
        self.assertIn('nothing to escalate', out.stdout)
        self.assertEqual(before, path.read_bytes())
        health.update(completed_at=None, snapshot_complete=False,
                      last_success_at=None)
        path.write_text(json.dumps(health))
        self.assertIn('persistent-silence', self.main_output().stdout)

    def test_main_missing_executions_db_degrades_to_clear(self):
        out = self.main_output()
        self.assertEqual(0, out.returncode, out.stderr)
        self.assertIn('nothing to escalate', out.stdout)


def make_cron(root, job_id, now, runs):
    cron = root / 'cron'
    cron.mkdir(parents=True, exist_ok=True)
    (cron / 'jobs.json').write_text(json.dumps(
        {'jobs': [{'id': job_id, 'name': 'kanban owner blocker alerts'}]}))
    db = sqlite3.connect(cron / 'executions.db')
    db.executescript(EXEC_SCHEMA)
    for n, (status, error, outcome, hours_ago) in enumerate(runs):
        db.execute(
            'INSERT INTO executions (id, job_id, source, process_id, pid,'
            ' status, claimed_at, error, delivery_outcome)'
            ' VALUES (?,?,?,?,?,?,?,?,?)',
            (f'e{n}', job_id, 'test', 'p', n + 400, status,
             iso(now - int(hours_ago * HOUR)), error, outcome))
    db.commit()
    db.close()


if __name__ == '__main__':
    unittest.main(argv=[sys.argv[0]], verbosity=2)
PY
