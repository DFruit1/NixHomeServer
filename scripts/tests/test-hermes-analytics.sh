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


def analytics_module():
    source = Path(REPO) / 'scripts/hermes/kanban-analytics.py'
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
        db = sqlite3.connect(self.board / 'kanban.db')
        db.executescript(SCHEMA)
        created = NOW - 3 * DAY
        # t_a: clean flow with a named dependency wait; t_x: a failed run
        for task, status, completed in (('t_a', 'done', NOW - DAY - 3600),
                                        ('t_b', 'todo', None),
                                        ('t_c', 'blocked', None),
                                        ('t_parent', 'done', NOW - DAY)):
            db.execute('INSERT INTO tasks (id,title,status,created_at,completed_at) '
                       'VALUES (?,?,?,?,?)', (task, task, status, created, completed))
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
        runs = [('t_a', 'done', 'completed',
                 json.dumps({'verdict': 'accept', 'worker_session_id': 's_ok'}),
                 NOW - DAY - 7200)]
        for task, status, outcome, metadata, started in runs:
            db.execute('INSERT INTO task_runs (task_id,profile,status,outcome,'
                       'metadata,started_at) VALUES (?,?,?,?,?,?)',
                       (task, 'fixture', status, outcome, metadata, started))
        db.execute('INSERT INTO task_runs (task_id,profile,status,outcome,'
                   "metadata,started_at) VALUES ('t_x','fixture','failed','timed_out',"
                   "'{}',?)", (NOW - 2 * DAY + 3600,))
        db.execute('INSERT INTO task_comments (task_id,author,body,created_at) '
                   "VALUES ('t_b','aging-escalation','Aging escalation: idle',?)",
                   (NOW - 2 * DAY - 7200,))
        db.commit()
        db.close()

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
        env = os.environ.copy()
        env['HERMES_ROOT'] = str(self.root)
        module = analytics_module()
        return module.collect(self.root, NOW - days * DAY, NOW, only_board='fixture')

    def test_report_metrics(self):
        result = self.run_script('--board', 'fixture', '--days', '7', '--json')
        self.assertEqual(result.returncode, 0, result.stderr)
        data = json.loads(result.stdout)
        board = data['boards']['fixture']
        self.assertEqual(board['lifecycle']['completed_cards'], 1)
        # t_a and t_b both claim inside the window; t_a waited 600s (<1d)
        self.assertEqual(board['lifecycle']['claim_wait_days']['n'], 2)
        self.assertGreater(board['lifecycle']['claim_wait_days']['p50'], 0)
        self.assertLess(board['lifecycle']['claim_wait_days']['p50'], 1)
        self.assertEqual(board['lifecycle']['open_cards_by_status']
                         .get('todo', {}).get('count'), 1)
        self.assertEqual(board['lifecycle']['open_cards_by_status']
                         .get('blocked', {}).get('count'), 1)
        # dependency attribution names the parent exactly once
        chronic = {entry['parent']: entry['waits']
                   for entry in board['dependencies']['chronic_parents']}
        self.assertEqual(chronic.get('t_parent'), 1)
        # rework: t_a completed first pass; t_x completed 0, failed with timeout
        self.assertEqual(board['rework']['completed_tasks'], 1)
        self.assertEqual(board['rework']['first_pass_tasks'], 1)
        self.assertEqual(board['rework']['failure_outcomes'].get('timeout'), 1)
        # churn: two block events on t_c; t_a's unblocked also lands in the
        # window, so two distinct cards appear in the blocked/unblocked set
        self.assertEqual(board['reblocks']['block_events'], 2)
        self.assertEqual(board['reblocks']['blocks_on_already_blocked_cards'], 0)
        self.assertEqual(board['reblocks']['cards_with_blocks'], 2)
        # review: one accept verdict, no request-changes verdicts
        self.assertEqual(board['review']['verdicts'].get('accept'), 1)
        self.assertEqual(board['review']['repair_rate'], 0.0)
        # escalation marker followed by a claim on t_b: released
        self.assertEqual(board['escalation']['escalation_markers'], 1)
        self.assertEqual(board['escalation']['cards_released_after_marker'], 1)
        self.assertEqual(board['escalation']['release_rate'], 1.0)

    def test_snapshot_and_trend(self):
        first = self.run_script('--board', 'fixture', '--days', '7', '--snapshot')
        self.assertEqual(first.returncode, 0, first.stderr)
        path = self.root / 'state' / 'analytics' / 'snapshots.jsonl'
        self.assertEqual(len(path.read_text().strip().splitlines()), 1)
        self.assertEqual(oct(path.stat().st_mode & 0o777), oct(0o600))
        # a second snapshot with a different window; trend reads the prior one
        second = self.run_script('--board', 'fixture', '--days', '2', '--snapshot')
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual(len(path.read_text().strip().splitlines()), 2)
        third = self.run_script('--board', 'fixture', '--days', '7')
        self.assertEqual(third.returncode, 0, third.stderr)
        self.assertIn('Trend vs previous snapshot', third.stdout)

    def test_retention_bound(self):
        analytics = analytics_module()
        path = self.root / 'state' / 'analytics' / 'snapshots.jsonl'
        for i in range(410):
            analytics.append_snapshot(self.root, {'at': NOW, 'i': i}, keep=400)
        lines = path.read_text().strip().splitlines()
        self.assertEqual(len(lines), 400)
        self.assertEqual(json.loads(lines[-1])['i'], 409)
        self.assertEqual(json.loads(lines[0])['i'], 10)


if __name__ == '__main__':
    unittest.main()
PY
