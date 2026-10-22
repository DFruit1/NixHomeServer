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

source = Path(sys.argv[1]) / 'scripts/hermes/review-verdict-guard.py'
spec = importlib.util.spec_from_file_location('verdict_guard', source)
guard_mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard_mod)

DAY = 86400
NOW = 1_700_000_000
SCHEMA = """
CREATE TABLE tasks (
    id TEXT PRIMARY KEY, title TEXT, body TEXT, assignee TEXT, status TEXT,
    priority INTEGER DEFAULT 0, created_at INTEGER, block_kind TEXT,
    idempotency_key TEXT, consecutive_failures INTEGER DEFAULT 0, tenant TEXT
);
CREATE TABLE task_events (id INTEGER PRIMARY KEY AUTOINCREMENT, task_id TEXT,
    kind TEXT, payload TEXT, created_at INTEGER);
CREATE TABLE task_links (parent_id TEXT, child_id TEXT);
CREATE TABLE task_runs (id INTEGER PRIMARY KEY AUTOINCREMENT, task_id TEXT,
    profile TEXT, status TEXT, outcome TEXT, metadata TEXT,
    started_at INTEGER, ended_at INTEGER);
"""


def accept_run(rid, ended):
    return json.dumps({'verdict': 'accept', 'revision': rid, 'checks': []}), ended


def changes_run(rid, ended):
    return (json.dumps({'verdict': 'request-changes', 'revision': rid,
                        'requested_changes': ['fix x'],
                        'checks': [{'command': 'prior check', 'exit_code': 1}]}),
            ended)


class VerdictGuardTest(unittest.TestCase):
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

    def add_run(self, tid, verdict, ended, rid="r0"):
        row = accept_run(rid, ended) if verdict == 'accept' else changes_run(rid, ended)
        self.db.execute(
            "INSERT INTO task_runs (task_id, profile, status, outcome, metadata,"
            " ended_at) VALUES (?, 'feature-reviewer', 'done', 'completed', ?, ?)",
            (tid, row[0], row[1]))
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
        self.assertEqual({}, guard_mod.guard(self.payload('t_rev_old', 't_child'), self.root))

    def test_newer_request_changes_does_not_shadow_an_acceptance(self):
        # The window is "any completed accept after the anchor", not "the last
        # completed verdict in the window".
        self.card('t_rev_old', assignee='feature-reviewer', created=NOW - 4 * DAY)
        self.add_run('t_rev_old', 'request-changes', NOW - 3 * DAY)
        self.card('t_rev_accept', assignee='feature-reviewer', created=NOW - 3 * DAY)
        self.add_run('t_rev_accept', 'accept', NOW - 2 * DAY)
        # Card status is mutable after a review; do not require the accepting
        # card to remain done when considering its completed run.
        self.db.execute("UPDATE tasks SET status='blocked' WHERE id='t_rev_accept'")
        self.db.commit()
        self.card('t_rev_later', assignee='feature-reviewer', created=NOW - 2 * DAY)
        self.add_run('t_rev_later', 'request-changes', NOW - DAY)
        self.card('t_child', assignee='standard-implementer', status='running')
        self.link('t_rev_old', 't_child')
        self.assertEqual({}, guard_mod.guard(self.payload('t_rev_old', 't_child'), self.root))

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
