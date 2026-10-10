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
                db.executescript('CREATE TABLE tasks (id TEXT, title TEXT, body TEXT, status TEXT, block_kind TEXT); CREATE TABLE task_events (id INTEGER, task_id TEXT, kind TEXT, payload TEXT); CREATE TABLE task_comments (id INTEGER PRIMARY KEY AUTOINCREMENT, task_id TEXT, author TEXT, body TEXT, created_at INTEGER);')
                db.execute('INSERT INTO tasks VALUES (?, ?, ?, ?, ?)', ('t_12345678', 'Decide repair', 'ASK: Approve repair?\n A) Approve\n B) Reject', 'blocked', 'needs_input' if board == 'one' else 'capability'))
                db.execute('INSERT INTO task_events VALUES (1, ?, ?, ?)', ('t_12345678', 'blocked', json.dumps({'reason': 'Need a decision' if board == 'one' else 'Evidence unavailable'})))
                db.commit()
        self.boards = {name: self.root / 'kanban/boards' / name / 'kanban.db' for name in ('one', 'two')}
        self.sent = []
        self.real_send = alerts.send
        self.sender = patch.object(alerts, 'send', lambda root, target, message: self.sent.append(message))
        self.sender.start()
        self.addCleanup(self.sender.stop)

    def mark(self, board, body):
        with closing(sqlite3.connect(self.boards[board])) as db:
            db.execute('UPDATE tasks SET body=?', (body,))
            db.commit()

    def board_bytes(self):
        return {name: path.read_bytes() for name, path in self.boards.items()}

    def test_only_hard_blockers_reach_the_owner(self):
        alerts.tick(self.root, now=1000)
        self.assertEqual(1, len(self.sent))
        self.assertTrue(self.sent[0].startswith('*Hard Blocker*\n'))
        self.assertIn('D1 · one', self.sent[0])
        self.assertIn('Approve repair?', self.sent[0])
        self.assertNotIn('two', self.sent[0])
        alerts.tick(self.root, now=1001)
        self.assertEqual(1, len(self.sent))
        # Prose that merely mentions the phrase is not a marker.
        self.mark('two', 'Notes: this is not a Hard Blocker yet.')
        alerts.tick(self.root, now=1002)
        self.assertEqual(1, len(self.sent))
        # The retired urgency vocabulary no longer alerts.
        self.mark('two', 'Urgency: security\nGoal: Contain exposure.')
        alerts.tick(self.root, now=1003)
        self.assertEqual(1, len(self.sent))
        self.assertFalse(alerts.resolve(self.root, 'B1')['can_reply'])
        # A standalone marker makes the card a Hard Blocker: it joins the D
        # category and reaches the owner.
        self.mark('two', 'Hard Blocker: needs the owner key\nGoal: Sign the release.')
        alerts.tick(self.root, now=1004)
        self.assertEqual(2, len(self.sent))
        self.assertIn('*Hard Blocker*\n', self.sent[1])
        self.assertIn('D2 · two', self.sent[1])
        self.assertIn('needs the owner key', self.sent[1])
        self.assertTrue(alerts.resolve(self.root, 'D2')['can_reply'])
        # The marker line is case-insensitive; a revision repushes as a new D.
        self.mark('two', 'hard blocker\nGoal: Sign the release.')
        alerts.tick(self.root, now=1006)
        self.assertEqual(3, len(self.sent))
        self.assertIn('D3 · two', self.sent[-1])

    def test_format_shows_description_and_recommendation(self):
        with closing(sqlite3.connect(self.boards['one'])) as db:
            db.execute("UPDATE tasks SET body=?",
                       ('ASK: Which owner profile should own the adapter?\n'
                        ' A) head-coordinator — route replies through the coordinator only\n'
                        ' B) gateway — **keep** the existing profile as owner\n'
                        'NEEDED FROM YOU: choose A or B\n'
                        'IF UNANSWERED: adapter rollout stays blocked\n'
                        'Context: Two lanes share the same paired endpoint. This splits '
                        'handling of authenticated owner traffic.',))
            db.commit()
        alerts.tick(self.root, now=1000)
        message = self.sent[0]
        self.assertIn('D1 · one', message)
        self.assertIn('Blocking: Which owner profile should own the adapter?', message)
        self.assertIn('Why owner: If you do not act, adapter rollout stays blocked.', message)
        self.assertIn('Recommended: A) head-coordinator — route replies through the coordinator only', message)
        self.assertIn('Alternatives:', message)
        # GitHub emphasis is converted to the markup SimpleX actually renders.
        self.assertIn('B) gateway — *keep* the existing profile as owner', message)
        self.assertNotIn('**keep**', message)

    def test_needs_input_without_ask_reports_three_sentences(self):
        # A needs_input card whose body is work-shaped (Goal/Change), not a gate
        # (no ASK/options), used to reach the phone as a bare "Details required"
        # stub. It must now carry what/why/recommended in full.
        reason = 'Upstream review rejected the head; a corrected-source verdict is the prerequisite.'
        with closing(sqlite3.connect(self.boards['one'])) as db:
            db.execute("UPDATE tasks SET body='Goal: Activate the accepted inbox.\\n"
                       "Change: Install only the reviewed head.'")
            db.execute('UPDATE task_events SET payload=?', (json.dumps({'reason': reason}),))
            db.commit()
        alerts.tick(self.root, now=1000)
        message = self.sent[0]
        self.assertIn('Blocking: Upstream review rejected the head;', message)
        self.assertIn('Why owner:', message)
        self.assertIn('Recommended:', message)
        self.assertNotIn('Details required before deciding', message)
        self.assertTrue(alerts.resolve(self.root, 'D1')['compact_complete'])

    def test_plain_summary_comment_overrides_jargon_body(self):
        # The card body and block reason are internal jargon; an agent posts a
        # plain-language summary as a comment and the phone message uses it.
        with closing(sqlite3.connect(self.boards['one'])) as db:
            db.execute("UPDATE tasks SET body='Goal: fix t_abc across the worktree.'")
            db.execute('UPDATE task_events SET payload=?',
                       (json.dumps({'reason': 'review t_deadbeef rejected 1e299daf6464c8b6a02080a5d01223f3fe90766c'}),))
            db.execute("INSERT INTO task_comments (task_id, author, body, created_at) VALUES "
                       "('t_12345678','head-coordinator',?,1)",
                       ('Blocking: A required safety check was removed and nobody re-approved it.\n'
                        'Why owner: Only you can approve restoring the check.\n'
                        'Unblock: Tell us to restore the check, or to leave it out.',))
            db.commit()
        alerts.tick(self.root, now=1000)
        message = self.sent[0]
        self.assertIn('Blocking: A required safety check was removed', message)
        self.assertIn('Why owner: Only you can approve restoring the check.', message)
        self.assertIn('Recommended: Tell us to restore the check', message)
        self.assertNotIn('t_deadbeef', message)
        self.assertNotIn('worktree', message)

    def test_simplex_markdown_matches_the_messenger(self):
        self.assertEqual('*bold*', alerts.simplex_markdown('**bold**'))
        self.assertEqual('_italic_', alerts.simplex_markdown('__italic__'))
        self.assertEqual('~strike~', alerts.simplex_markdown('~~strike~~'))
        self.assertEqual('a *b* and _c_', alerts.simplex_markdown('a **b** and __c__'))
        self.assertEqual('*Hard Blocker*', alerts.simplex_markdown('**Hard Blocker**'))

    def test_decision_hard_blockers_repush_on_revision_and_stay_replyable(self):
        alerts.tick(self.root, now=1000)
        self.assertEqual(1, len(self.sent))
        self.assertTrue(alerts.resolve(self.root, 'D1')['can_reply'])
        self.assertIn('ASK: Approve repair?', alerts.details(self.root, 'D1'))
        with closing(sqlite3.connect(self.boards['one'])) as db:
            db.execute("UPDATE tasks SET body='ASK: Approve a revised plan?'")
            db.commit()
        alerts.tick(self.root, now=1001)
        self.assertEqual(2, len(self.sent))
        self.assertIn('D2 · one', self.sent[1])
        self.assertFalse(alerts.resolve(self.root, 'D1')['can_reply'])
        self.assertTrue(alerts.resolve(self.root, 'D2')['can_reply'])
        with closing(sqlite3.connect(self.boards['one'])) as db:
            db.execute("UPDATE tasks SET status='done'")
            db.commit()
        alerts.tick(self.root, now=1002)
        self.assertEqual(2, len(self.sent))
        self.assertFalse(alerts.resolve(self.root, 'D2')['can_reply'])

    def test_failed_decision_delivery_retries(self):
        attempts = []

        def fail_once(root, target, message):
            attempts.append(message)
            if len(attempts) == 1:
                raise RuntimeError('offline')
            self.sent.append(message)
        with patch.object(alerts, 'send', fail_once):
            with self.assertRaises(RuntimeError):
                alerts.tick(self.root, now=1000)
            self.assertFalse(self.sent)
            alerts.tick(self.root, now=1001)
        self.assertEqual(1, len(self.sent))
        self.assertIn('D1 · one', self.sent[0])
        self.assertTrue(alerts.resolve(self.root, 'D1')['can_reply'])

    def test_technical_labels_are_terminal_diagnostics_only(self):
        alerts.tick(self.root, now=1000)
        self.assertFalse(alerts.resolve(self.root, 'B1')['can_reply'])
        listed = alerts.details(self.root, 'blockers')
        self.assertIn('B1 · two:t_12345678', listed)
        self.assertIn('Evidence unavailable', listed)
        # A technical label never becomes replyable and never reaches the phone.
        alerts.tick(self.root, now=1001)
        self.assertEqual(1, len(self.sent))
        self.assertFalse(alerts.resolve(self.root, 'B1')['can_reply'])
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
        self.assertIn('A) XDG autostart + supervised loop (recommended)', self.sent[0])
        self.assertIn('C) user crontab watchdog', self.sent[0])
        self.assertNotIn('/receipt.md', self.sent[0])
        self.assertNotIn('Approve', self.sent[0])
        with closing(sqlite3.connect(self.boards['one'])) as db:
            db.execute('UPDATE tasks SET body=?', ('ASK: ' + 'Scope ' * 500 + '\n A) Accept\n B) Reject',))
            db.commit()
        alerts.tick(self.root, now=1001)
        self.assertIn('Details required before deciding', self.sent[-1])
        self.assertNotIn('A) Accept', self.sent[-1])
        self.assertFalse(alerts.resolve(self.root, 'D2')['compact_complete'])
        self.assertLess(len(self.sent[-1]), 500)

    def test_conflicting_card_and_block_reason_choices_require_details(self):
        with closing(sqlite3.connect(self.boards['one'])) as db:
            db.execute('UPDATE task_events SET payload=?', (json.dumps({'reason': 'Revised ask: A) Replace framework, B) Defer'}),))
            db.commit()
        alerts.tick(self.root, now=1000)
        self.assertIn('Details required before deciding', self.sent[0])
        self.assertFalse(alerts.resolve(self.root, 'D1')['compact_complete'])

    def test_worker_diagnostics_fill_empty_legacy_block_reasons(self):
        with closing(sqlite3.connect(self.boards['two'])) as db:
            db.execute('ALTER TABLE tasks ADD COLUMN last_failure_error TEXT')
            db.execute("UPDATE tasks SET last_failure_error='model endpoint unavailable'")
            db.execute('DELETE FROM task_events')
            db.commit()
        self.assertIn('model endpoint unavailable', alerts.details(self.root, 'blockers'))

    def test_operator_only_cleanup_is_not_reported_as_missing_evidence(self):
        with closing(sqlite3.connect(self.boards['two'])) as db:
            db.execute("UPDATE tasks SET title='Record cleanup', body='Operator-only: cleanup requires stat receipts from the worktree.'")
            db.execute('UPDATE task_events SET payload=?', (json.dumps({'reason': 'initial_status'}),))
            db.commit()
        alerts.tick(self.root, now=1000)
        shown = alerts.details(self.root, 'B1')
        self.assertIn('Blocked: Operator recovery needed', shown)
        self.assertNotIn('Missing evidence', shown)

    def test_reclassifying_a_card_moves_it_between_the_two_labels(self):
        alerts.tick(self.root, now=1000)
        self.assertFalse(alerts.resolve(self.root, 'B1')['can_reply'])
        with closing(sqlite3.connect(self.boards['two'])) as db:
            db.execute("UPDATE tasks SET block_kind='needs_input'")
            db.commit()
        alerts.tick(self.root, now=1001)
        self.assertEqual('two', alerts.resolve(self.root, 'D2')['board'])
        self.assertFalse(alerts.resolve(self.root, 'B1')['can_reply'])
        with closing(sqlite3.connect(self.boards['two'])) as db:
            db.execute("UPDATE tasks SET block_kind='capability'")
            db.commit()
        self.assertEqual('two', alerts.resolve(self.root, 'B1')['board'])
        self.assertFalse(alerts.resolve(self.root, 'D2')['can_reply'])

    def test_technical_labels_persist_but_never_send(self):
        with closing(sqlite3.connect(self.boards['two'])) as db:
            for number in range(20):
                db.execute('INSERT INTO tasks VALUES (?, ?, ?, ?, ?)', (f't_extra_{number}', f'Recover worker {number}', '', 'blocked', 'capability'))
            db.commit()
        alerts.tick(self.root, now=1000)
        self.assertEqual(1, len(self.sent))  # only the decision
        listed = alerts.details(self.root, 'blockers')
        for number in range(1, 22):
            self.assertIn(f'B{number} · two:t_', listed)
            self.assertFalse(alerts.resolve(self.root, f'B{number}')['can_reply'])
        self.assertEqual('t_12345678', alerts.resolve(self.root, 'B1')['task_id'])
        alerts.tick(self.root, now=1001)
        self.assertEqual(1, len(self.sent))
        with patch.dict(os.environ, {'HERMES_KANBAN_TASK': 't_worker'}):
            with self.assertRaises(PermissionError):
                alerts.tick(self.root)
        with patch.dict(os.environ, {'HERMES_DELEGATED_CHILD_CONTEXT': '1'}):
            with self.assertRaises(PermissionError):
                alerts.tick(self.root, force_decisions=True)

    def test_wrapped_choices_preserve_consequences_and_batches_fit_phone(self):
        body = ('ASK: Choose a recovery mechanism\n for this host?\n'
                ' A) Restore the worker\n  with existing credentials\n'
                ' B) Pause work\n  until capacity returns\n'
                'NEEDED FROM YOU: choose A or B\nContext: The worker is down and queued work is stuck.')
        with closing(sqlite3.connect(self.boards['one'])) as db:
            db.execute('UPDATE tasks SET body=?', (body,))
            for number in range(12):
                db.execute('INSERT INTO tasks VALUES (?, ?, ?, ?, ?)', (f't_new_{number}', 'Recover worker', body, 'blocked', 'needs_input'))
            db.commit()
        alerts.tick(self.root, now=1000)
        decisions = [m for m in self.sent if m.startswith('*Hard Blocker*')]
        self.assertGreater(len(decisions), 1)
        self.assertTrue(all(len(m) <= 1600 for m in decisions))
        self.assertIn('Choose a recovery mechanism for this host?', decisions[0])
        self.assertIn('Why owner: This needs you to choose A or B.', decisions[0])
        self.assertIn('Recommended: A) Restore the worker with existing credentials', decisions[0])
        self.assertIn('Alternatives:', decisions[0])
        self.assertIn('B) Pause work until capacity returns', decisions[0])
        self.assertNotIn('Context:', decisions[0])
        # An explicit pull with nothing waiting answers instead of going quiet.
        with closing(sqlite3.connect(self.boards['one'])) as db:
            db.execute("UPDATE tasks SET status='done'")
            db.commit()
        alerts.tick(self.root, now=1001, force_decisions=True)
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
        self.assertEqual(before, {p: p.read_bytes() for p in paths})
        with self.assertRaises(ValueError):
            alerts.resolve(self.root, 'D999')

    def test_old_count_only_state_upgrades_without_repushing(self):
        alerts.tick(self.root, now=1000)
        self.assertEqual(1, len(self.sent))
        path = self.root / 'kanban/owner-alerts/inbox.json'
        old = json.loads(path.read_text())
        old.pop('blockers', None)
        old.pop('next_blocker', None)
        old['delivery']['simplex:3'].pop('technical_format', None)
        path.write_text(json.dumps(old))
        alerts.tick(self.root, now=1001)
        self.assertEqual(1, len(self.sent))
        self.assertEqual('two', alerts.resolve(self.root, 'B1')['board'])
        self.assertEqual(('two', 't_12345678'), tuple(alerts.resolve(self.root, 'B1')[k] for k in ('board', 'task_id')))

    def test_partial_board_reads_block_pulls_but_not_single_alerts(self):
        original = alerts.snapshot

        def broken(root, task_id=None):
            if root.parent.name == 'two':
                raise sqlite3.OperationalError('database is locked')
            return original(root, task_id)

        with patch.object(alerts, 'snapshot', broken):
            with self.assertRaises(RuntimeError):
                alerts.tick(self.root, now=1000)
            self.assertEqual(1, len(self.sent))
            self.assertIn('D1 · one', self.sent[0])
            with self.assertRaises(RuntimeError):
                alerts.tick(self.root, now=1001, force_decisions=True)
        self.assertEqual(1, len(self.sent))

    def test_delivery_state_migrates_the_retired_urgent_key(self):
        alerts.tick(self.root, now=1000)
        path = self.root / 'kanban/owner-alerts/inbox.json'
        state = json.loads(path.read_text())
        delivery = state['delivery']['simplex:3']
        delivery.pop('hard_blocker', None)
        delivery['urgent'] = {'one:t_12345678': 'abc'}
        path.write_text(json.dumps(state))
        alerts.tick(self.root, now=1001)
        migrated = json.loads(path.read_text())['delivery']['simplex:3']
        self.assertNotIn('urgent', migrated)
        self.assertEqual({'one:t_12345678': 'abc'}, migrated['hard_blocker'])

    def test_corrupt_label_state_fails_closed(self):
        alerts.tick(self.root, now=1000)
        for value in ['{broken', '[]', '{"version":1,"next_label":0,"decisions":{},"delivery":{}}',
                      '{"version":1,"next_label":2,"decisions":{"D1":null},"delivery":{}}',
                      '{"version":1,"next_label":1,"decisions":{},"delivery":{"simplex:3":{}}}']:
            with self.subTest(value=value):
                (self.root / 'kanban/owner-alerts/inbox.json').write_text(value)
                with self.assertRaises(ValueError):
                    alerts.tick(self.root)
        self.assertEqual(1, len(self.sent))

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
        for flag in ['--send-decisions']:
            result = subprocess.run([sys.executable, '-B', alerts.__file__, flag], env=environment, text=True, capture_output=True)
            self.assertEqual(2, result.returncode)
            self.assertIn('only from the operator or no-agent cron', result.stderr)
        result = subprocess.run([sys.executable, '-B', alerts.__file__, '--send-blockers'], env=environment, text=True, capture_output=True)
        self.assertEqual(2, result.returncode)
        self.assertIn('unrecognized arguments', result.stderr)
        self.assertEqual(1, len(self.sent))

    def test_dry_run_and_fenced_workers_do_not_send(self):
        self.mark('two', 'Hard Blocker\nGoal: Sign.')
        with redirect_stdout(StringIO()) as preview:
            alerts.tick(self.root, dry_run=True)
        self.assertIn('Hard Blocker', preview.getvalue())
        self.assertIn('D1 · one', preview.getvalue())
        self.assertIn('D2 · two', preview.getvalue())
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
