#!/usr/bin/env bash
set -euo pipefail
TESTS_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

python3 -B - "$TESTS_REPO_ROOT" <<'PY'
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

source = Path(sys.argv[1]) / 'scripts/hermes'
sys.path.insert(0, str(source))

def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, source / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class CardDependenciesTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.guard = load('card_dependencies', 'card-dependency-guard.py')
        cls.installer = load('instruction_policy', 'install-instruction-policy.py')

    def request(self, body, tool='kanban_comment', profile='standard-implementer'):
        args = {'body': body, 'board': 'fixture', 'task_id': 't_child'}
        if tool == 'kanban_amend':
            args = {'changes': {'body': body}}
        return self.guard.guard({'tool_name': tool, 'tool_input': args, 'profile': profile})

    def test_dependency_prose_is_refused_on_every_card_write(self):
        for text in ('Waiting on t_ab12cd34.', 'Depends on fixture:t_parent.',
                     'Blocked by card t_parent.', 'Resume after t_parent completes.',
                     't_parent must finish before this card starts.',
                     'Dependencies:\n- t_parent', 'Parents: t_parent',
                     't_parent -> t_child', 'Awaiting the upstream review card.',
                     'Wait for the upstream review card.', 'This task requires t_parent.',
                     'Pending t_parent.', 'Proceed when t_parent delivers.',
                     't_parent blocks t_child.', 'Depends upon t_parent.',
                     'Waits on t_parent.', 't_child <- t_parent'):
            for tool in ('kanban_comment', 'kanban_create', 'kanban_amend'):
                with self.subTest(text=text, tool=tool):
                    result = self.request('Update: Prepared.\nEvidence: Tests pass.\nNext: ' + text, tool)
                    self.assertEqual('block', result.get('action'))
                    self.assertIn('kanban_link', result['message'])
                    self.assertIn('parents', result['message'])

    def test_references_membership_and_normal_updates_remain_available(self):
        for text in ('Update: Fixed retries.\nEvidence: Tests pass.\nNext: Review the change.',
                     'Goal: Show pending tasks in the admin list.',
                     'Evidence: Accepted output t_example includes the dependency parser fix.',
                     'Evidence: Accepted result recorded on t_ab12cd34.',
                     'Feature tracker: fixture:t_parent',
                     'Goal: Update Cargo dependencies.',
                     'Goal: Fix task dependency validation.',
                     'Evidence: The parents field is displayed correctly.',
                     'Next: This task requires Cargo to run the tests.',
                     'Goal: Repair a card pending owner approval.',
                     'Next: Awaiting the reviewer verdict on this task.',
                     'Evidence: Tests pass after installing the package.',
                     'Evidence: Graph readback verified; obsolete edge removed.'):
            self.assertEqual({}, self.request(text), text)
        # A tracker marker cannot hide an informal wait on the next line.
        self.assertEqual('block', self.request(
            'Feature tracker: fixture:t_parent\nNext: Wait for t_parent.').get('action'))
        for tool in ('kanban_link', 'kanban_unlink', 'kanban_show', 'kanban_block'):
            self.assertEqual({}, self.request('Waiting on t_parent.', tool))

    def test_owner_quotes_and_structured_decisions_preserve_their_contracts(self):
        texts = ['Owner reply received: Wait for t_parent.',
                 'Owner reply via SimpleX D2: Wait for t_parent.']
        for key in ('deployment_decision', 'owner_execution_decision', 'delegated_execution_decision'):
            texts.append(json.dumps({key: {'reason': 'Wait for t_parent.'}}))
        for text in texts:
            self.assertEqual({}, self.request(text, profile='head-coordinator'))
            self.assertEqual('block', self.request(text).get('action'))
        self.assertEqual('block', self.request(
            'Owner reply received: Wait for t_parent.', 'kanban_create', 'head-coordinator').get('action'))

    def test_hook_fails_closed_on_malformed_input(self):
        for payload in ('{', '[]', '{"tool_name":"kanban_comment","tool_input":[]}'):
            run = subprocess.run([sys.executable, '-B', str(source / 'card-dependency-guard.py')],
                                 input=payload, text=True, capture_output=True, check=True)
            self.assertEqual('block', json.loads(run.stdout).get('action'))

    def test_existing_owner_hook_checks_dependencies_before_reading_the_board(self):
        owner = load('owner_authoring', 'owner-blocker-authoring-guard.py')
        request = {'tool_name': 'kanban_comment', 'profile': 'standard-implementer',
                   'tool_input': {'body': 'Next: Wait for t_parent.'}}
        result = owner.guard(request, Path('/nonexistent-fixture'), None)
        self.assertEqual('block', result.get('action'))
        self.assertIn('kanban_link', result['message'])

    def test_scoped_install_covers_all_profiles_without_changing_board_data(self):
        with tempfile.TemporaryDirectory(prefix='hermes-card-dependencies-') as tmp:
            root = Path(tmp)
            homes = [root] + [root / 'profiles' / name for name in (*self.installer.PROFILES, 'custom-worker')]
            for home in homes:
                home.mkdir(parents=True, exist_ok=True)
                (home / 'SOUL.md').write_text('Keep operator instructions.\n')
                (home / 'config.yaml').write_text('model: unchanged\napprovals: unchanged\n')
            board = root / 'kanban/boards/fixture/kanban.db'
            board.parent.mkdir(parents=True)
            board.write_bytes(b'Historical cards and comments remain unchanged.')
            before = board.read_bytes()
            self.assertEqual(1, self.installer.install(root, check=True, dependencies_only=True))
            self.assertFalse((root / 'scripts').exists())
            self.assertEqual(0, self.installer.install(root, dependencies_only=True))
            self.assertEqual(0, self.installer.install(root, check=True, dependencies_only=True))
            self.assertEqual(before, board.read_bytes())
            for home in homes:
                text = (home / 'SOUL.md').read_text()
                self.assertIn('Keep operator instructions.', text)
                self.assertIn('Never encode card dependencies in comments', text)
                config = (home / 'config.yaml').read_text()
                self.assertIn('model: unchanged\napprovals: unchanged', config)
                self.assertIn('^kanban_(create|amend|comment)$', config)
                self.assertIn('fail_closed: true', config)
            steward = load('steward_installer', 'install-steward-readonly.py')
            text = (root / 'profiles/board-steward/SOUL.md').read_text()
            refreshed = steward.steward_soul(text, self.installer)
            self.assertIn('Never encode card dependencies in comments', refreshed)

    def test_bad_hook_config_is_rejected_before_any_install_write(self):
        with tempfile.TemporaryDirectory(prefix='hermes-card-dependencies-') as tmp:
            root = Path(tmp)
            (root / 'SOUL.md').write_text('Keep this.\n')
            (root / 'config.yaml').write_text('hooks: malformed\n')
            before = {p: p.read_bytes() for p in root.rglob('*') if p.is_file()}
            with self.assertRaises(ValueError):
                self.installer.install(root, dependencies_only=True)
            self.assertEqual(before, {p: p.read_bytes() for p in root.rglob('*') if p.is_file()})

    def test_config_only_profiles_converge_without_creating_new_instruction_scopes(self):
        with tempfile.TemporaryDirectory(prefix='hermes-card-dependencies-') as tmp:
            root = Path(tmp)
            (root / 'config.yaml').write_text('model: unchanged\n')
            self.assertEqual(0, self.installer.install(root))
            self.assertFalse((root / 'SOUL.md').exists())
            self.assertEqual(0, self.installer.install(root, check=True))


unittest.main(argv=['test-hermes-card-dependencies'], verbosity=2)
PY
