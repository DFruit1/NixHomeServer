#!/usr/bin/env bash
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
python3 -B - "$repo" <<'PY'
import importlib.util
import sqlite3
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('blockers', Path(sys.argv[1])/'scripts/hermes/kanban-blockers.py')
blockers = importlib.util.module_from_spec(spec)
spec.loader.exec_module(blockers)


class BlockersTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='nixhomeserver-hermes-blockers-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.path = self.root/'kanban/boards/one/kanban.db'
        self.path.parent.mkdir(parents=True)
        self.db = sqlite3.connect(self.path)
        self.addCleanup(self.db.close)
        self.db.executescript('''CREATE TABLE tasks(id TEXT PRIMARY KEY,status TEXT,assignee TEXT,block_kind TEXT);
            CREATE TABLE task_links(parent_id TEXT,child_id TEXT);''')

    def task(self, tid, status='todo', kind=None):
        self.db.execute('INSERT INTO tasks VALUES (?,?,?,?)', (tid,status,'standard-implementer',kind))

    def edge(self, parent, child):
        self.db.execute('INSERT INTO task_links VALUES (?,?)', (parent,child))

    def report(self):
        self.db.commit()
        before = self.path.read_bytes()
        result = blockers.report(self.root, 'one')['boards']['one']
        self.assertEqual(before, self.path.read_bytes())
        return result

    def test_chain_diamond_has_unique_root_impact_and_one_bounded_path(self):
        for tid in ('root','a','b','leaf'): self.task(tid)
        for parent, child in [('root','a'),('root','b'),('a','leaf'),('b','leaf')]: self.edge(parent,child)
        r = self.report()
        self.assertEqual(3, r['waiting_cards'])
        self.assertEqual(3, r['roots'][0]['downstream_cards'])
        leaf = next(w for w in r['waiting'] if w['task_id']=='leaf')
        self.assertEqual(['root'], leaf['roots'])
        self.assertEqual(['leaf','a','root'], leaf['paths']['root'])

    def test_only_done_satisfies_native_dependencies_archived_does_not(self):
        self.task('done','done'); self.task('old','archived'); self.task('child')
        self.edge('done','child'); self.edge('old','child')
        r=self.report()
        self.assertEqual(['old'], r['waiting'][0]['roots'])
        self.assertEqual('archived_prerequisite', r['roots'][0]['category'])

    def test_cycle_and_missing_parent_are_visible_and_never_dispatchable(self):
        for tid in ('a','b','downstream','orphan'): self.task(tid)
        self.edge('a','b'); self.edge('b','a'); self.edge('b','downstream'); self.edge('missing','orphan')
        r=self.report()
        self.assertEqual([['a','b']],r['cycles'])
        self.assertTrue(r['dangling_links'])
        self.assertTrue(any(root['category']=='cycle' for root in r['roots']))
        self.assertTrue(any(root['category']=='missing_prerequisite' for root in r['roots']))

    def test_local_hold_is_kept_even_with_an_unfinished_parent(self):
        self.task('producer','running'); self.task('gate','blocked','needs_input'); self.task('child')
        self.edge('producer','gate'); self.edge('gate','child')
        r=self.report()
        child=next(w for w in r['waiting'] if w['task_id']=='child')
        self.assertEqual(['gate'], child['holds'])
        self.assertEqual(['producer'], child['roots'])
        self.assertEqual('gate', r['local_holds'][0]['task_id'])
        self.assertEqual(1, r['local_holds'][0]['downstream_cards'])

    def test_no_database_creation_and_bad_board_identifiers_fail(self):
        self.db.close()
        self.path.unlink()
        r=blockers.report(self.root,'one')
        self.assertTrue(r['warnings'])
        self.assertFalse(self.path.exists())
        self.path.with_name('board.json').write_text('{}')
        self.assertTrue(blockers.report(self.root)['warnings'])
        with self.assertRaises(ValueError): blockers.report(self.root,'../escape')

    def test_archived_intermediate_is_visible_and_cycle_expansion_is_bounded(self):
        self.task('producer','running'); self.task('archived','archived'); self.task('child')
        self.edge('producer','archived'); self.edge('archived','child')
        r=self.report()
        self.assertEqual('archived_prerequisite',r['local_holds'][0]['category'])
        tasks={str(i):{'status':'blocked','block_kind':'dependency','assignee':None} for i in range(20)}
        links=[(str(i),str((i+1)%20)) for i in range(20)]
        with patch.object(blockers,'MAX_WALK',100), self.assertRaises(ValueError):
            blockers.analyze(tasks,links)

    def test_long_chain_does_not_use_python_recursion(self):
        for i in range(1100):
            self.task(str(i))
            if i: self.edge(str(i-1),str(i))
        r=self.report()
        self.assertEqual(1099,r['roots'][0]['downstream_cards'])


unittest.main(argv=['blockers'],verbosity=2)
PY
