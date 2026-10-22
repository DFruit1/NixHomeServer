#!/usr/bin/env bash
set -euo pipefail
TESTS_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Detach from any inherited dispatcher worker identity and credential fallback
# before the fixture runs.
#
# This suite drives kanban-owner-alerts.py's send path (`alerts.tick`) directly,
# and that path refuses a worker context outright: with HERMES_DELEGATED_CHILD_CONTEXT
# or HERMES_KANBAN_TASK set it raises PermissionError ("Owner alerts run only from
# the operator or no-agent cron", kanban-owner-alerts.py:487). The operator-context
# tests are the point of this file, so those pins must be gone before it runs.
#
# This is not a fence bypass. The suite's own negative controls set the same
# variables explicitly with patch.dict / subprocess env and still assert the
# refusal, the read-only paths and the check-only exit code, so every assertion
# about the fence survives; untrusting the ambient environment only decides which
# of the two contexts the harness itself runs in.
#
# HERMES_KANBAN_DB / HERMES_KANBAN_BOARD are the hermes CLI's board-resolution
# pins and can outrank an explicit --board (kanban_db._explicit_board_intent_pinned),
# so an inherited pin could resolve a call onto the live operator board.
# OPENCODE_API_KEY is a live credential fallback the suite never supplies. These
# are worker-identity and credential-fallback settings, not locations or fixtures,
# so dropping them can only reach this test's own mktemp tree.
unset HERMES_DELEGATED_CHILD_CONTEXT HERMES_KANBAN_TASK HERMES_KANBAN_DB \
  HERMES_KANBAN_BOARD OPENCODE_API_KEY
for pin in HERMES_DELEGATED_CHILD_CONTEXT HERMES_KANBAN_TASK HERMES_KANBAN_DB \
  HERMES_KANBAN_BOARD OPENCODE_API_KEY; do
  [[ -z "${!pin:-}" ]] ||
    { echo "❌ $pin is still set; the fixture is not isolated from the ambient worker environment" >&2; exit 1; }
done

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

sys.path.insert(0, str(Path(sys.argv[1]) / 'scripts/hermes'))
spec = importlib.util.spec_from_file_location('alerts', Path(sys.argv[1]) / 'scripts/hermes/kanban-owner-alerts.py')
alerts = importlib.util.module_from_spec(spec)
spec.loader.exec_module(alerts)
writer_spec = importlib.util.spec_from_file_location('writer', Path(sys.argv[1]) / 'scripts/hermes/owner-blocker-authoring-guard.py')
writer = importlib.util.module_from_spec(writer_spec)
writer_spec.loader.exec_module(writer)


REPAIR_SUMMARY = ('Blocking: Repair is waiting for your approval. Nothing proceeds until you decide.\n'
                  'Why owner: The repair changes a setting you previously chose. Only you can confirm it is wanted.\n'
                  'Unblock: Approve the repair or keep the current setting.')


class AlertsTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='nixhomeserver-owner-alerts-')
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
                db.executescript('CREATE TABLE tasks (id TEXT, title TEXT, body TEXT, status TEXT, block_kind TEXT, created_by TEXT DEFAULT "head-coordinator"); CREATE TABLE task_events (id INTEGER, task_id TEXT, kind TEXT, payload TEXT, created_at INTEGER DEFAULT 0); CREATE TABLE task_comments (id INTEGER PRIMARY KEY AUTOINCREMENT, task_id TEXT, author TEXT, body TEXT, created_at INTEGER);')
                db.execute('INSERT INTO tasks (id,title,body,status,block_kind) VALUES (?, ?, ?, ?, ?)', ('t_12345678', 'Decide repair', 'ASK: Approve repair?\n A) Approve\n B) Reject\n' + REPAIR_SUMMARY, 'blocked', 'needs_input' if board == 'one' else 'capability'))
                db.execute('INSERT INTO task_events (id,task_id,kind,payload) VALUES (1, ?, ?, ?)', ('t_12345678', 'blocked', json.dumps({'reason': 'Need a decision' if board == 'one' else 'Evidence unavailable'})))
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

    def test_answered_owner_hold_is_not_reported_as_an_open_ask(self):
        # A supplier=owner reason lives on an immutable block event. Once the
        # owner answers, that text is stale; reporting it as an open ask tells
        # the coordinator to author a gate the owner already answered, which
        # pages the owner twice for one decision.
        with closing(sqlite3.connect(self.boards['one'])) as db:
            db.execute("INSERT INTO tasks (id,title,body,status,block_kind) VALUES (?,?,?,?,?)",
                       ('t_ownerhold', 'Route approval', 'Goal: route the approval', 'todo', None))
            db.execute("INSERT INTO task_events VALUES (?,?,?,?,?)",
                       (10, 't_ownerhold', 'blocked',
                        json.dumps({'reason': 'Input supplier: owner\nBlocking: x'}), 0))
            db.commit()
        problems = alerts.check_ownership(self.root)
        self.assertTrue(any('t_ownerhold' in p and 'author the ASK' in p for p in problems),
                        problems)
        with closing(sqlite3.connect(self.boards['one'])) as db:
            db.execute("INSERT INTO task_comments (task_id,author,body,created_at) VALUES (?,?,?,?)",
                       ('t_ownerhold', 'owner', 'Owner decision: A', 2))
            db.commit()
        problems = alerts.check_ownership(self.root)
        self.assertTrue(any('t_ownerhold' in p and 'do not re-page' in p for p in problems),
                        problems)
        self.assertFalse(any('t_ownerhold' in p and 'author the ASK' in p for p in problems),
                         problems)

    def test_worker_cannot_turn_a_technical_block_into_an_owner_decision(self):
        request = {'profile': 'standard-implementer', 'tool_name': 'kanban_block',
                   'tool_input': {'board': 'one', 'task_id': 't_12345678', 'kind': 'needs_input',
                                  'reason': 'Missing preparation evidence; ask the coordinator.'}}
        before = self.board_bytes()
        response = writer.guard(request, self.root, alerts)
        self.assertEqual('block', response['action'])
        self.assertIn('Only head-coordinator', response['message'])
        request['tool_input']['kind'] = 'capability'
        self.assertEqual({}, writer.guard(request, self.root, alerts))
        self.assertEqual(before, self.board_bytes())

    def test_owner_gate_is_checked_before_creation(self):
        body = 'ASK: Approve repair?\n A) Approve\n B) Keep current setting\n'
        request = {'profile': 'head-coordinator', 'tool_name': 'kanban_create',
                   'tool_input': {'board': 'one', 'title': 'Approve repair', 'body': body}}
        self.assertEqual('block', writer.guard(request, self.root, alerts)['action'])

        request['tool_input']['body'] = body + REPAIR_SUMMARY
        self.assertEqual({}, writer.guard(request, self.root, alerts))
        request['profile'] = 'project-auditor'
        self.assertEqual('block', writer.guard(request, self.root, alerts)['action'])

    def test_dependency_fallback_cannot_manufacture_owner_input(self):
        with closing(sqlite3.connect(self.boards['one'])) as db:
            db.execute('CREATE TABLE task_links (parent_id TEXT, child_id TEXT)')
            db.commit()
        request = {'profile': 'standard-implementer', 'tool_name': 'kanban_block',
                   'tool_input': {'board': 'one', 'task_id': 't_12345678', 'kind': 'dependency'}}
        self.assertEqual('block', writer.guard(request, self.root, alerts)['action'])
        with closing(sqlite3.connect(self.boards['one'])) as db:
            db.execute('INSERT INTO tasks (id,title,body,status,block_kind) VALUES (?,?,?,?,?)',
                       ('t_input', 'Collect missing input', '', 'ready', None))
            db.execute('INSERT INTO task_links VALUES (?,?)', ('t_input', 't_12345678'))
            db.commit()
        self.assertEqual({}, writer.guard(request, self.root, alerts))

    def test_coordinator_owner_block_requires_the_existing_checked_summary(self):
        request = {'profile': 'head-coordinator', 'tool_name': 'kanban_block',
                   'tool_input': {'board': 'one', 'task_id': 't_12345678', 'kind': 'needs_input'}}
        self.assertEqual({}, writer.guard(request, self.root, alerts))
        self.mark('one', 'Goal: Collect missing preparation evidence.')
        self.assertEqual('block', writer.guard(request, self.root, alerts)['action'])

    def test_worker_comments_cannot_publish_owner_summary(self):
        request = {'profile': 'project-auditor', 'tool_name': 'kanban_comment',
                   'tool_input': {'board': 'one', 'task_id': 't_12345678', 'body': REPAIR_SUMMARY}}
        self.assertEqual('block', writer.guard(request, self.root, alerts)['action'])
        request['profile'] = 'head-coordinator'
        self.assertEqual({}, writer.guard(request, self.root, alerts))
        request['tool_input']['body'] = 'Owner reply received: choose A. Scope remains unchanged.'
        self.assertEqual({}, writer.guard(request, self.root, alerts))

    def test_generic_owner_reason_and_details_pointer_are_not_actionable(self):
        task = alerts.snapshot(self.root / 'kanban/boards/one/board.json')[0]
        task['body'] = 'Goal: Activate the accepted inbox.'
        task['reason'] = 'The check failed.'
        shown, complete = alerts.decision_text('D1', 'one', task)
        self.assertFalse(complete, shown)

    def test_coordinator_can_check_summary_without_sending_or_mutating(self):
        summary = ('Blocking: The phone test is waiting for confirmation. Nothing else can confirm it.\n'
                   'Why owner: Only you can see whether the message reached your phone. No log proves it was displayed.\n'
                   'Unblock: Reply yes if it arrived, or no if it did not.')
        environment = {**os.environ, 'HERMES_ROOT': str(self.root),
                       'HERMES_DELEGATED_CHILD_CONTEXT': '1'}
        before = self.board_bytes()
        result = subprocess.run([sys.executable, '-B', alerts.__file__, '--check-summary', '-'],
                                input=summary, env=environment, text=True, capture_output=True)
        self.assertEqual(0, result.returncode, result.stderr)
        for invalid in [summary.replace('Unblock:', 'Notes:'),
                        summary.replace('Only you can see whether the message reached your phone.',
                                        'Only you can clear this; the board cannot self-resolve it.'),
                        summary.replace('Reply yes if it arrived, or no if it did not.',
                                        'Inspect details.'),
                        summary.replace('The phone test is waiting for confirmation.', 'x' * 501)]:
            with self.subTest(invalid=invalid):
                result = subprocess.run([sys.executable, '-B', alerts.__file__, '--check-summary', '-'],
                                        input=invalid, env=environment, text=True, capture_output=True)
                self.assertEqual(2, result.returncode, result.stdout)
        self.assertEqual(before, self.board_bytes())
        self.assertFalse(self.sent)
        self.assertFalse((self.root / 'kanban/owner-alerts').exists())

    def test_summary_length_checks_record_a_bounded_counter(self):
        # The CLI validation path records one aggregate outcome per check:
        # totals and per-limit rejections, a latest stamp, and no message text.
        valid = ('Blocking: The phone test is waiting for confirmation.\n'
                 'Why owner: Only you can see whether the message reached your phone.\n'
                 'Unblock: Reply yes if it arrived, or no if it did not.')
        environment = {**os.environ, 'HERMES_ROOT': str(self.root), 'HERMES_DELEGATED_CHILD_CONTEXT': '1'}
        result = subprocess.run([sys.executable, '-B', alerts.__file__, '--check-summary', '-'],
                                input=valid, env=environment, text=True, capture_output=True)
        self.assertEqual(0, result.returncode, result.stderr)
        result = subprocess.run([sys.executable, '-B', alerts.__file__, '--check-summary', '-'],
                                input=valid.replace('Reply yes if it arrived, or no if it did not.', 'x' * 501),
                                env=environment, text=True, capture_output=True)
        self.assertEqual(2, result.returncode, result.stdout)
        path = self.root / 'state/owner-alerts/limit-checks.json'
        state = json.loads(path.read_text())
        self.assertEqual(2, state['total'], state)
        self.assertEqual(1, state['rejections'].get('summary'), state)
        self.assertFalse(state['latest']['ok'])
        rendered = json.dumps(state)
        self.assertNotIn('phone test', rendered)
        self.assertNotIn('Blocking:', rendered)

    def test_concrete_single_sentence_fields_need_no_padding(self):
        summary = ('Blocking: Phone delivery cannot be verified until the message is seen.\n'
                   'Why owner: Only you can see whether the message appeared on your phone.\n'
                   'Unblock: Reply yes if it arrived, or no if it did not.')
        self.assertEqual('Reply yes if it arrived, or no if it did not.',
                         alerts.check_summary(summary)['Unblock'])

    def test_date_path_exemption_requires_a_literal_absolute_path(self):
        header = ('Blocking: The dated staging path is needed.\n'
                  'Why owner: Only you can provide its exact location.\n')
        accepted = ['/tmp/SXPOL-20261014-v3 holds the copies.',
                    'Inspect /tmp/SXPOL-20261014-v3.',
                    'Inspect /tmp/20261014-SXPOL.',
                    'Inspect (/tmp/20261014-SXPOL/).']
        for action in accepted:
            with self.subTest(accept=action):
                self.assertEqual(action, alerts.check_summary(header + 'Unblock: ' + action)['Unblock'])
        rejected = ['Run `cd -- ${ROOT}/tmp/SXPOL-20261014-v3`.',
                    'Run `cd -- $ROOT/tmp/SXPOL-20261014-v3`.',
                    'Run `cd -- $(pwd)/tmp/SXPOL-20261014-v3`.',
                    'Run `cd -- "$ROOT"/tmp/20261014-SXPOL`.',
                    'Run `cd -- `pwd`/tmp/SXPOL-20261014-v3`.',
                    'Inspect /tmp/20261014-abcdef7.',
                    'Inspect /tmp/20261014-SXPOL/abcdef7.',
                    'Inspect /tmp/20261014-SXPOL/20261014.',
                    'Inspect /tmp/20261014-20310409.']
        for action in rejected:
            with self.subTest(reject=action):
                with self.assertRaises(ValueError):
                    alerts.check_summary(header + 'Unblock: ' + action)


    def test_summary_duplicate_and_reordered_fields_are_refused(self):
        header = ('Blocking: The staging location is needed.\n'
                  'Why owner: Only you can provide its exact location.\n')
        self.assertEqual('Reply yes.',
                         alerts.check_summary(header + 'Unblock: Reply yes.')['Unblock'])
        refused = [header + 'Unblock: Reply yes.\nUnblock: Reply no.',
                   header + 'Unblock:\nUnblock: Reply no.',
                   header + 'Unblock: Reply yes.\nWhy owner: Only you can confirm it.',
                   'Why owner: Only you can confirm it.\n'
                   'Blocking: The staging location is needed.\nUnblock: Reply yes.',
                   header + 'Unblock:']
        for text in refused:
            with self.subTest(text=text):
                with self.assertRaises(ValueError):
                    alerts.check_summary(text)


    def test_worker_summary_cannot_replace_coordinator_summary(self):
        with closing(sqlite3.connect(self.boards['one'])) as db:
            for author, timestamp, problem in [('head-coordinator', 1, 'The phone test needs a reply. Nothing else can proceed.'),
                                                ('standard-implementer', 2, 'Approve unrelated changes.')]:
                db.execute('INSERT INTO task_comments (task_id,author,body,created_at) VALUES (?,?,?,?)',
                           ('t_12345678', author, f'Blocking: {problem}\n'
                            'Why owner: Only you can confirm receipt on your phone. No log records delivery.\n'
                            'Unblock: Reply yes if the test message arrived.', timestamp))
            db.commit()
        task = alerts.snapshot(self.root / 'kanban/boards/one/board.json')[0]
        shown, complete = alerts.decision_text('D1', 'one', task)
        self.assertTrue(complete, shown)
        self.assertIn('The phone test needs a reply.', shown)
        self.assertNotIn('unrelated', shown)
        self.assertNotIn('A) Approve', shown)

    def test_worker_created_gate_requires_coordinator_adoption(self):
        with closing(sqlite3.connect(self.boards['one'])) as db:
            db.execute("UPDATE tasks SET created_by='project-auditor'")
            db.execute('INSERT INTO task_comments (task_id,author,body,created_at) VALUES (?,?,?,?)',
                       ('t_12345678', 'project-auditor', REPAIR_SUMMARY, 1))
            db.commit()
        with self.assertRaisesRegex(RuntimeError, 'head-coordinator must author'):
            alerts.tick(self.root)
        self.assertFalse(self.sent)
        with closing(sqlite3.connect(self.boards['one'])) as db:
            db.execute('INSERT INTO task_comments (task_id,author,body,created_at) VALUES (?,?,?,?)',
                       ('t_12345678', 'head-coordinator', REPAIR_SUMMARY, 2))
            db.commit()
        alerts.tick(self.root)
        self.assertEqual(1, len(self.sent))

    def test_partial_comment_cannot_borrow_old_summary_fields(self):
        with closing(sqlite3.connect(self.boards['one'])) as db:
            db.execute('INSERT INTO task_comments (task_id,author,body,created_at) VALUES (?,?,?,?)',
                       ('t_12345678', 'head-coordinator', 'Blocking: The scope has changed.', 1))
            db.commit()
        with self.assertRaises(RuntimeError):
            alerts.tick(self.root)
        self.assertFalse(self.sent)

    def test_bad_summary_does_not_hide_other_valid_individual_blockers(self):
        self.mark('two', 'Hard Blocker\nGoal: Sign the release.')
        with self.assertRaises(RuntimeError):
            alerts.tick(self.root, force_decisions=True)
        self.assertEqual(1, len(self.sent))
        self.assertIn('D1 · one', self.sent[0])
        self.assertNotIn('D2 · two', self.sent[0])
        self.assertEqual([], alerts.resolve(self.root, 'D2')['delivered'])

    def test_check_blockers_reports_bad_author_without_mutation(self):
        with closing(sqlite3.connect(self.boards['one'])) as db:
            db.execute("UPDATE tasks SET created_by='project-auditor'")
            db.commit()
        before = self.board_bytes()
        result = subprocess.run([sys.executable, '-B', alerts.__file__, '--check-blockers'],
                                env={**os.environ, 'HERMES_ROOT': str(self.root)},
                                text=True, capture_output=True)
        self.assertEqual(2, result.returncode)
        self.assertIn('one:t_12345678', result.stderr)
        self.assertIn('head-coordinator must author', result.stderr)
        self.assertEqual(before, self.board_bytes())
        self.assertFalse((self.root / 'kanban/owner-alerts').exists())

    def test_check_blockers_warns_on_unclassified_capability_hold(self):
        environment = {**os.environ, 'HERMES_ROOT': str(self.root)}
        before = self.board_bytes()
        result = subprocess.run([sys.executable, '-B', alerts.__file__, '--check-blockers'],
                                env=environment, text=True, capture_output=True)
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn('two:t_12345678', result.stdout)
        self.assertIn('input supplier', result.stdout)
        self.assertEqual(before, self.board_bytes())
        # Classifying the hold clears the warning without touching a card's state.
        with closing(sqlite3.connect(self.boards['two'])) as db:
            db.execute("UPDATE task_events SET payload=? WHERE task_id='t_12345678'",
                       (json.dumps({'reason': 'Deferred scope. Input supplier: agent.'}),))
            db.commit()
        result = subprocess.run([sys.executable, '-B', alerts.__file__, '--check-blockers'],
                                env=environment, text=True, capture_output=True)
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertNotIn('two:t_12345678', result.stdout)
        self.assertFalse((self.root / 'kanban/owner-alerts').exists())

    def board_bytes(self):
        return {name: path.read_bytes() for name, path in self.boards.items()}

    def test_only_hard_blockers_reach_the_owner(self):
        alerts.tick(self.root, now=1000)
        self.assertEqual(1, len(self.sent))
        self.assertTrue(self.sent[0].startswith('*Hard Blocker*\n'))
        self.assertIn('D1 · one', self.sent[0])
        self.assertIn('Repair is waiting for your approval.', self.sent[0])
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
        self.mark('two', 'Hard Blocker: needs the owner key\nGoal: Sign the release.\n'
                  'Blocking: The release cannot be signed. The key is missing from the keyring.\n'
                  'Why owner: Only you hold the signing key. No agent can retrieve it.\n'
                  'Unblock: Sign the release with your existing key.')
        alerts.tick(self.root, now=1004)
        self.assertEqual(2, len(self.sent))
        self.assertIn('*Hard Blocker*\n', self.sent[1])
        self.assertIn('D2 · two', self.sent[1])
        self.assertIn('Only you hold the signing key.', self.sent[1])
        self.assertTrue(alerts.resolve(self.root, 'D2')['can_reply'])
        # The marker line is case-insensitive; a revision repushes as a new D.
        self.mark('two', 'hard blocker\nGoal: Sign the release.\n' + REPAIR_SUMMARY)
        alerts.tick(self.root, now=1006)
        self.assertEqual(3, len(self.sent))
        self.assertIn('D3 · two', self.sent[-1])

    def test_format_shows_description_and_coordinator_recommendation(self):
        self.mark('one', 'ASK: Where should phone replies go?\n'
                  ' A) Use the existing assistant for replies\n'
                  ' B) Keep the current setup\n'
                  'Blocking: Phone replies currently reach two assistants. Only one should answer.\n'
                  'Why owner: Only you can choose which assistant handles your replies. The choice is a preference only you hold.\n'
                  'Unblock: Choose A to use one assistant, or B to keep the current setup.')
        alerts.tick(self.root)
        message = self.sent[0]
        self.assertIn('Blocking: Phone replies currently reach two assistants.', message)
        self.assertIn('Why owner: Only you can choose which assistant handles your replies.', message)
        self.assertIn('Recommended: Choose A to use one assistant, or B to keep the current setup.', message)
        # The Recommended section is the coordinator's Unblock text only: card
        # body options are never echoed to the phone.
        self.assertNotIn('Choices:', message)
        self.assertNotIn('A) Use the existing assistant for replies', message)
        self.assertNotIn('B) Keep the current setup', message)

    def test_incomplete_blocker_is_not_sent_or_marked_delivered(self):
        self.mark('one', 'Goal: Activate the accepted inbox.')
        with self.assertRaisesRegex(RuntimeError, 'Coordinator must repair blocker text'):
            alerts.tick(self.root)
        self.assertFalse(self.sent)
        decision = alerts.resolve(self.root, 'D1')
        self.assertFalse(decision['compact_complete'])
        self.assertEqual([], decision['delivered'])
        with closing(sqlite3.connect(self.boards['one'])) as db:
            db.execute('INSERT INTO task_comments (task_id,author,body,created_at) VALUES (?,?,?,?)',
                       ('t_12345678', 'head-coordinator', REPAIR_SUMMARY, 1))
            db.commit()
        alerts.tick(self.root)
        self.assertEqual(1, len(self.sent))
        self.assertTrue(alerts.resolve(self.root, 'D2')['compact_complete'])
        self.assertFalse(alerts.resolve(self.root, 'D1')['can_reply'])

    def test_plain_summary_comment_overrides_jargon_body(self):
        # The card body and block reason are internal jargon; an agent posts a
        # plain-language summary as a comment and the phone message uses it.
        with closing(sqlite3.connect(self.boards['one'])) as db:
            db.execute("UPDATE tasks SET body='Goal: fix t_abc across the worktree.'")
            db.execute('UPDATE task_events SET payload=?',
                       (json.dumps({'reason': 'review t_deadbeef rejected 1e299daf6464c8b6a02080a5d01223f3fe90766c'}),))
            db.execute("INSERT INTO task_comments (task_id, author, body, created_at) VALUES "
                       "('t_12345678','head-coordinator',?,1)",
                       ('Blocking: A required safety check was removed and nobody re-approved it. The build is unsafe until it is restored.\n'
                        'Why owner: Only you can approve restoring the check. The original approval was yours alone.\n'
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
            db.execute('UPDATE tasks SET body=?', ('ASK: Approve a revised plan?\n' + REPAIR_SUMMARY,))
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

    def test_inline_choices_without_coordinator_summary_are_not_sent(self):
        with closing(sqlite3.connect(self.boards['one'])) as db:
            db.execute("UPDATE tasks SET body='Goal: Install approved supervision.'")
            db.execute('UPDATE task_events SET payload=?',
                       (json.dumps({'reason': 'Choose a supervisor: A) Autostart, B) Wait'}),))
            db.commit()
        with self.assertRaises(RuntimeError):
            alerts.tick(self.root)
        self.assertFalse(self.sent)
        self.assertFalse(alerts.resolve(self.root, 'D1')['compact_complete'])

    def test_block_reason_options_are_never_echoed_to_the_owner(self):
        with closing(sqlite3.connect(self.boards['one'])) as db:
            db.execute('UPDATE task_events SET payload=?',
                       (json.dumps({'reason': 'Revised ask: A) Replace framework, B) Defer'}),))
            db.commit()
        alerts.tick(self.root)
        self.assertEqual(1, len(self.sent))
        self.assertIn('D1 · one', self.sent[0])
        self.assertNotIn('Replace framework', self.sent[0])
        self.assertNotIn('Defer', self.sent[0])
        self.assertNotIn('Choices:', self.sent[0])

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
                db.execute('INSERT INTO tasks (id,title,body,status,block_kind) VALUES (?, ?, ?, ?, ?)', (f't_extra_{number}', f'Recover worker {number}', '', 'blocked', 'capability'))
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

    def test_one_message_per_blocker_keeps_prose_recommendation(self):
        body = ('ASK: Choose a recovery mechanism\n for this host?\n'
                ' A) Restore the worker\n  with existing credentials\n'
                ' B) Pause work\n  until capacity returns\n'
                'Blocking: The worker is down and queued work is stuck. Nothing is progressing until it recovers.\n'
                'Why owner: Recovery needs credentials that only you hold. No agent can supply them.\n'
                'Unblock: Choose A to restore access, or B to pause work.')
        with closing(sqlite3.connect(self.boards['one'])) as db:
            db.execute('UPDATE tasks SET body=?', (body,))
            for number in range(12):
                db.execute('INSERT INTO tasks (id,title,body,status,block_kind) VALUES (?, ?, ?, ?, ?)', (f't_new_{number}', 'Recover worker', body, 'blocked', 'needs_input'))
            db.commit()
        alerts.tick(self.root, now=1000)
        decisions = [m for m in self.sent if m.startswith('*Hard Blocker*')]
        # Board 'one' holds 13 blocked gates; each is exactly one phone message.
        self.assertEqual(13, len(decisions))
        self.assertTrue(all(m.count('Reply:') == 1 for m in decisions))
        self.assertTrue(all(len(m) <= 1600 for m in decisions))
        self.assertIn('Blocking: The worker is down and queued work is stuck.', decisions[0])
        self.assertIn('Why owner: Recovery needs credentials that only you hold.', decisions[0])
        self.assertIn('Recommended: Choose A to restore access, or B to pause work.', decisions[0])
        # Card-body options are never echoed; the coordinator wrote the choice.
        self.assertNotIn('Choices:', decisions[0])
        self.assertNotIn('B) Pause work until capacity returns', decisions[0])
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
        self.mark('two', 'Hard Blocker\nGoal: Sign.\n' + REPAIR_SUMMARY)
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

    def test_decision_channel_mirrors_the_live_set_instead_of_dming(self):
        self.env.write_text(self.env.read_text() + 'SIMPLEX_DECISION_GROUP=7\nSIMPLEX_GROUP_ALLOWED=7\n')
        self.assertEqual('simplex:3', alerts.target_config(self.root))
        seen = []
        with patch.object(alerts.simplex_decisions, 'reconcile',
                          side_effect=lambda root, live, dry_run=False: seen.append(live) or []):
            alerts.tick(self.root)
        self.assertFalse(self.sent)
        self.assertEqual(1, len(seen))
        self.assertIn('alert:D1', seen[0])
        self.assertIn('*Decision*', seen[0]['alert:D1'])

    def test_incomplete_board_read_never_deletes_live_decisions(self):
        self.env.write_text(self.env.read_text() + 'SIMPLEX_DECISION_GROUP=7\nSIMPLEX_GROUP_ALLOWED=7\n')
        seen = []
        with patch.object(alerts, 'collect', return_value=([], {}, {}, [], True)), \
             patch.object(alerts.simplex_decisions, 'reconcile',
                          side_effect=lambda root, live, dry_run=False: seen.append(live) or []):
            with self.assertRaises(RuntimeError):
                alerts.tick(self.root)
        self.assertEqual([], seen)

    def test_transport_requires_success_acknowledgment(self):
        for stdout in ['{"success":false}', '{"skipped":true}', '{"error":"offline"}']:
            with patch.object(alerts.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, stdout, '')):
                with self.assertRaises(RuntimeError):
                    self.real_send(self.root, 'simplex:3', 'test')

    def test_install_preserves_policy_and_job_state(self):
        soul = self.env.parent / 'SOUL.md'
        legacy = (Path(alerts.__file__).parent / 'taskforce/owner-alert-replies.md').read_text()
        soul.write_text('# Head\nKeep existing deploy policy.\n' + alerts.MARKER + '\n' + legacy)
        (soul.parent / 'config.yaml').write_text('model: keep-head-model\n')
        auditor = self.root / 'profiles/project-auditor/SOUL.md'
        auditor.parent.mkdir(parents=True)
        auditor.write_text('# Auditor\nKeep existing assessment policy.\n')
        steward = self.root / 'profiles/board-steward/SOUL.md'
        steward.parent.mkdir(parents=True)
        steward.write_text('# Steward\nKeep existing read-only policy.\n')
        cron = self.root / 'cron/jobs.json'
        cron.parent.mkdir()
        job = {"name": alerts.JOB, "script": "kanban-owner-alerts.py", "no_agent": True,
               "schedule": {"minutes": 15}, "enabled": False}
        cron.write_text(json.dumps({'jobs': [job]}))
        alerts.install(self.root)
        installed = soul.read_text()
        self.assertIn('Keep existing deploy policy.', installed)
        self.assertIn('kanban_comment', installed)
        self.assertIn('owner-blocker-authoring-guard.py', (soul.parent / 'config.yaml').read_text())
        self.assertIn('model: keep-head-model', (soul.parent / 'config.yaml').read_text())
        self.assertIn('sole author', auditor.read_text())
        self.assertIn('Keep existing assessment policy.', auditor.read_text())
        # The read-only steward gets the bounded boundary, not lane procedures.
        installed_steward = steward.read_text()
        self.assertIn('Keep existing read-only policy.', installed_steward)
        self.assertIn('Fleet boundary', installed_steward)
        self.assertIn('hermes-fleet-policy.md', installed_steward)
        self.assertNotIn('Never remove worker pins', installed_steward)
        self.assertIn('Never remove worker pins', soul.read_text())
        installed_auditor = auditor.read_text()
        alerts.install(self.root)
        self.assertEqual(installed, soul.read_text())
        self.assertEqual(installed_auditor, auditor.read_text())
        self.assertEqual(installed_steward, steward.read_text())
        # The pre-install head policy is archived, content-addressed, and a
        # no-change reinstall adds no new archive.
        archived = {p.read_bytes() for p in (self.root / 'backups/owner-alerts').rglob('*')
                    if p.is_file()}
        self.assertIn(('# Head\nKeep existing deploy policy.\n' + alerts.MARKER + '\n' + legacy).encode(),
                      archived)
        alerts.install(self.root)
        self.assertEqual(archived, {p.read_bytes() for p in (self.root / 'backups/owner-alerts').rglob('*')
                                    if p.is_file()})
        soul.write_text(installed + '\n## Another policy\nPreserve this later addition.\n')
        alerts.install(self.root)
        self.assertIn('Preserve this later addition.', soul.read_text())
        self.assertFalse(json.loads(cron.read_text())['jobs'][0]['enabled'])

    def test_install_rejects_ambiguous_policy_markers_before_any_write(self):
        head = self.env.parent / 'SOUL.md'
        auditor = self.root / 'profiles/project-auditor/SOUL.md'
        auditor.parent.mkdir(parents=True)
        cron = self.root / 'cron/jobs.json'
        cron.parent.mkdir()
        cron.write_text(json.dumps({'jobs': [{'name': alerts.JOB, 'script': 'kanban-owner-alerts.py',
            'no_agent': True, 'schedule': {'minutes': 15}, 'enabled': False}]}))
        for target, start, end in ((head, alerts.MARKER, alerts.END_MARKER),
                                   (auditor, alerts.AUTHOR_MARKER, alerts.AUTHOR_END_MARKER)):
            for text in (start, end, start + end + end, start + start + end, end + start):
                with self.subTest(target=target.name, text=text):
                    head.write_text('# Coordinator\n')
                    auditor.write_text('# Auditor\n')
                    target.write_text(text)
                    before = {p: p.read_bytes() for p in self.root.rglob('*') if p.is_file()}
                    with patch.object(alerts.subprocess, 'run') as run:
                        with self.assertRaises(ValueError):
                            alerts.install(self.root)
                        run.assert_not_called()
                    self.assertEqual(before, {p: p.read_bytes() for p in self.root.rglob('*') if p.is_file()})

with patch.dict(os.environ):
    os.environ.pop('HERMES_DELEGATED_CHILD_CONTEXT', None)
    os.environ.pop('HERMES_KANBAN_TASK', None)
    unittest.main(argv=['alerts'], verbosity=2)
PY
