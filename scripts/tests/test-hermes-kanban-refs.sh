#!/usr/bin/env bash
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
python3 -B - "$repo" <<'PY'
from contextlib import closing
import importlib.util
import sqlite3
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(sys.argv[1])
spec = importlib.util.spec_from_file_location('ref_guard', ROOT / 'scripts/hermes/kanban-ref-guard.py')
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)


def board(root, slug, rows):
    directory = root / 'kanban/boards' / slug
    directory.mkdir(parents=True)
    with closing(sqlite3.connect(directory / 'kanban.db')) as db:
        db.execute('CREATE TABLE tasks (id TEXT PRIMARY KEY, status TEXT)')
        db.executemany('INSERT INTO tasks (id, status) VALUES (?, ?)', rows)
        db.commit()


class ReferenceGuardTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='nixhomeserver-kanban-refs-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        board(self.root, 'nixhomeserver', [('t_live', 'running'), ('t_old', 'archived')])
        board(self.root, 'pcops', [('t_cross', 'archived')])
        self.warnings = []

    def completion(self, **fields):
        return guard.guard({'tool_name': 'kanban_complete', 'tool_input': fields},
                           self.root, self.warnings.append)

    def test_other_tools_are_not_inspected(self):
        self.assertEqual({}, guard.guard({'tool_name': 'kanban_show',
                                          'tool_input': {'summary': 't_ghost'}},
                                         self.root, self.warnings.append))

    def test_resolving_bare_cross_board_and_archived_ids_pass(self):
        self.assertEqual({}, self.completion(
            summary='Hand off t_live; the cross-board pcops/t_cross and the archived t_old also resolve'))

    def test_unknown_ids_are_rejected_and_named(self):
        result = self.completion(summary='Finished t_live',
                                 metadata={'note': 't_ghost plus other/t_phant0m'})
        self.assertEqual('block', result['action'])
        self.assertIn('t_ghost', result['message'])
        self.assertIn('t_phant0m', result['message'])
        self.assertNotIn('t_live', result['message'])

    def test_nested_metadata_is_scanned(self):
        result = self.completion(summary='ok', metadata={'findings': [{'ref': 't_ghost'}],
                                                         'nested': {'ids': ['t_phant0m']}})
        self.assertEqual('block', result['action'])

    def test_partial_words_are_not_mistaken_for_ids(self):
        self.assertEqual({}, self.completion(summary='see subst_ring and mixbrush_thing here'))

    def test_unreadable_board_warns_and_a_resolving_id_still_passes(self):
        broken = self.root / 'kanban/boards/pcops2'
        broken.mkdir()
        (broken / 'kanban.db').write_bytes(b'not a database')
        self.assertEqual({}, self.completion(summary='See t_live'))
        self.assertEqual(1, len(self.warnings))
        self.assertIn('kanban-ref-guard', self.warnings[0])
        self.assertIn('unreadable', self.warnings[0])

    def test_unused_board_placeholder_is_not_a_warning(self):
        placeholder = self.root / 'kanban/boards/_archived'
        placeholder.mkdir()
        (placeholder / 'kanban.db').touch()
        self.assertEqual({}, self.completion(summary='See t_live'))
        self.assertEqual([], self.warnings)

    def test_id_absent_from_every_readable_board_fails(self):
        broken = self.root / 'kanban/boards/pcops2'
        broken.mkdir()
        (broken / 'kanban.db').write_bytes(b'not a database')
        result = self.completion(summary='See t_hidden')
        self.assertEqual('block', result['action'])
        self.assertIn('t_hidden', result['message'])

    def test_no_readable_board_fails_closed(self):
        empty = Path(self.tmp.name) / 'empty-root'
        empty.mkdir()
        result = guard.guard({'tool_name': 'kanban_complete',
                              'tool_input': {'summary': 'See t_live'}}, empty, self.warnings.append)
        self.assertEqual('block', result['action'])
        self.assertIn('t_live', result['message'])

    def test_empty_handoff_is_not_checked(self):
        self.assertEqual({}, self.completion(summary='', metadata={}))


unittest.main(argv=['kanban-refs'], verbosity=2)
PY

# Verify the affected installation paths without running unrelated fleet tests.
bash "$repo/scripts/tests/test-hermes-review-taskforce.sh" \
  TaskforceTest.test_installer_preserves_unrelated_policies_and_is_idempotent \
  TaskforceTest.test_hooks_only_repairs_effective_matcher_without_other_configuration
