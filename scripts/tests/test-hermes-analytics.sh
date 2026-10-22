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

REPO = sys.argv[1]
del sys.argv[1:]

DAY = 86400
NOW = int(time.time())

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


def analytics(data_root):
    source = Path(REPO) / 'scripts/hermes/kanban-analytics.py'
    os.environ['HERMES_ROOT'] = str(data_root)
    spec = importlib.util.spec_from_file_location('analytics', source)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class AnalyticsTest(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp(prefix='analytics-test-'))
        self.addCleanup(self._rm, self.root)
        self.board = self.root / 'kanban' / 'boards' / 'fixture'
        self.board.mkdir(parents=True)
        self.module = None  # set per test with HERMES_ROOT

    def filled_module(self):
        db = sqlite3.connect(self.board / 'kanban.db')
        db.executescript(SCHEMA)
        created = NOW - 3 * DAY
        # t_a: clean flow with a named dependency wait; t_x: a failed run
        for task, status, completed, block_kind in (
                ('t_a', 'done', NOW - DAY - 3600, None),
                ('t_b', 'todo', None, None),
                ('t_c', 'blocked', None, 'dependency'),
                ('t_parent', 'done', NOW - DAY, None)):
            db.execute('INSERT INTO tasks (id,title,status,created_at,completed_at,block_kind) '
                       'VALUES (?,?,?,?,?,?)', (task, task, status, created, completed,
                                                block_kind))
        events = [
            ('t_a', 'created', None, created),
            ('t_a', 'claimed', None, created + 600),
            ('t_a', 'dependency_wait', json.dumps({'parent': 't_parent'}), created + 1200),
            ('t_a', 'unblocked', None, created + 2 * DAY),
            ('t_a', 'completed', None, NOW - DAY - 3600),
            ('t_b', 'created', None, NOW - 2 * DAY),
            ('t_b', 'claimed', None, NOW - 2 * DAY + 1800),
            ('t_c', 'created', None, NOW - 5 * DAY),
            ('t_c', 'blocked', None, NOW - 4 * DAY),
            ('t_c', 'unblocked', None, NOW - 3 * DAY),
            ('t_c', 'blocked', None, NOW - 2 * DAY),
        ]
        db.executemany('INSERT INTO task_events (task_id,kind,payload,created_at) '
                       'VALUES (?,?,?,?)', events)
        db.execute('INSERT INTO task_runs (task_id,profile,status,outcome,'
                   'metadata,started_at) VALUES (?,?,?,?,?,?)',
                   ('t_a', 'fixture', 'done', 'completed',
                    json.dumps({'verdict': 'accept', 'worker_session_id': 's_ok'}),
                    NOW - DAY - 7200))
        db.execute('INSERT INTO task_runs (task_id,profile,status,outcome,'
                   "metadata,started_at) VALUES ('t_x','fixture','failed','timed_out',"
                   "'{}',?)", (NOW - 2 * DAY + 3600,))
        db.execute('INSERT INTO task_comments (task_id,author,body,created_at) '
                   "VALUES ('t_b','aging-escalation','Aging escalation: idle',?)",
                   (NOW - 2 * DAY - 7200,))
        db.commit()
        db.close()
        os.environ['HERMES_ROOT'] = str(self.root)
        source = Path(REPO) / 'scripts/hermes/kanban-analytics.py'
        spec = importlib.util.spec_from_file_location('analytics', source)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    @staticmethod
    def _rm(path):
        import shutil
        shutil.rmtree(path, ignore_errors=True)

    def run_script(self, *args):
        env = os.environ.copy()
        env['HERMES_ROOT'] = str(self.root)
        return subprocess.run(
            [sys.executable, '-B', str(Path(REPO) / 'scripts/hermes/kanban-analytics.py'),
             *args], env=env, capture_output=True, text=True)

    def collect(self, days):
        module = self.filled_module()
        return module, module.collect(self.root, NOW - days * DAY, NOW,
                                      only_board='fixture')

    def test_report_metrics(self):
        module, data = self.collect(7)
        board = data['boards']['fixture']
        self.assertEqual(board['lifecycle']['completed_cards'], 1)
        # claim-wait is a create-cohort metric: both created cards claim in-window
        self.assertEqual(board['lifecycle']['claim_wait_days']['n'], 2)
        self.assertGreater(board['lifecycle']['claim_wait_days']['p50'], 0)
        self.assertLess(board['lifecycle']['claim_wait_days']['p50'], 1)
        # t_parent has no events, so the event-derived create-cohort is 3 cards
        self.assertEqual(board['lifecycle']['created_in_window'], 3)
        blocked = board['lifecycle']['open_cards_by_status']['blocked']
        self.assertEqual(blocked['block_kinds'], {'dependency': 1})
        self.assertEqual(board['lifecycle']['open_cards_by_status']
                         ['todo']['count'], 1)
        # R2: the wait ends at the next release event; parent attributed once
        self.assertEqual({e['parent']: e['waits']
                          for e in board['dependencies']['chronic_parents']}
                         .get('t_parent'), 1)
        self.assertEqual(board['dependencies']['resolved_wait_days']['n'], 1)
        # rework: t_a completed first pass; t_x failed with timeout
        self.assertEqual(board['rework']['completed_tasks'], 1)
        self.assertEqual(board['rework']['first_pass_tasks'], 1)
        self.assertEqual(board['rework']['failure_outcomes'].get('timeout'), 1)
        # churn: two block events on t_c; t_a's unblocked lands in-window too
        self.assertEqual(board['reblocks']['block_events'], 2)
        self.assertEqual(board['reblocks']['blocks_on_already_blocked_cards'], 0)
        self.assertEqual(board['reblocks']['cards_with_blocks'], 2)
        # review: one accept verdict, no request-changes verdicts
        self.assertEqual(board['review']['verdicts'].get('accept'), 1)
        self.assertEqual(board['review']['repair_rate'], 0.0)
        # no review/ streams exist here: stream_missing, never '0 entries'
        self.assertEqual(board['review']['audit_findings']['status'], 'stream_missing')
        self.assertEqual(board['review']['sweeps']['status'], 'stream_missing')
        # escalation marker on t_b (not gated), claim 2.5h later: released
        self.assertEqual(board['escalation']['escalation_markers'], 1)
        self.assertEqual(board['escalation']['markers_on_currently_gated_cards'], 0)
        self.assertEqual(board['escalation']['release_rate'], 1.0)
        self.assertEqual(board['escalation']['release_rate_excluding_currently_gated'], 1.0)
        # no state.db anywhere in the fixture root: no token estimate
        self.assertIsNone(board['token_effort'])

    def test_adversarial_streams(self):
        """T1: missing vs empty vs unreadable review streams; prose payloads."""
        module = self.filled_module()
        review = self.board / 'review'
        review.mkdir()
        # exists but nothing in-window: 'empty', not 'nothing prevention'
        (review / 'sweeps.jsonl').write_text(
            json.dumps({'at': NOW - 20 * DAY, 'outcome': 'routed'}) + '\n')
        data = module.collect(self.root, NOW - 7 * DAY, NOW, only_board='fixture')
        board = data['boards']['fixture']
        self.assertEqual(board['review']['audit_findings']['status'], 'stream_missing')
        self.assertEqual(board['review']['sweeps']['status'], 'empty')
        # malformed trailing line never crashes the tail read
        with open(review / 'sweeps.jsonl', 'a') as stream:
            stream.write('{"at": ' + str(NOW - DAY) + ', "outcome": "routed"}\n{truncated')
        data = module.collect(self.root, NOW - 7 * DAY, NOW, only_board='fixture')
        self.assertEqual(data['boards']['fixture']['review']['sweeps']['outcomes'],
                         {'routed': 1})

    def test_adversarial_prose_wait_and_open_waits(self):
        """Prose payloads are unattributed, never crashes; wait with no
        release and no later wait is still-open, not zero."""
        module = self.filled_module()
        db = sqlite3.connect(self.board / 'kanban.db')
        db.execute("INSERT INTO task_events (task_id,kind,payload,created_at) "
                   "VALUES ('t_c','dependency_wait','parent not done; long prose',"
                   "?)", (NOW - DAY,))
        db.commit()
        db.close()
        data = module.collect(self.root, NOW - 7 * DAY, NOW, only_board='fixture')
        deps = data['boards']['fixture']['dependencies']
        self.assertEqual(deps['unattributed_waits'], 1)
        self.assertEqual(deps['open_waits_still_blocked'], 1)

    def test_truncation_omits_instead_of_overstating(self):
        """T1: event bound hit -> 'truncated', never half-truths."""
        module = self.filled_module()
        module.MAX_EVENT_ROWS = 4
        data = module.collect(self.root, NOW - 7 * DAY, NOW, only_board='fixture')
        self.assertTrue(data['boards']['fixture'].get('truncated'))

    def test_marker_boundary_and_gated_split(self):
        """T1: markers just before the window are excluded; gated markers
        (block_kind set) split out of the excluding-gated rate."""
        module = self.filled_module()
        db = sqlite3.connect(self.board / 'kanban.db')
        # marker outside the window on t_c, which is gated by block_kind
        db.execute('INSERT INTO task_comments (task_id,author,body,created_at) '
                   "VALUES ('t_c','aging-escalation','Aging escalation',?)",
                   (NOW - 8 * DAY,))
        db.commit()
        db.close()
        data = module.collect(self.root, NOW - 7 * DAY, NOW, only_board='fixture')
        esc = data['boards']['fixture']['escalation']
        self.assertEqual(esc['escalation_markers'], 1)  # boundary excluded
        self.assertEqual(esc['markers_on_currently_gated_cards'], 0)

    def test_zero_verdicts_yield_none(self):
        """T1: no verdicts at all -> repair_rate None, not 0.0."""
        module = self.filled_module()
        db = sqlite3.connect(self.board / 'kanban.db')
        db.execute('DELETE FROM task_runs')
        db.commit()
        db.close()
        data = module.collect(self.root, NOW - 7 * DAY, NOW, only_board='fixture')
        self.assertIsNone(data['boards']['fixture']['review']['repair_rate'])
        self.assertEqual(data['boards']['fixture']['review']['verdicts'], {})

    def test_snapshot_dedupe_and_trend(self):
        """T1/T2: duplicate snapshot skipped; trend compares same-schema only,
        both directions."""
        module = self.filled_module()
        self.run_script('--board', 'fixture', '--days', '7', '--snapshot')
        path = self.root / 'state' / 'analytics' / 'snapshots.jsonl'
        self.assertEqual(oct(path.stat().st_mode & 0o777), oct(0o600))
        second = self.run_script('--board', 'fixture', '--days', '7', '--snapshot')
        self.assertIn('snapshot identical to latest; skipped', second.stdout)
        self.assertEqual(len(path.read_text().strip().splitlines()), 1)
        # different window: appended
        self.run_script('--board', 'fixture', '--days', '2', '--snapshot')
        self.assertEqual(len(path.read_text().strip().splitlines()), 2)
        third = self.run_script('--board', 'fixture', '--days', '7')
        self.assertEqual(third.returncode, 0, third.stderr)
        self.assertIn('Trend vs previous snapshot', third.stdout)

    def test_trend_directions_and_schema_guard(self):
        """T2: trend reports both directions; schema mismatch compares never."""
        module = self.filled_module()
        base = lambda yield_value, version: {
            'schema_version': version,
            'boards': {'fixture': {'lifecycle': {'lead_time_days': {'p95': 2},
                                                 'claim_wait_days': {'p95': 1}},
                                   'rework': {'first_pass_yield': yield_value,
                                              'completed_tasks': 1},
                                   'review': {'repair_rate': 0.5}}}}
        current = base(1.0, module.SNAPSHOT_SCHEMA_VERSION)
        improved = base(0.5, 2)
        worse = module.trend_text(current, base(1.0, module.SNAPSHOT_SCHEMA_VERSION))
        self.assertIn('first_pass_yield 1.0->1.0', worse)
        up = module.trend_text(base(1.0, module.SNAPSHOT_SCHEMA_VERSION),
                               improved)
        self.assertIn('first_pass_yield 0.5->1.0', up)
        stale = module.trend_text(base(1.0, module.SNAPSHOT_SCHEMA_VERSION),
                                  {'schema_version': 1, 'boards': {}})
        self.assertEqual(stale, 'no comparable prior snapshot')

    def _retention(self):
        module = self.filled_module()
        path = self.root / 'state' / 'analytics' / 'snapshots.jsonl'
        for i in range(410):
            module.append_snapshot(self.root, {'at': NOW, 'i': i}, keep=400)
        lines = path.read_text().strip().splitlines()
        self.assertEqual(len(lines), 400)
        self.assertEqual(json.loads(lines[-1])['i'], 409)
        self.assertEqual(json.loads(lines[0])['i'], 10)

    def test_retention_bound(self):
        self._retention()


if __name__ == '__main__':
    unittest.main()
PY
