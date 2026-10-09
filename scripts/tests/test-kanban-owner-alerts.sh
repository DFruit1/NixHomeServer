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
        self.sent = []
        self.real_send = alerts.send
        self.sender = patch.object(alerts, 'send', lambda root, target, message: self.sent.append(message))
        self.sender.start()
        self.addCleanup(self.sender.stop)

    def test_current_and_new_blocks_are_delivered_once_without_board_mutations(self):
        paths = list(self.root.glob('kanban/boards/*/kanban.db'))
        before = {p: p.read_bytes() for p in paths}
        alerts.tick(self.root)
        self.assertEqual(2, len(self.sent))
        self.assertIn('Owner decision', self.sent[0])
        self.assertIn('Technical blocker', self.sent[1])
        self.assertNotIn('approve, reject', self.sent[1])
        self.assertIn('one t_12345678', self.sent[0])
        alerts.tick(self.root)
        self.assertEqual(2, len(self.sent))
        self.assertEqual(before, {p: p.read_bytes() for p in paths})
        with closing(sqlite3.connect(paths[0])) as db:
            db.execute('INSERT INTO task_events VALUES (2, ?, ?, ?)', ('t_12345678', 'commented', '{}'))
            db.commit()
        alerts.tick(self.root)
        self.assertEqual(2, len(self.sent))
        with closing(sqlite3.connect(paths[0])) as db:
            db.execute('INSERT INTO task_events VALUES (3, ?, ?, ?)', ('t_12345678', 'blocked', '{"reason":"Different question"}'))
            db.commit()
        alerts.tick(self.root)
        self.assertEqual(3, len(self.sent))
        with closing(sqlite3.connect(paths[0])) as db:
            db.execute("UPDATE tasks SET body='ASK: Approve a revised plan?' WHERE id='t_12345678'")
            db.commit()
        alerts.tick(self.root)
        self.assertEqual(4, len(self.sent))

    def test_failed_delivery_retries_without_starving_other_board(self):
        def fail_one(root, target, message):
            if 'one t_' in message:
                raise RuntimeError('offline')
            self.sent.append(message)
        with patch.object(alerts, 'send', fail_one):
            with self.assertRaises(RuntimeError):
                alerts.tick(self.root)
        self.assertEqual(1, len(self.sent))
        alerts.tick(self.root)
        self.assertEqual(2, len(self.sent))

    def test_dry_run_and_fenced_workers_do_not_send(self):
        alerts.tick(self.root, dry_run=True)
        self.assertFalse(self.sent)
        self.assertFalse((self.root / 'kanban/owner-alerts/state.json').exists())
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
