#!/usr/bin/env bash
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PYTHONDONTWRITEBYTECODE=1 python3 - "$repo" <<'PY'
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(sys.argv[1]) / 'scripts/hermes'))
spec = importlib.util.spec_from_file_location('policy', Path(sys.argv[1]) / 'scripts/hermes/install-owner-chat-policy.py')
policy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(policy)


class OwnerChatPolicyTest(unittest.TestCase):
    def test_cleanup_preserves_other_destinations_and_never_sends(self):
        with tempfile.TemporaryDirectory(prefix='nixhomeserver-owner-chat-policy-') as tmp:
            root = Path(tmp)
            soul = root / 'profiles/head-coordinator/SOUL.md'
            soul.parent.mkdir(parents=True)
            soul.write_text('# Coordinator\nKeep the deploy gate.\n')
            for board in ('one', 'two'):
                path = root / 'kanban/boards' / board / 'board.json'
                path.parent.mkdir(parents=True)
                path.write_text('{}')
            rows = [dict(task_id='t_done', platform='simplex', chat_id='3', thread_id=''),
                    dict(task_id='t_temp', platform='simplex', chat_id='3', thread_id='topic'),
                    dict(task_id='t_group', platform='simplex', chat_id='group:1', thread_id=''),
                    dict(task_id='t_tui', platform='tui', chat_id='session', thread_id=''),
                    dict(task_id='t_other', platform='simplex', chat_id='4', thread_id='')]
            state = {board: list(rows) for board in ('one', 'two')}
            calls = []

            def run(args, **kwargs):
                calls.append(args)
                self.assertEqual(str(root), kwargs['env']['HERMES_HOME'])
                if 'notify-list' in args:
                    return subprocess.CompletedProcess(args, 0, json.dumps(state[args[args.index('--board') + 1]]), '')
                if 'notify-unsubscribe' in args:
                    board = args[args.index('--board') + 1]
                    task = args[args.index('notify-unsubscribe') + 1]
                    state[board] = [row for row in state[board] if row['task_id'] != task]
                return subprocess.CompletedProcess(args, 0, '', '')

            with patch.object(policy.subprocess, 'run', side_effect=run):
                self.assertEqual(4, policy.install(root, 'simplex:3'))
                installed = soul.read_text()
                self.assertEqual(0, policy.install(root, 'simplex:3'))
                self.assertEqual(installed, soul.read_text())
            self.assertIn('Keep the deploy gate.', installed)
            self.assertIn('unsolicited files', installed)
            self.assertIn('Hard Blocker', installed)
            for remaining in state.values():
                self.assertEqual(['t_group', 't_tui', 't_other'], [row['task_id'] for row in remaining])
            self.assertEqual(4, sum('notify-unsubscribe' in call for call in calls))
            self.assertFalse(any('send' in call for call in calls))
            for profile in ('default', 'head-coordinator'):
                self.assertIn(['hermes', '--profile', profile, 'config', 'set',
                               'kanban.auto_subscribe_on_create', 'false'], calls)

    def test_non_private_destination_fails_before_mutation(self):
        with patch.object(policy.subprocess, 'run') as run:
            with self.assertRaises(ValueError):
                policy.install(Path('/unused'), 'simplex:group:1')
            run.assert_not_called()

    def test_check_reports_drift_without_writing_or_unsubscribing(self):
        with tempfile.TemporaryDirectory(prefix='nixhomeserver-owner-chat-policy-') as tmp:
            root = Path(tmp)
            soul = root / 'profiles/head-coordinator/SOUL.md'
            soul.parent.mkdir(parents=True)
            board = root / 'kanban/boards/one/board.json'
            board.parent.mkdir(parents=True)
            board.write_text('{}')
            rows = []
            auto_subscribe = 'false\n'
            seen = []

            def run(args, **kwargs):
                seen.append(list(args))
                if 'config' in args and 'get' in args:
                    return subprocess.CompletedProcess(args, 0, auto_subscribe, '')
                if 'notify-list' in args:
                    return subprocess.CompletedProcess(args, 0, json.dumps(rows), '')
                return subprocess.CompletedProcess(args, 0, '', '')

            def mutating_calls():
                return [call for call in seen
                        if 'notify-unsubscribe' in call or ('config' in call and 'set' in call)]

            with patch.object(policy.subprocess, 'run', side_effect=run):
                soul.write_text('# Coordinator\nKeep the deploy gate.\n')
                self.assertEqual(1, policy.check(root, 'simplex:3'))
                self.assertEqual('# Coordinator\nKeep the deploy gate.\n', soul.read_text())
                self.assertEqual([], mutating_calls())

                policy.install(root, 'simplex:3')
                seen.clear()
                self.assertEqual(0, policy.check(root, 'simplex:3'))
                self.assertEqual([], mutating_calls())

                rows.append(dict(task_id='t_done', platform='simplex', chat_id='3', thread_id=''))
                self.assertEqual(1, policy.check(root, 'simplex:3'))
                self.assertEqual(1, len(rows))
                self.assertEqual([], mutating_calls())

                auto_subscribe = 'true\n'
                self.assertEqual(3, policy.check(root, 'simplex:3'))
                rows.clear()
                self.assertEqual(2, policy.check(root, 'simplex:3'))
            self.assertIn('unsolicited files', soul.read_text())

    def test_malformed_policy_fails_before_config_changes(self):
        with tempfile.TemporaryDirectory(prefix='nixhomeserver-owner-chat-policy-') as tmp:
            root = Path(tmp)
            soul = root / 'profiles/head-coordinator/SOUL.md'
            soul.parent.mkdir(parents=True)
            start, end = policy.MARKER + '\n', policy.END_MARKER + '\n'
            for text in (start, end, start + end + end, start + start + end, end + start):
                with self.subTest(text=text):
                    soul.write_text(text)
                    with patch.object(policy.subprocess, 'run') as run:
                        with self.assertRaises(ValueError):
                            policy.install(root, 'simplex:3')
                        run.assert_not_called()
                    self.assertEqual(text, soul.read_text())


unittest.main(argv=['owner-chat-policy'], verbosity=2)
PY
