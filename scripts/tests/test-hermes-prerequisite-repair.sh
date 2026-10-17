#!/usr/bin/env bash
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
python3 -B - "$repo" <<'PY'
from contextlib import closing
import importlib.util
import os
from pathlib import Path
import sqlite3
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(sys.argv[1])
spec = importlib.util.spec_from_file_location(
    'prerequisite_repair', ROOT / 'scripts/hermes/kanban-prerequisite-repair.py')
repair = importlib.util.module_from_spec(spec)
spec.loader.exec_module(repair)


class PrerequisiteRepairTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='nixhomeserver-prerequisite-repair-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.board = self.root / 'kanban/boards/one'
        self.board.mkdir(parents=True)
        self.path = self.board / 'kanban.db'
        with closing(sqlite3.connect(self.path)) as db:
            db.executescript('''CREATE TABLE tasks (
                id TEXT PRIMARY KEY, status TEXT, assignee TEXT, block_kind TEXT);
                CREATE TABLE task_links (parent_id TEXT, child_id TEXT);''')

    def seed(self, tasks, links):
        with closing(sqlite3.connect(self.path)) as db:
            db.executemany('INSERT INTO tasks VALUES (?,?,?,?)',
                           [(tid, status, 'standard-implementer', None)
                            for tid, status in tasks.items()])
            db.executemany('INSERT INTO task_links VALUES (?,?)', links)
            db.commit()

    def _connection(self):
        db = sqlite3.connect(self.path)
        db.row_factory = sqlite3.Row
        return db

    def test_dry_run_lists_only_open_children_whose_parents_are_all_dead_and_is_read_only(self):
        self.seed({'archived': 'archived', 'missing-child': 'todo',
                   'mixed-child': 'todo', 'open': 'running', 'done-child': 'done'},
                  [('archived', 'missing-child'), ('gone', 'missing-child'),
                   ('archived', 'mixed-child'), ('open', 'mixed-child'),
                   ('gone', 'done-child')])
        before = self.path.read_bytes()
        result = repair.plan(self.root, 'one')
        self.assertEqual(before, self.path.read_bytes())
        self.assertEqual([{'task_id': 'missing-child', 'parents': ['archived', 'gone']}],
                         result['candidates'])

    def test_apply_unlinks_only_dead_edges_for_fully_releasable_child(self):
        self.seed({'archived': 'archived', 'gone-child': 'todo',
                   'mixed-child': 'todo', 'open': 'running'},
                  [('archived', 'gone-child'), ('gone', 'gone-child'),
                   ('archived', 'mixed-child'), ('open', 'mixed-child')])
        calls = []
        def unlink(conn, parent_id, child_id):
            calls.append((parent_id, child_id))
            conn.execute('DELETE FROM task_links WHERE parent_id=? AND child_id=?',
                         (parent_id, child_id))
            conn.commit()
            return True
        with patch.object(repair, 'native_api', return_value=(
                type('NativeApi', (), {'unlink_tasks': staticmethod(unlink)})(),
                lambda _path: self._connection())):
            released = repair.apply(self.root, 'one', profile='head-coordinator')
        self.assertEqual([('archived', 'gone-child'), ('gone', 'gone-child')], calls)
        self.assertEqual([{'task_id': 'gone-child', 'parents': ['archived', 'gone']}], released)

    def test_apply_requires_head_coordinator(self):
        with patch.dict(os.environ, {'HERMES_PROFILE': 'standard-implementer'}):
            with self.assertRaises(PermissionError):
                repair.apply(self.root, 'one')

    def test_apply_refuses_child_with_any_open_parent_edge(self):
        self.seed({'archived': 'archived', 'open': 'todo', 'child': 'todo'},
                  [('archived', 'child'), ('open', 'child')])
        calls = []
        with patch.object(repair, 'native_api', return_value=(None, lambda *args: calls.append(args))):
            released = repair.apply(self.root, 'one', profile='head-coordinator')
        self.assertEqual([], calls)
        self.assertEqual([], released)


unittest.main(argv=['prerequisite-repair'], verbosity=2)
PY
