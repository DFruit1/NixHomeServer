#!/usr/bin/env bash
set -euo pipefail
TESTS_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
python3 -B - "$TESTS_REPO_ROOT" <<'PY'
from contextlib import closing
import importlib.util
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
from contextlib import redirect_stdout
from io import StringIO
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('alerts', Path(sys.argv[1]) / 'scripts/hermes/kanban-owner-alerts.py')
alerts = importlib.util.module_from_spec(spec)
spec.loader.exec_module(alerts)


class AlertsTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.env = self.root / 'profiles/head-coordinator/.env'
        self.env.parent.mkdir(parents=True)
        self.env.write_text('SIMPLEX_WS_URL=ws://127.0.0.1:5225\nSIMPLEX_ALLOWED_USERS=3\nSIMPLEX_HOME_CHANNEL=3\n')
        for board in ['one', 'two']:
            p = self.root / 'kanban/boards' / board
            p.mkdir(parents=True)
            (p / 'board.json').write_text('{}')
            with closing(sqlite3.connect(p / 'kanban.db')) as db:
                db.executescript('CREATE TABLE tasks (id TEXT, title TEXT, body TEXT, status TEXT, block_kind TEXT); CREATE TABLE task_events (id INTEGER, task_id TEXT, kind TEXT, payload TEXT);')
                db.execute('INSERT INTO tasks VALUES (?, ?, ?, ?, ?)', ('t_12345678', 'Decide repair', 'ASK: Approve repair?\n A) Approve\n B) Reject', 'blocked', 'needs_input' if board == 'one' else 'capability'))
                db.execute('INSERT INTO task_events VALUES (1, ?, ?, ?)', ('t_12345678', 'blocked', json.dumps({'reason': 'Need a decision' if board == 'one' else 'Evidence unavailable'})))
                db.commit()
        self.boards = {name: self.root / 'kanban/boards' / name / 'kanban.db' for name in ('one', 'two')}
        self.sent = []
        self.real_send = alerts.send
        self.sender = patch.object(alerts, 'send', lambda root, target, message: self.sent.append(message))
        self.sender.start()
        self.addCleanup(self.sender.stop)

    def board_bytes(self):
        return {name: path.read_bytes() for name, path in self.boards.items()}

    def test_nothing_unsolicited_reaches_the_owner(self):
        alerts.tick(self.root, now=1000)
        self.assertEqual([], self.sent)
        # Labels are still allocated, so pulls and replies resolve to a card.
        self.assertEqual('one', alerts.resolve(self.root, 'D1')['board'])
        self.assertEqual('two', alerts.resolve(self.root, 'B1')['board'])
        with closing(sqlite3.connect(self.boards['one'])) as db:
            db.execute("UPDATE tasks SET body='ASK: Approve a revised plan?'")
            db.execute('INSERT INTO task_events VALUES (2, ?, ?, ?)', ('t_12345678', 'blocked', '{"reason":"Different question"}'))
            db.commit()
        with closing(sqlite3.connect(self.boards['two'])) as db:
            db.execute('INSERT INTO task_events VALUES (3, ?, ?, ?)', ('t_12345678', 'blocked', '{"reason":"Still unavailable, attempt 3"}'))
            db.execute("INSERT INTO tasks VALUES ('t_new', 'Other failure', '', 'blocked', 'capability')")
            db.commit()
        before = self.board_bytes()
        for now in (2000, 2001, 4601, 8201):
            alerts.tick(self.root, now=now)
            self.assertEqual([], self.sent)
        self.assertEqual(before, self.board_bytes())
        # A revised ask gets a fresh label rather than a pusher reminder.
        self.assertFalse(alerts.resolve(self.root, 'D1')['can_reply'])
        self.assertTrue(alerts.resolve(self.root, 'D2')['can_reply'])

    def test_only_urgency_marked_technical_cards_are_pushed(self):
        alerts.tick(self.root, now=1000)
        self.assertEqual([], self.sent)
        with closing(sqlite3.connect(self.boards['two'])) as db:
            db.execute("UPDATE tasks SET body='Urgency: security\nGoal: Contain credential exposure.'")
            db.commit()
        alerts.tick(self.root, now=1001)
        self.assertEqual(1, len(self.sent))
        self.assertIn('Urgent security · two', self.sent[-1])
        self.assertIn('B1 · two', self.sent[-1])
        self.assertTrue(alerts.resolve(self.root, 'B1')['can_reply'])
        alerts.tick(self.root, now=1002)
        self.assertEqual(1, len(self.sent))
        with closing(sqlite3.connect(self.boards['two'])) as db:
            db.execute("UPDATE tasks SET body='Urgency: regression\nGoal: Contain credential exposure.'")
            db.commit()
        alerts.tick(self.root, now=1003)
        self.assertEqual(2, len(self.sent))
        self.assertIn('Urgent regression · two', self.sent[-1])
        # A decision card never becomes an urgent push: it needs the owner's
        # input, not the owner's interruption.
        with closing(sqlite3.connect(self.boards['one'])) as db:
            db.execute("UPDATE tasks SET body='Urgency: security\nASK: Approve repair?'")
            db.commit()
        alerts.tick(self.root, now=1004)
        self.assertEqual(2, len(self.sent))
        # Only the two named incidents qualify; a priority hint does not.
        with closing(sqlite3.connect(self.boards['two'])) as db:
            db.execute("UPDATE tasks SET body='Urgency: high\nGoal: Contain credential exposure.'")
            db.commit()
        alerts.tick(self.root, now=1005)
        self.assertEqual(2, len(self.sent))
        # The marker must be its own line, not prose mentioning it.
        with closing(sqlite3.connect(self.boards['two'])) as db:
            db.execute("UPDATE tasks SET body='Goal: note Urgency: security later.'")
            db.commit()
        alerts.tick(self.root, now=1006)
        self.assertEqual(2, len(self.sent))

    def test_failed_urgent_delivery_retries_without_losing_the_label(self):
        def fail_once(root, target, message):
            if 'Urgent security' in message:
                raise RuntimeError('offline')
            self.sent.append(message)
        with closing(sqlite3.connect(self.boards['two'])) as db:
            db.execute("UPDATE tasks SET body='Urgency: security\nGoal: Contain credential exposure.'")
            db.commit()
        with patch.object(alerts, 'send', fail_once):
            with self.assertRaises(RuntimeError):
                alerts.tick(self.root, now=1000)
        self.assertEqual([], self.sent)
        alerts.tick(self.root, now=1001)
        self.assertEqual(1, len(self.sent))
        self.assertIn('Urgent security · two', self.sent[0])
        self.assertTrue(alerts.resolve(self.root, 'B1')['can_reply'])

    def test_decision_labels_stay_replyable_without_a_push(self):
        alerts.tick(self.root, now=1000)
        self.assertEqual([], self.sent)
        self.assertTrue(alerts.resolve(self.root, 'D1')['can_reply'])
        self.assertIn('ASK: Approve repair?', alerts.details(self.root, 'D1'))
        with closing(sqlite3.connect(self.boards['one'])) as db:
            db.execute("UPDATE tasks SET body='ASK: Approve a different scope?'")
            db.commit()
        self.assertFalse(alerts.resolve(self.root, 'D1')['can_reply'])
        alerts.tick(self.root, now=1001)
        self.assertEqual([], self.sent)
        self.assertTrue(alerts.resolve(self.root, 'D2')['can_reply'])
        with closing(sqlite3.connect(self.boards['one'])) as db:
            db.execute("UPDATE tasks SET status='done'")
            db.commit()
        self.assertEqual('done', alerts.resolve(self.root, 'D2')['current']['status'])
        self.assertFalse(alerts.resolve(self.root, 'D2')['can_reply'])

    def test_technical_labels_need_delivery_before_recovery_instructions(self):
        alerts.tick(self.root, now=1000)
        self.assertEqual([], self.sent)
        self.assertFalse(alerts.resolve(self.root, 'B1')['can_reply'])
        alerts.tick(self.root, now=1001, force_blockers=True)
        self.assertEqual(1, len(self.sent))
        self.assertIn('Technical blockers: 1', self.sent[0])
        self.assertIn('B1 · two', self.sent[0])
        self.assertIn('Missing evidence', self.sent[0])
        self.assertTrue(alerts.resolve(self.root, 'B1')['can_reply'])
        self.assertIn('Evidence unavailable', alerts.details(self.root, 'B1'))
        with closing(sqlite3.connect(self.boards['two'])) as db:
            db.execute("UPDATE tasks SET block_kind='needs_input'")
            db.commit()
        self.assertFalse(alerts.resolve(self.root, 'B1')['can_reply'])
        alerts.tick(self.root, now=1002)
        self.assertEqual('two', alerts.resolve(self.root, 'D2')['board'])
        with closing(sqlite3.connect(self.boards['two'])) as db:
            db.execute("UPDATE tasks SET status='done'")
            db.commit()
        self.assertFalse(alerts.resolve(self.root, 'B1')['can_reply'])
        self.assertIn('done', alerts.details(self.root, 'B1'))

    def test_inline_choices_and_large_asks_are_not_rewritten_or_silently_cut(self):
        reason = ('Unavailable on Void. Choose a supervisor: A) XDG autostart + supervised loop (recommended), '
                  'B) turnstile/runit user service, or C) user crontab watchdog. Details: /receipt.md')
        with closing(sqlite3.connect(self.boards['one'])) as db:
            db.execute("UPDATE tasks SET body='Goal: Install approved supervision.'")
            db.execute('UPDATE task_events SET payload=?', (json.dumps({'reason': reason}),))
            db.commit()
        alerts.tick(self.root, now=1000)
        self.assertEqual([], self.sent)
        alerts.tick(self.root, now=1001, force_decisions=True)
        self.assertIn('A) XDG autostart + supervised loop (recommended)', self.sent[-1])
        self.assertIn('C) user crontab watchdog', self.sent[-1])
        self.assertNotIn('/receipt.md', self.sent[-1])
        self.assertNotIn('Approve', self.sent[-1])
        with closing(sqlite3.connect(self.boards['one'])) as db:
            db.execute('UPDATE tasks SET body=?', ('ASK: ' + 'Scope ' * 500 + '\n A) Accept\n B) Reject',))
            db.commit()
        alerts.tick(self.root, now=1002, force_decisions=True)
        self.assertIn('Details required before deciding', self.sent[-1])
        self.assertNotIn('A) Accept', self.sent[-1])
        self.assertFalse(alerts.resolve(self.root, 'D2')['compact_complete'])
        self.assertLess(len(self.sent[-1]), 500)

    def test_conflicting_card_and_block_reason_choices_require_details(self):
        with closing(sqlite3.connect(self.boards['one'])) as db:
            db.execute('UPDATE task_events SET payload=?', (json.dumps({'reason': 'Revised ask: A) Replace framework, B) Defer'}),))
            db.commit()
        alerts.tick(self.root, now=1000, force_decisions=True)
        self.assertIn('Details required before deciding', self.sent[0])
        self.assertFalse(alerts.resolve(self.root, 'D1')['compact_complete'])

    def test_worker_diagnostics_fill_empty_legacy_block_reasons(self):
        with closing(sqlite3.connect(self.boards['two'])) as db:
            db.execute('ALTER TABLE tasks ADD COLUMN last_failure_error TEXT')
            db.execute("UPDATE tasks SET last_failure_error='model endpoint unavailable'")
            db.execute('DELETE FROM task_events')
            db.commit()
        alerts.tick(self.root, now=1000)
        self.assertEqual([], self.sent)
        alerts.tick(self.root, now=1001, force_blockers=True)
        self.assertIn('1 worker failures', self.sent[-1])
        self.assertIn('model endpoint unavailable', alerts.details(self.root, 'blockers'))

    def test_operator_only_cleanup_is_not_reported_as_missing_evidence(self):
        with closing(sqlite3.connect(self.boards['two'])) as db:
            db.execute("UPDATE tasks SET title='Record cleanup', body='Operator-only: cleanup requires stat receipts from the worktree.'")
            db.execute('UPDATE task_events SET payload=?', (json.dumps({'reason': 'initial_status'}),))
            db.commit()
        alerts.tick(self.root, now=1000, force_blockers=True)
        self.assertIn('Blocked: Operator recovery needed', self.sent[-1])
        self.assertNotIn('Missing evidence', self.sent[-1])

    def test_reclassifying_a_card_moves_it_between_the_two_labels(self):
        alerts.tick(self.root, now=1000)
        with closing(sqlite3.connect(self.boards['two'])) as db:
            db.execute("UPDATE tasks SET block_kind='needs_input'")
            db.commit()
        alerts.tick(self.root, now=1001)
        self.assertEqual('two', alerts.resolve(self.root, 'D2')['board'])
        self.assertFalse(alerts.resolve(self.root, 'B1')['can_reply'])
        self.assertEqual([], self.sent)
        with closing(sqlite3.connect(self.boards['two'])) as db:
            db.execute("UPDATE tasks SET block_kind='capability'")
            db.commit()
        self.assertEqual('two', alerts.resolve(self.root, 'B1')['board'])
        self.assertFalse(alerts.resolve(self.root, 'D2')['can_reply'])

    def test_pulls_batch_every_blocker_and_keep_their_labels(self):
        with closing(sqlite3.connect(self.boards['two'])) as db:
            for number in range(20):
                db.execute('INSERT INTO tasks VALUES (?, ?, ?, ?, ?)', (f't_extra_{number}', f'Recover worker {number}', '', 'blocked', 'capability'))
            db.commit()
        alerts.tick(self.root, now=1000)
        self.assertEqual([], self.sent)
        alerts.tick(self.root, now=1001, force_blockers=True)
        technical = [m for m in self.sent if m.startswith('Technical blockers:')]
        self.assertGreater(len(technical), 1)
        self.assertTrue(all(len(m) <= 1600 for m in technical))
        for number in range(1, 22):
            self.assertIn(f'B{number} · two', '\n'.join(technical))
            self.assertTrue(alerts.resolve(self.root, f'B{number}')['can_reply'])
        sent = len(self.sent)
        alerts.tick(self.root, now=1002)
        self.assertEqual(sent, len(self.sent))
        alerts.tick(self.root, now=1003, force_blockers=True)
        self.assertEqual(sent + len(technical), len(self.sent))
        self.assertEqual('t_12345678', alerts.resolve(self.root, 'B1')['task_id'])
        with patch.dict(os.environ, {'HERMES_KANBAN_TASK': 't_worker'}):
            with self.assertRaises(PermissionError):
                alerts.tick(self.root, force_blockers=True)
        with patch.dict(os.environ, {'HERMES_DELEGATED_CHILD_CONTEXT': '1'}):
            with self.assertRaises(PermissionError):
                alerts.tick(self.root, force_decisions=True)

    def test_wrapped_choices_preserve_consequences_and_batches_fit_phone(self):
        body = ('ASK: Choose a recovery mechanism\n for this host?\n'
                ' A) Restore the worker\n  with existing credentials\n'
                ' B) Pause work\n  until capacity returns\n'
                'NEEDED FROM YOU: choose A or B\nContext: excluded from the compact ask')
        with closing(sqlite3.connect(self.boards['one'])) as db:
            db.execute('UPDATE tasks SET body=?', (body,))
            for number in range(12):
                db.execute('INSERT INTO tasks VALUES (?, ?, ?, ?, ?)', (f't_new_{number}', 'Recover worker', body, 'blocked', 'needs_input'))
            db.commit()
        alerts.tick(self.root, now=1000)
        self.assertEqual([], self.sent)
        alerts.tick(self.root, now=1001, force_decisions=True)
        decisions = [m for m in self.sent if m.startswith('Decision inbox')]
        self.assertGreater(len(decisions), 1)
        self.assertTrue(all(len(m) <= 1600 for m in decisions))
        self.assertIn('Choose a recovery mechanism for this host?', decisions[0])
        self.assertIn('A) Restore the worker with existing credentials', decisions[0])
        self.assertIn('B) Pause work until capacity returns', decisions[0])
        self.assertNotIn('Context:', decisions[0])
        # An explicit pull with nothing waiting answers instead of going quiet.
        with closing(sqlite3.connect(self.boards['one'])) as db:
            db.execute("UPDATE tasks SET status='done' WHERE id='t_12345678'")
            for number in range(12):
                db.execute("UPDATE tasks SET status='done' WHERE id=?", (f't_new_{number}',))
            db.commit()
        alerts.tick(self.root, now=1002, force_decisions=True)
        self.assertIn('No decisions are waiting.', self.sent[-1])

    def test_details_and_resolve_are_read_only_even_in_fenced_workers(self):
        alerts.tick(self.root, now=1000)
        paths = list(self.root.glob('kanban/boards/*/kanban.db')) + [self.root / 'kanban/owner-alerts/inbox.json']
        before = {p: p.read_bytes() for p in paths}
        with patch.dict(os.environ, {'HERMES_DELEGATED_CHILD_CONTEXT': '1'}):
            self.assertIn('ASK: Approve repair?', alerts.details(self.root, 'D1'))
            self.assertIn('Evidence unavailable', alerts.details(self.root, 'blockers'))
            self.assertIn('B1 · two:t_12345678', alerts.details(self.root, 'blockers'))
            self.assertTrue(alerts.resolve(self.root, 'D1')['can_reply'])
            self.assertEqual('technical', alerts.resolve(self.root, 'B1')['kind'])
            # Never delivered, so recovery instructions through it are not honoured.
            self.assertFalse(alerts.resolve(self.root, 'B1')['can_reply'])
            self.assertIn('Evidence unavailable', alerts.details(self.root, 'B1'))
        self.assertEqual(before, {p: p.read_bytes() for p in paths})
        with self.assertRaises(ValueError):
            alerts.resolve(self.root, 'D999')

    def test_old_count_only_state_upgrades_without_pushing(self):
        alerts.tick(self.root, now=1000)
        path = self.root / 'kanban/owner-alerts/inbox.json'
        old = json.loads(path.read_text())
        old.pop('blockers', None)
        old.pop('next_blocker', None)
        old['delivery']['simplex:3'].pop('technical_format', None)
        path.write_text(json.dumps(old))
        alerts.tick(self.root, now=1001)
        self.assertEqual([], self.sent)
        self.assertEqual('two', alerts.resolve(self.root, 'B1')['board'])
        self.assertEqual(('two', 't_12345678'), tuple(alerts.resolve(self.root, 'B1')[k] for k in ('board', 'task_id')))

    def test_partial_board_reads_are_never_delivered_as_complete(self):
        original = alerts.snapshot

        def broken(root, task_id=None):
            if root.parent.name == 'two':
                raise sqlite3.OperationalError('database is locked')
            return original(root, task_id)

        with closing(sqlite3.connect(self.boards['two'])) as db:
            db.execute("UPDATE tasks SET body='Urgency: security\nGoal: Contain credential exposure.'")
            db.commit()
        with patch.object(alerts, 'snapshot', broken):
            with self.assertRaises(RuntimeError):
                alerts.tick(self.root, now=1000)
            self.assertEqual([], self.sent)
            with self.assertRaises(RuntimeError):
                alerts.tick(self.root, now=1001, force_blockers=True)
            with self.assertRaises(RuntimeError):
                alerts.tick(self.root, now=1002, force_decisions=True)
        self.assertEqual([], self.sent)
        alerts.tick(self.root, now=1003)
        self.assertEqual(1, len(self.sent))
        self.assertIn('Urgent security · two', self.sent[-1])

    def test_corrupt_label_state_fails_closed(self):
        alerts.tick(self.root, now=1000)
        for value in ['{broken', '[]', '{"version":1,"next_label":0,"decisions":{},"delivery":{}}',
                      '{"version":1,"next_label":2,"decisions":{"D1":null},"delivery":{}}',
                      '{"version":1,"next_label":1,"decisions":{},"delivery":{"simplex:3":{}}}']:
            with self.subTest(value=value):
                (self.root / 'kanban/owner-alerts/inbox.json').write_text(value)
                with self.assertRaises(ValueError):
                    alerts.tick(self.root)
        self.assertEqual([], self.sent)

    def test_cli_resolve_and_details_use_persisted_labels_in_fenced_environment(self):
        alerts.tick(self.root, now=1000)
        environment = {**os.environ, 'HERMES_ROOT': str(self.root), 'HERMES_DELEGATED_CHILD_CONTEXT': '1'}
        result = subprocess.run([sys.executable, '-B', alerts.__file__, '--resolve', 'D1'], env=environment, text=True, capture_output=True, check=True)
        self.assertEqual('one', json.loads(result.stdout)['board'])
        self.assertTrue(json.loads(result.stdout)['can_reply'])
        result = subprocess.run([sys.executable, '-B', alerts.__file__, '--resolve', 'B1'], env=environment, text=True, capture_output=True, check=True)
        self.assertEqual('technical', json.loads(result.stdout)['kind'])
        self.assertFalse(json.loads(result.stdout)['can_reply'])
        result = subprocess.run([sys.executable, '-B', alerts.__file__, '--details', 'two:t_12345678'], env=environment, text=True, capture_output=True, check=True)
        self.assertIn('Evidence unavailable', result.stdout)
        for flag in ['--send-blockers', '--send-decisions']:
            result = subprocess.run([sys.executable, '-B', alerts.__file__, flag], env=environment, text=True, capture_output=True)
            self.assertEqual(2, result.returncode)
            self.assertIn('only from the operator or no-agent cron', result.stderr)
        self.assertEqual([], self.sent)

    def test_dry_run_and_fenced_workers_do_not_send(self):
        with closing(sqlite3.connect(self.boards['two'])) as db:
            db.execute("UPDATE tasks SET body='Urgency: security\nGoal: Contain credential exposure.'")
            db.commit()
        with redirect_stdout(StringIO()) as preview:
            alerts.tick(self.root, dry_run=True)
        self.assertIn('Urgent security · two', preview.getvalue())
        self.assertFalse(self.sent)
        self.assertFalse((self.root / 'kanban/owner-alerts').exists())
        with patch.dict(os.environ, {'HERMES_DELEGATED_CHILD_CONTEXT': '1'}):
            with self.assertRaises(PermissionError):
                alerts.tick(self.root)

    def test_authentication_configuration_fails_closed(self):
        for line in ['SIMPLEX_ALLOW_ALL_USERS=true', 'SIMPLEX_GROUP_ALLOWED=*', 'SIMPLEX_HOME_CHANNEL=4', 'SIMPLEX_WS_URL=ws://example.org:5225']:
            with self.subTest(line=line):
                original = self.env.read_text()
                self.env.write_text(original + line + '\n')
                with self.assertRaises(ValueError):
                    alerts.tick(self.root)
                self.assertFalse(self.sent)
                self.env.write_text(original)

    def test_transport_requires_success_acknowledgment(self):
        for stdout in ['{"success":false}', '{"skipped":true}', '{"error":"offline"}']:
            with patch.object(alerts.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, stdout, '')):
                with self.assertRaises(RuntimeError):
                    self.real_send(self.root, 'simplex:3', 'test')

    def test_install_preserves_policy_and_job_state(self):
        soul = self.env.parent / 'SOUL.md'
        soul.write_text('# Head\nKeep existing deploy policy.\n')
        cron = self.root / 'cron/jobs.json'
        cron.parent.mkdir()
        job = {'name': alerts.JOB, 'script': 'kanban-owner-alerts.py', 'no_agent': True,
               'schedule': {'minutes': 1}, 'enabled': False}
        cron.write_text(json.dumps({'jobs': [job]}))
        alerts.install(self.root)
        installed = soul.read_text()
        self.assertIn('Keep existing deploy policy.', installed)
        self.assertIn('kanban_comment', installed)
        alerts.install(self.root)
        self.assertEqual(installed, soul.read_text())
        soul.write_text(installed + '\n## Another policy\nPreserve this later addition.\n')
        alerts.install(self.root)
        self.assertIn('Preserve this later addition.', soul.read_text())
        self.assertFalse(json.loads(cron.read_text())['jobs'][0]['enabled'])
        self.assertEqual(1, len(list((self.root / 'backups/owner-alerts').glob('*.md'))))

unittest.main(argv=['alerts'], verbosity=2)
PY
