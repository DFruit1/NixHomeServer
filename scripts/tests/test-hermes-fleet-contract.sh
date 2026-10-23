#!/usr/bin/env bash
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
python3 -B - "$repo" <<'PY'
import copy
import json
from pathlib import Path
import sqlite3
import sys
import unittest
sys.path.insert(0, str(Path(sys.argv[1]) / 'scripts/hermes'))
import fleet_contract as contract


class ContractTest(unittest.TestCase):
    def setUp(self):
        self.db = sqlite3.connect(':memory:')
        self.db.row_factory = sqlite3.Row
        self.addCleanup(self.db.close)
        self.db.execute('CREATE TABLE task_events(id INTEGER PRIMARY KEY, task_id TEXT, kind TEXT, payload TEXT)')
        self.workflow = {'version': 1, 'review': 'native-review-v1', 'plan_author': 'owner',
                         'feature': {'tracker': 'test:t_feature', 'role': 'producer', 'scope': 'synthetic slice'}}

    def record(self, value):
        self.db.execute('INSERT INTO task_events(task_id,kind,payload) VALUES(?,?,?)',
                        ('t_work', 'created', json.dumps({'workflow': value})))

    def test_validated_contract_generates_readable_markers(self):
        value = contract.validate(self.workflow)
        text = contract.render('Goal: implement the slice.', value)
        self.assertIn('Workflow: native-review-v1', text)
        self.assertIn('Feature tracker: test:t_feature', text)
        self.assertEqual(text, contract.render(text, value))

    def test_unknown_fields_and_ambiguous_bindings_are_refused(self):
        for value in ({**self.workflow, 'version': 2}, {**self.workflow, 'version': True},
                      {**self.workflow, 'typo': 'x'}, {**self.workflow, 'plan_author': False},
                      {**self.workflow, 'feature': {'tracker': 't_feature', 'role': 'producer'}},
                      {**self.workflow, 'requirements': {'tools': ['terminal;echo x']}},
                      {**self.workflow, 'requirements': {'imports': ['os.system']}}):
            with self.subTest(value=value), self.assertRaises(ValueError):
                contract.validate(value)

    def test_saved_contract_is_authoritative_and_legacy_is_explicit(self):
        self.assertIsNone(contract.load(self.db, 't_work'))
        self.record(self.workflow)
        self.db.execute('INSERT INTO task_events(task_id,kind,payload) VALUES(?,?,?)',
                        ('t_work', 'commented', json.dumps({'body': 'Workflow: anything'})))
        self.assertEqual(self.workflow, contract.load(self.db, 't_work'))

    def test_bad_saved_contract_never_falls_back_to_prose(self):
        for value in (None, {}, {'version': 2}):
            self.db.execute('DELETE FROM task_events')
            self.record(value)
            with self.assertRaises(ValueError):
                contract.load(self.db, 't_work')

    def test_review_author_is_filled_only_from_declared_contract(self):
        self.record(self.workflow)
        metadata = {'revision': 'a' * 40, 'checks': [{'command': 'test', 'exit_code': 0}]}
        original = copy.deepcopy(metadata)
        self.assertEqual('owner', contract.review_metadata(self.db, 't_work', metadata)['plan_author'])
        self.assertEqual(original, metadata)
        with self.assertRaises(ValueError):
            contract.review_metadata(self.db, 't_work', {**metadata, 'plan_author': 'invented-author'})


unittest.main(argv=[sys.argv[0]])
PY
