#!/usr/bin/env bash
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
python3 -B - "$repo" <<'PY'
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(sys.argv[1]) / 'scripts/hermes'))
spec = importlib.util.spec_from_file_location('decisions', Path(sys.argv[1]) / 'scripts/hermes/simplex_decisions.py')
decisions = importlib.util.module_from_spec(spec)
spec.loader.exec_module(decisions)
installer_spec = importlib.util.spec_from_file_location(
    'installer', Path(sys.argv[1]) / 'scripts/hermes/install-decision-channel.py')
installer = importlib.util.module_from_spec(installer_spec)
installer_spec.loader.exec_module(installer)


class FakeTransport:
    def __init__(self):
        self.calls = []
        self.next_id = 40
        self.items = {}

    def send(self, group, text):
        self.next_id += 1
        self.items[self.next_id] = text
        self.calls.append(('send', group, self.next_id, text))
        return self.next_id

    def update(self, group, item_id, text):
        if item_id not in self.items:
            raise decisions.ItemGone('item not found')
        self.items[item_id] = text
        self.calls.append(('update', group, item_id, text))

    def delete(self, group, item_id):
        self.items.pop(item_id, None)
        self.calls.append(('delete', group, item_id))


class DecisionChannelTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='hermes-decisions-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.env = self.root / 'profiles/head-coordinator/.env'
        self.env.parent.mkdir(parents=True)
        self.env.write_text('SIMPLEX_WS_URL=ws://127.0.0.1:5225\n'
                            'SIMPLEX_HOME_CHANNEL=3\nSIMPLEX_ALLOWED_USERS=3\n'
                            'SIMPLEX_DECISION_GROUP=7\nSIMPLEX_GROUP_ALLOWED=7\n')
        self.transport = FakeTransport()

    def state(self):
        return json.loads(decisions.state_path(self.root).read_text())

    def test_group_configuration_fails_closed_on_a_wider_allowlist(self):
        self.assertEqual(7, decisions.configured_group(self.root))
        base = ('SIMPLEX_WS_URL=ws://127.0.0.1:5225\n'
                'SIMPLEX_HOME_CHANNEL=3\nSIMPLEX_ALLOWED_USERS=3\n')
        cases = {
            'wider allowlist': base + 'SIMPLEX_DECISION_GROUP=7\nSIMPLEX_GROUP_ALLOWED=7,8\n',
            'wildcard allowlist': base + 'SIMPLEX_DECISION_GROUP=7\nSIMPLEX_GROUP_ALLOWED=*\n',
            'non-numeric group': base + 'SIMPLEX_DECISION_GROUP=seven\nSIMPLEX_GROUP_ALLOWED=seven\n',
            'allowlist without a group': base + 'SIMPLEX_GROUP_ALLOWED=7\n',
        }
        for name, content in cases.items():
            with self.subTest(name=name):
                self.env.write_text(content)
                with self.assertRaises(ValueError):
                    decisions.configured_group(self.root)
        self.env.write_text(base)
        self.assertIsNone(decisions.configured_group(self.root))

    def test_reconcile_posts_edits_and_deletes_only_alert_messages(self):
        decisions.post(self.root, 'plan-x', 'Plan X is still open', transport=self.transport)
        self.assertEqual(1, len(self.transport.calls))

        errors = decisions.reconcile(self.root, {'alert:D1': 'Decision one'}, transport=self.transport)
        self.assertEqual([], errors)
        first = self.state()['messages']['alert:D1']['item_id']
        self.assertIn('plan-x', self.state()['messages'])
        self.assertEqual('Decision one', self.transport.items[first])

        # An unchanged live set sends no duplicate message and leaves the item id
        # alone, though it still verifies the item exists.
        before = [call for call in self.transport.calls if call[0] == 'send']
        decisions.reconcile(self.root, {'alert:D1': 'Decision one'}, transport=self.transport)
        self.assertEqual(before, [call for call in self.transport.calls if call[0] == 'send'])

        decisions.reconcile(self.root, {'alert:D1': 'Decision one, revised'}, transport=self.transport)
        self.assertEqual('Decision one, revised', self.transport.items[first])
        self.assertEqual(first, self.state()['messages']['alert:D1']['item_id'])

        decisions.reconcile(self.root, {}, transport=self.transport)
        self.assertNotIn(first, self.transport.items)
        self.assertNotIn('alert:D1', self.state()['messages'])
        self.assertIn('plan-x', self.state()['messages'])

    def test_manual_messages_are_edited_and_deleted_by_key(self):
        item = decisions.post(self.root, 'deploy-choice', 'Choose A or B', transport=self.transport)
        self.assertEqual('Choose A or B', self.transport.items[item])
        with self.assertRaises(ValueError):
            decisions.post(self.root, 'deploy-choice', 'duplicate', transport=self.transport)
        with self.assertRaises(ValueError):
            decisions.post(self.root, 'D1', 'collides with an alert label', transport=self.transport)

        decisions.edit(self.root, 'deploy-choice', 'Choose B only', transport=self.transport)
        self.assertEqual('Choose B only', self.transport.items[item])
        self.assertTrue(decisions.delete(self.root, 'deploy-choice', transport=self.transport))
        self.assertFalse(decisions.delete(self.root, 'deploy-choice', transport=self.transport))
        self.assertEqual({}, self.state()['messages'])

    def test_state_refuses_to_reuse_ids_from_another_group(self):
        decisions.post(self.root, 'plan-x', 'Plan X', transport=self.transport)
        self.env.write_text(self.env.read_text().replace('SIMPLEX_DECISION_GROUP=7', 'SIMPLEX_DECISION_GROUP=8')
                            .replace('SIMPLEX_GROUP_ALLOWED=7', 'SIMPLEX_GROUP_ALLOWED=8'))
        with self.assertRaises(ValueError):
            decisions.reconcile(self.root, {'alert:D1': 'Decision one'}, transport=self.transport)

    def test_replace_deletes_the_old_item_and_rejects_empty_edits(self):
        old = decisions.post(self.root, 'plan-x', 'Plan X v1', transport=self.transport)
        new = decisions.post(self.root, 'plan-x', 'Plan X v2', transport=self.transport, replace=True)
        self.assertNotEqual(old, new)
        self.assertNotIn(old, self.transport.items)
        self.assertEqual('Plan X v2', self.transport.items[new])
        with self.assertRaises(ValueError):
            decisions.edit(self.root, 'plan-x', '   ', transport=self.transport)

    def test_items_deleted_outside_the_ledger_are_recreated(self):
        decisions.reconcile(self.root, {'alert:D1': 'Decision one'}, transport=self.transport)
        old = self.state()['messages']['alert:D1']['item_id']
        del self.transport.items[old]
        decisions.reconcile(self.root, {'alert:D1': 'Decision one'}, transport=self.transport)
        new = self.state()['messages']['alert:D1']['item_id']
        self.assertNotEqual(old, new)
        self.assertEqual('Decision one', self.transport.items[new])


