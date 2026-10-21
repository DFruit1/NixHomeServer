#!/usr/bin/env bash
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
python3 -B - "$repo" <<'PY'
import hashlib
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

source = Path(sys.argv[1]) / 'scripts/hermes/kanban-aging-escalation.py'
spec = importlib.util.spec_from_file_location('aging', source)
aging = importlib.util.module_from_spec(spec)
spec.loader.exec_module(aging)

DAY = 86400
SCHEMA = """
CREATE TABLE tasks (
    id TEXT PRIMARY KEY, title TEXT NOT NULL, body TEXT, assignee TEXT,
    status TEXT NOT NULL, priority INTEGER DEFAULT 0, created_by TEXT,
    created_at INTEGER NOT NULL, started_at INTEGER, completed_at INTEGER,
    workspace_kind TEXT NOT NULL DEFAULT 'scratch', workspace_path TEXT,
    branch_name TEXT, project_id TEXT, claim_lock TEXT, claim_expires INTEGER,
    tenant TEXT, result TEXT, idempotency_key TEXT,
    consecutive_failures INTEGER NOT NULL DEFAULT 0, worker_pid INTEGER,
    worker_started_at INTEGER, last_failure_error TEXT,
    max_runtime_seconds INTEGER, last_heartbeat_at INTEGER,
    block_kind TEXT
);
CREATE TABLE task_events (
    id INTEGER PRIMARY KEY AUTOINCREMENT, task_id TEXT NOT NULL, run_id INTEGER,
    kind TEXT NOT NULL, payload TEXT, created_at INTEGER NOT NULL
);
CREATE TABLE task_comments (
    id INTEGER PRIMARY KEY AUTOINCREMENT, task_id TEXT NOT NULL, author TEXT,
    body TEXT, created_at INTEGER NOT NULL
);
CREATE TABLE task_links (
    parent_id TEXT NOT NULL, child_id TEXT NOT NULL,
    PRIMARY KEY (parent_id, child_id)
);
CREATE TABLE task_runs (
    id INTEGER PRIMARY KEY AUTOINCREMENT, task_id TEXT NOT NULL,
    profile TEXT, status TEXT, outcome TEXT, metadata TEXT,
    started_at INTEGER, ended_at INTEGER
);
"""


def insert_comment(db_path, tid, author, age_days, body='x'):
    now = int(time.time())
    db = sqlite3.connect(db_path)
    db.execute(
        "INSERT INTO task_comments (task_id, author, body, created_at)"
        " VALUES (?, ?, ?, ?)", (tid, author, body, now - int(age_days * DAY)))
    db.commit()
    db.close()


def make_board(root, cards):
    """cards: list of (tid, title, status, age_days, extra dict)."""
    board = root / 'kanban' / 'boards' / 'testboard'
    board.mkdir(parents=True)
    (board / 'board.json').write_text('{}')
    db = sqlite3.connect(board / 'kanban.db')
    db.executescript(SCHEMA)
    now = int(time.time())
    for tid, title, status, age_days, extra in cards:
        created = now - int(age_days * DAY)
        db.execute(
            "INSERT INTO tasks (id, title, status, created_at, priority, body, block_kind,"
            " idempotency_key, consecutive_failures, assignee)"
            " VALUES (?,?,?,?,?,?,?,?,?,?)",
            (tid, title, status, created, extra.get('priority', 0),
             extra.get('body'), extra.get('block_kind'),
             extra.get('idempotency_key'), extra.get('consecutive_failures', 0),
             extra.get('assignee')))
        db.execute(
            "INSERT INTO task_events (task_id, kind, created_at)"
            " VALUES (?, 'created', ?)", (tid, created))
        for kind, age_days_offset in extra.get('events', []):
            db.execute(
                "INSERT INTO task_events (task_id, kind, created_at)"
                " VALUES (?, ?, ?)", (tid, kind, now - int(age_days_offset * DAY)))
        for verdict, age_days_offset in extra.get('runs', []):
            db.execute(
                "INSERT INTO task_runs (task_id, profile, status, outcome, metadata,"
                " ended_at) VALUES (?, 'feature-reviewer', 'done', 'completed', ?, ?)",
                (tid, json.dumps({'verdict': verdict}),
                 now - int(age_days_offset * DAY)))
    db.commit()
    db.close()
    return now


class AgingEscalationTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='aging-escalation-test-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.report = []

    def classify_card(self, cards):
        now = make_board(self.root, cards)
        db = aging.connect_ro(self.root / 'kanban' / 'boards' / 'testboard' / 'kanban.db')
        row = db.execute("SELECT * FROM tasks WHERE id = ?",
                         (cards[0][0],)).fetchone()
        result = aging.classify(db, row, now, 48.0, 72.0)
        db.close()
        return result

    def test_fresh_card_is_not_escalated(self):
        idle_days, tier, exempt, gated = self.classify_card(
            [('t_fresh', 'Work on something', 'todo', 1.0, {})])
        self.assertIsNone(tier)

    def test_two_day_idle_card_bumps_priority(self):
        idle_days, tier, exempt, gated = self.classify_card(
            [('t_aged', 'Work on something', 'todo', 2.5, {})])
        self.assertEqual(tier, 'bump')
        row = ('t_aged', 'Work on something', 'todo', 2.5, {})
        actions = aging.plan_card(row, idle_days, tier, exempt, gated)
        self.assertEqual(actions, ['priority -> >=50'])

    def test_three_day_idle_card_escalates_fully(self):
        idle_days, tier, exempt, gated = self.classify_card(
            [('t_old', 'Work on something', 'todo', 4.0, {})])
        self.assertEqual(tier, 'escalate')
        row = ('t_old', 'Work on something', 'todo', 4.0, {})
        actions = aging.plan_card(row, idle_days, tier, exempt, gated)
        self.assertEqual(actions, ['priority -> >=100',
                                   'commission auditor deep-dive',
                                   'post coordinator clearing directive'])

    def test_recent_comment_resets_idle_clock(self):
        # An old card with a substantive comment yesterday is not stale.
        idle_days, tier, exempt, gated = self.classify_card(
            [('t_active', 'Work on something', 'todo', 6.0,
              {'events': [('commented', 1.0)]})])
        self.assertIsNone(tier)

    def test_heartbeat_alone_does_not_reset_idle(self):
        idle_days, tier, exempt, gated = self.classify_card(
            [('t_quiet', 'Work on something', 'ready', 4.0,
              {'events': [('heartbeat', 0.01)]})])
        self.assertEqual(tier, 'escalate')

    def test_age_backstop_escalates_actively_held_card(self):
        # A 10-day-old card kept "fresh" by a holding comment this morning
        # still escalates: the decision stall outlives the comments.
        idle_days, tier, exempt, gated = self.classify_card(
            [('t_held', 'Decide: deploy the range', 'todo', 10.0,
              {'events': [('commented', 0.2)]})])
        self.assertEqual(tier, 'escalate')

    def test_backstop_respects_exemptions(self):
        idle_days, tier, exempt, gated = self.classify_card(
            [('t_track2', '[FEATURE TRACKER] ideas', 'triage', 12.0,
              {'events': [('commented', 0.5)]})])
        self.assertTrue(exempt)
        self.assertEqual([], aging.plan_card(
            ('t_track2', 'x', 'triage', 12.0, {}), idle_days, tier, exempt,
            gated))

    def test_recent_escalation_comment_damps_refire(self):
        # A card the job escalated yesterday must not re-escalate on the next
        # run: the age backstop would otherwise repost directives forever.
        now = make_board(self.root, [
            ('t_damped', 'Decide: deploy the range', 'todo', 14.0, {}),
        ])
        insert_comment(self.root / 'kanban' / 'boards' / 'testboard' /
                       'kanban.db', 't_damped', aging.CREATED_BY, 1.0)
        db = aging.connect_ro(
            self.root / 'kanban' / 'boards' / 'testboard' / 'kanban.db')
        row = db.execute("SELECT * FROM tasks WHERE id = 't_damped'").fetchone()
        idle_days, tier, exempt, gated = aging.classify(
            db, row, now, 48.0, 72.0)
        db.close()
        self.assertIsNone(tier)

    def test_old_escalation_comment_rearms_escalation(self):
        now = make_board(self.root, [
            ('t_rearm', 'Decide: deploy the range', 'todo', 14.0, {}),
        ])
        insert_comment(self.root / 'kanban' / 'boards' / 'testboard' /
                       'kanban.db', 't_rearm', aging.CREATED_BY, 4.0)
        db = aging.connect_ro(
            self.root / 'kanban' / 'boards' / 'testboard' / 'kanban.db')
        row = db.execute("SELECT * FROM tasks WHERE id = 't_rearm'").fetchone()
        idle_days, tier, exempt, gated = aging.classify(
            db, row, now, 48.0, 72.0)
        db.close()
        self.assertEqual(tier, 'escalate')

    def test_stale_block_flags_review_flipped_to_accept(self):
        # Block reason says the review requested changes; the same review's
        # newest verdict is now accept -> the block condition no longer holds.
        now = make_board(self.root, [
            ('t_0b10c5dd', 'Implement the repair', 'blocked', 1.0,
             {'events': [('blocked', 0.9)]}),
            ('t_5a1b2c3d', 'Review the repair', 'done', 3.0,
             {'assignee': 'feature-reviewer',
              'runs': [('request-changes', 2.5), ('accept', 0.5)]}),
        ])
        insert_comment(self.root / 'kanban' / 'boards' / 'testboard' /
                       'kanban.db', 't_0b10c5dd', 'head-coordinator', 0.9)
        # The block event payload must name the review.
        db = sqlite3.connect(
            self.root / 'kanban' / 'boards' / 'testboard' / 'kanban.db')
        db.execute(
            "INSERT INTO task_events (task_id, kind, payload, created_at)"
            " VALUES ('t_0b10c5dd', 'blocked', ?, ?)",
            (json.dumps({'reason': 'Review t_5a1b2c3d requested changes; the'
                                   ' completion guard refused'}),
             now - int(0.9 * DAY)))
        db.commit()
        db.close()
        report = []
        aging.recheck_blocks(self.root, 'testboard', now, dry_run=True,
                             report=report)
        self.assertTrue(any('stale block' in line and 't_0b10c5dd' in line
                            for line in report), report)

    def test_stale_block_stays_silent_while_verdict_stands(self):
        now = make_board(self.root, [
            ('t_0b10c5ee', 'Implement the repair', 'blocked', 1.0, {}),
            ('t_5a1b2c4e', 'Review the repair', 'done', 3.0,
             {'assignee': 'feature-reviewer',
              'runs': [('request-changes', 0.5)]}),
        ])
        db = sqlite3.connect(
            self.root / 'kanban' / 'boards' / 'testboard' / 'kanban.db')
        db.execute(
            "INSERT INTO task_events (task_id, kind, payload, created_at)"
            " VALUES ('t_0b10c5ee', 'blocked', ?, ?)",
            (json.dumps({'reason': 'Review t_5a1b2c4e requested changes; the'
                                   ' completion guard refused'}),
             now - int(0.9 * DAY)))
        db.commit()
        db.close()
        report = []
        aging.recheck_blocks(self.root, 'testboard', now, dry_run=True,
                             report=report)
        self.assertEqual([], report)

    def test_dependency_block_with_no_open_parents_is_stale(self):
        # The shape the owner-blocker-authoring guard refuses to create: a
        # dependency block whose every parent is done. The block is dead.
        now = make_board(self.root, [
            ('t_0b10c5ff', 'Follow-on work', 'blocked', 2.0,
             {'block_kind': 'dependency'}),
            ('t_5a1b2c77', 'Finished prerequisite', 'done', 4.0,
             {'assignee': 'standard-implementer'}),
        ])
        db = sqlite3.connect(
            self.root / 'kanban' / 'boards' / 'testboard' / 'kanban.db')
        db.execute("INSERT INTO task_links (parent_id, child_id)"
                   " VALUES ('t_5a1b2c77', 't_0b10c5ff')")
        db.commit()
        db.close()
        report = []
        aging.recheck_blocks(self.root, 'testboard', now, dry_run=True,
                             report=report)
        self.assertTrue(any('no open prerequisite' in line
                            and 't_0b10c5ff' in line for line in report),
                        report)

    def test_live_dependency_block_is_not_stale(self):
        now = make_board(self.root, [
            ('t_0b10c6aa', 'Follow-on work', 'blocked', 2.0,
             {'block_kind': 'dependency'}),
            ('t_5a1b2c88', 'Open prerequisite', 'blocked', 4.0,
             {'assignee': 'standard-implementer'}),
        ])
        db = sqlite3.connect(
            self.root / 'kanban' / 'boards' / 'testboard' / 'kanban.db')
        db.execute("INSERT INTO task_links (parent_id, child_id)"
                   " VALUES ('t_5a1b2c88', 't_0b10c6aa')")
        db.commit()
        db.close()
        report = []
        aging.recheck_blocks(self.root, 'testboard', now, dry_run=True,
                             report=report)
        self.assertEqual([], report)

    def test_commission_rotates_past_tripped_key(self):
        # A breaker-tripped commission must not own the key forever: the next
        # escalation rotates to a fresh sequence so a replacement can exist.
        base = aging.commission_key('testboard', ['t_old'])
        make_board(self.root, [
            ('t_old', 'Work on something', 'todo', 4.0, {}),
            ('t_comm', 'Deep-dive: route to clear aged t_old', 'blocked',
             3.0, {'idempotency_key': base, 'consecutive_failures': 2}),
        ])
        db = aging.connect_ro(
            self.root / 'kanban' / 'boards' / 'testboard' / 'kanban.db')
        calls = []

        class FakeResult:
            returncode = 0
            stdout = 'Created task t_abc123'
            stderr = ''

        def fake_cli(args, env):
            calls.append(args)
            return FakeResult()

        self.addCleanup(setattr, aging, 'run_cli', aging.run_cli)
        aging.run_cli = fake_cli
        report = []
        try:
            result = aging.create_commission(
                'testboard', ['t_old'], {'t_old': {'idle_days': 4.0}}, db,
                {}, report)
        finally:
            pass
        self.assertEqual('t_abc123', result)
        create_args = [a for a in calls if 'create' in a][0]
        self.assertIn(base + ':r1', create_args)
        self.assertTrue(any('--idempotency-key' in a for a in calls))

    def test_running_card_is_exempt(self):
        idle_days, tier, exempt, gated = self.classify_card(
            [('t_run', 'Work on something', 'running', 5.0, {})])
        self.assertTrue(exempt)
        self.assertEqual([], aging.plan_card(
            ('t_run', 'x', 'running', 5.0, {}), idle_days, tier, exempt, gated))

    def test_feature_tracker_is_exempt(self):
        idle_days, tier, exempt, gated = self.classify_card(
            [('t_track', '[FEATURE TRACKER — NOT AN EXECUTION TASK] ideas',
              'triage', 9.0, {})])
        self.assertTrue(exempt)
        self.assertEqual([], aging.plan_card(
            ('t_track', 'x', 'triage', 9.0, {}), idle_days, tier, exempt, gated))

    def test_owner_gate_gets_directive_only(self):
        idle_days, tier, exempt, gated = self.classify_card(
            [('t_gate', 'ASK: pick a route', 'blocked', 5.0,
              {'block_kind': 'needs_input'})])
        self.assertEqual(tier, 'escalate')
        self.assertTrue(gated)
        row = ('t_gate', 'ASK: pick a route', 'blocked', 5.0, {})
        actions = aging.plan_card(row, idle_days, tier, exempt, gated)
        self.assertEqual(actions, ['post coordinator clearing directive'])

    def test_high_hard_blocker_line_counts_as_gate(self):
        idle_days, tier, exempt, gated = self.classify_card(
            [('t_hard', 'Ship the widget', 'blocked', 5.0,
              {'body': 'Goal: ship it\nHard Blocker: needs owner key\n'})])
        self.assertTrue(gated)

    def test_escalate_board_mutates_via_cli(self):
        # Integration: real CLI against a scratch HERMES_HOME root, using the
        # real kanban CLI is out of scope for a unit test; here we assert the
        # report/dry-run plumbing on the synthetic board only.
        make_board(self.root, [
            ('t_old', 'Work on something', 'todo', 4.0, {}),
            ('t_track', '[FEATURE TRACKER] ideas', 'triage', 9.0, {}),
        ])
        aging.escalate_board(self.root, 'testboard', int(time.time()),
                             dry_run=True, priority_hours=48.0,
                             escalation_hours=72.0, report=self.report)
        joined = '\n'.join(self.report)
        self.assertIn('t_old', joined)
        self.assertIn('commission auditor deep-dive', joined)
        self.assertNotIn('t_track', joined)

    def test_directive_body_names_card_and_route(self):
        body = aging.directive_body('t_old', 4.0, 't_abc123')
        self.assertIn('aging-escalation', body)
        self.assertIn('Decision owner: head-coordinator', body)
        self.assertIn('t_abc123', body)
        for line in body.splitlines():
            if not line.startswith('<!--'):
                self.assertLessEqual(len(line), 90, line)

    def test_commission_body_is_question_scope_stopping_condition(self):
        body = aging.commission_body(['t_old'], 'testboard',
                                     {'t_old': {'idle_days': 4.0}})
        self.assertIn('Goal: Name the concrete route', body)
        self.assertIn('Stopping condition:', body)
        self.assertIn('Evidence-only', body)

    def test_cluster_commission_names_all_members(self):
        cards = {f't_{i}': {'idle_days': 8.0} for i in range(3)}
        body = aging.commission_body(['t_0', 't_1', 't_2'], 'testboard', cards)
        for tid in ('t_0', 't_1', 't_2'):
            self.assertIn(tid, body)
        self.assertIn('every member card', body)

    # --- Auditor-reviewed clearance escalation -------------------------

    def _fake_cli(self):
        calls = []

        class FakeResult:
            returncode = 0
            stdout = ''
            stderr = ''

        def fake_cli(args, env):
            calls.append(args)
            return FakeResult()

        self.addCleanup(setattr, aging, 'run_cli', aging.run_cli)
        aging.run_cli = fake_cli
        return calls

    def _clearance_board(self, tid='t_stuck', status='todo', extra=None):
        make_board(self.root, [(tid, 'Stuck thing', status, 20.0, extra or {})])
        insert_comment(self.root / 'kanban' / 'boards' / 'testboard' /
                       'kanban.db', tid, 'project-auditor', 6.0)

    def test_clearance_escalation_never_reclassifies_the_card(self):
        # The job cannot know which supplier is missing, and only
        # head-coordinator authors needs_input gates. It posts a directive.
        self._clearance_board()
        calls = self._fake_cli()
        aging.force_owner_escalation(
            self.root, 'testboard', int(time.time()), 5.0, False, self.report)
        self.assertTrue(any('comment' in c for c in calls), calls)
        self.assertFalse(any('block' in c for c in calls), calls)
        joined = '\n'.join(' '.join(c) for c in calls)
        self.assertIn('Decision owner: head-coordinator', joined)
        self.assertIn(aging.OWNER_ESCALATION_MARKER, joined)
        self.assertNotIn('forced to needs_input', joined)
        self.assertTrue(any('clearance escalation' in line
                            for line in self.report), self.report)

    def test_clearance_skips_coordinator_scheduled_hold(self):
        # A scheduled hold is a deliberate time wait, not an unattended card.
        self._clearance_board(status='scheduled')
        calls = self._fake_cli()
        aging.force_owner_escalation(
            self.root, 'testboard', int(time.time()), 5.0, False, self.report)
        self.assertEqual([], calls)
        self.assertEqual([], self.report)

    def test_clearance_skips_existing_owner_gate(self):
        self._clearance_board(extra={'block_kind': 'needs_input'})
        calls = self._fake_cli()
        aging.force_owner_escalation(
            self.root, 'testboard', int(time.time()), 5.0, False, self.report)
        self.assertEqual([], calls)

    def test_clearance_directive_is_damped(self):
        self._clearance_board()
        insert_comment(self.root / 'kanban' / 'boards' / 'testboard' /
                       'kanban.db', 't_stuck', aging.CREATED_BY, 1.0,
                       body=aging.OWNER_ESCALATION_MARKER + '\nprior')
        calls = self._fake_cli()
        aging.force_owner_escalation(
            self.root, 'testboard', int(time.time()), 5.0, False, self.report)
        self.assertEqual([], calls)

    def test_clearance_directive_rearms_after_damping(self):
        self._clearance_board()
        insert_comment(self.root / 'kanban' / 'boards' / 'testboard' /
                       'kanban.db', 't_stuck', aging.CREATED_BY,
                       aging.CLEARANCE_DAMP_DAYS + 1.0,
                       body=aging.OWNER_ESCALATION_MARKER + '\nprior')
        calls = self._fake_cli()
        aging.force_owner_escalation(
            self.root, 'testboard', int(time.time()), 5.0, False, self.report)
        self.assertTrue(any('comment' in c for c in calls), calls)

    # --- Triage aging and the tracker parking lot ----------------------

    def test_triage_aging_splits_trackers_from_real_cards(self):
        now = make_board(self.root, [
            ('t_t1', '[FEATURE TRACKER] ideas', 'triage', 10.0, {}),
            ('t_t2', '[FEATURE TRACKER — NOT AN EXECUTION TASK] more',
             'triage', 9.0, {}),
            ('t_real', 'Compose the validated thing', 'triage', 8.0, {}),
            ('t_new', 'Fresh triage card', 'triage', 1.0, {}),
        ])
        db = aging.connect_ro(
            self.root / 'kanban' / 'boards' / 'testboard' / 'kanban.db')
        cards, trackers = aging.triage_aging_candidates(db, now, 7.0)
        db.close()
        self.assertEqual(['t_real'], [c[0] for c in cards])
        self.assertEqual({'t_t1', 't_t2'}, {t[0] for t in trackers})

    def test_triage_report_aggregates_tracker_parking_lot(self):
        # 13 per-card tracker lines buried the real signal on 2026-10-21.
        make_board(self.root, [
            ('t_t1', '[FEATURE TRACKER] one', 'triage', 11.0, {}),
            ('t_t2', '[FEATURE TRACKER] two', 'triage', 9.0, {}),
            ('t_real', 'Compose the validated thing', 'triage', 8.0, {}),
        ])
        import contextlib
        import io
        out = io.StringIO()
        old_root = os.environ.get('HERMES_ROOT')
        old_argv = sys.argv
        os.environ['HERMES_ROOT'] = str(self.root)
        sys.argv = [sys.argv[0], '--dry-run', '--board', 'testboard']
        try:
            with contextlib.redirect_stdout(out):
                aging.main()
        finally:
            sys.argv = old_argv
            if old_root is None:
                os.environ.pop('HERMES_ROOT', None)
            else:
                os.environ['HERMES_ROOT'] = old_root
        text = out.getvalue()
        self.assertIn('2 [FEATURE TRACKER] cards exceed triage limit', text)
        self.assertIn('t_real', text)
        self.assertNotIn('t_t1', text)

    def test_dependency_clusters_group_linked_cards(self):
        make_board(self.root, [
            ('t_a', 'Work a', 'todo', 8.0, {}),
            ('t_b', 'Work b', 'todo', 8.0, {}),
            ('t_c', 'Work c', 'todo', 8.0, {}),
        ])
        db = sqlite3.connect(
            self.root / 'kanban' / 'boards' / 'testboard' / 'kanban.db')
        db.execute("INSERT INTO task_links (parent_id, child_id)"
                   " VALUES ('t_a', 't_b')")
        db.commit()
        db.close()
        db = aging.connect_ro(
            self.root / 'kanban' / 'boards' / 'testboard' / 'kanban.db')
        groups = aging.escalated_components(db, ['t_a', 't_b', 't_c'])
        db.close()
        self.assertEqual(2, len(groups))
        self.assertEqual(1, len([g for g in groups if len(g) == 2]))

    # --- Install modes -------------------------------------------------

    def run_cli(self, *argv, env_extra=None):
        env = {key: value for key, value in os.environ.items()
               if key != 'HERMES_ROOT'}
        env['HERMES_ROOT'] = str(self.root)
        env.update(env_extra or {})
        return subprocess.run([sys.executable, '-B', str(source), *argv],
                              capture_output=True, text=True, env=env,
                              timeout=120)

    def fake_hermes(self):
        # PATH shim so the install modes' cron call is observed, not executed.
        bin_dir = self.root / 'fake-bin'
        bin_dir.mkdir()
        record = self.root / 'hermes-calls.log'
        shim = bin_dir / 'hermes'
        shim.write_text('#!/bin/sh\n'
                        'printf "%s\\n" "$*" >> "$HERMES_CALL_LOG"\n')
        shim.chmod(0o755)
        env = {'PATH': f'{bin_dir}{os.pathsep}{os.environ["PATH"]}',
               'HERMES_CALL_LOG': str(record)}
        return record, env

    def installed_copy(self):
        return self.root / 'scripts' / 'kanban-aging-escalation.py'

    def test_install_files_leaves_cron_jobs_byte_identical(self):
        # The update path must never duplicate the live job: same script file,
        # same mode, and cron/jobs.json is not even opened for writing.
        cron = self.root / 'cron' / 'jobs.json'
        cron.parent.mkdir(parents=True)
        original = json.dumps({'jobs': [{'id': 'b7dd0630',
                                         'name': aging.JOB}]}, indent=2)
        cron.write_text(original)
        before = hashlib.sha256(cron.read_bytes()).hexdigest()

        result = self.run_cli('--install-files')

        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual(before, hashlib.sha256(cron.read_bytes()).hexdigest())
        self.assertEqual(original, cron.read_text())
        self.assertEqual(source.read_bytes(), self.installed_copy().read_bytes())
        self.assertEqual(0o700, self.installed_copy().stat().st_mode & 0o777)

    def test_install_files_is_idempotent_and_never_calls_hermes(self):
        cron = self.root / 'cron' / 'jobs.json'
        record, env = self.fake_hermes()

        first = self.run_cli('--install-files', env_extra=env)
        second = self.run_cli('--install-files', env_extra=env)

        self.assertEqual(0, first.returncode, first.stderr)
        self.assertEqual(0, second.returncode, second.stderr)
        self.assertFalse(record.exists(), 'hermes was invoked by --install-files')
        self.assertFalse(cron.exists(), '--install-files created cron state')
        self.assertEqual(0o700, self.installed_copy().stat().st_mode & 0o777)
        self.assertEqual(source.read_bytes(), self.installed_copy().read_bytes())

    def test_install_keeps_job_creation_for_a_new_install(self):
        record, env = self.fake_hermes()

        result = self.run_cli('--install', env_extra=env)

        self.assertEqual(0, result.returncode, result.stderr)
        self.assertTrue(record.exists(), result.stdout)
        calls = record.read_text()
        self.assertIn('cron create', calls)
        self.assertIn('--name ' + aging.JOB, calls)
        self.assertIn('--script kanban-aging-escalation.py', calls)
        self.assertIn('--no-agent', calls)
        self.assertIn('--paused', calls)
        self.assertEqual(0o700, self.installed_copy().stat().st_mode & 0o777)


if __name__ == '__main__':
    unittest.main(argv=[sys.argv[0]], verbosity=2)
PY