class InstallerTest(unittest.TestCase):
    def test_env_update_preserves_comments_and_replaces_existing_keys(self):
        with tempfile.TemporaryDirectory(prefix='hermes-decisions-install-') as tmp:
            env = Path(tmp) / '.env'
            env.write_text('# keep me\nSIMPLEX_WS_URL=ws://127.0.0.1:5225\nSIMPLEX_DECISION_GROUP=2\n')
            wanted = installer.set_env(env, {'SIMPLEX_DECISION_GROUP': '9',
                                             'SIMPLEX_GROUP_ALLOWED': '9'})
            self.assertIn('# keep me', wanted)
            self.assertIn('SIMPLEX_DECISION_GROUP=9', wanted)
            self.assertIn('SIMPLEX_GROUP_ALLOWED=9', wanted)
            self.assertEqual(1, wanted.count('SIMPLEX_DECISION_GROUP='))

    def test_owner_contact_must_be_the_allowlisted_home_contact(self):
        with tempfile.TemporaryDirectory(prefix='hermes-decisions-owner-') as tmp:
            root = Path(tmp)
            env = root / 'profiles/head-coordinator/.env'
            env.parent.mkdir(parents=True)
            env.write_text('SIMPLEX_HOME_CHANNEL=3\nSIMPLEX_ALLOWED_USERS=3,4\n')
            self.assertEqual(3, installer.owner_contact(root))
            env.write_text('SIMPLEX_HOME_CHANNEL=5\nSIMPLEX_ALLOWED_USERS=3,4\n')
            with self.assertRaises(ValueError):
                installer.owner_contact(root)


if __name__ == '__main__':
    unittest.main(argv=['decision-channel'])
PY
