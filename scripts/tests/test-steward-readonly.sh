#!/usr/bin/env bash
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
python3 -B - "$repo" <<'PY'
from contextlib import closing
import importlib.util
import json
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

SOURCE = Path(sys.argv[1]) / 'scripts/hermes'
def module(name, filename):
    spec = importlib.util.spec_from_file_location(name, SOURCE / filename)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result
guard = module('guard', 'steward-readonly-guard.py')
reader = module('reader', 'steward-board-read.py')
installer = module('installer', 'install-steward-readonly.py')
snapshot = module('snapshot', 'kanban-daily-steward.py')

class StewardTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='nixhomeserver-steward-readonly-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name) / 'hermes'
        self.repo = Path(self.tmp.name) / 'repo'
        self.repo.mkdir()

    def call(self, tool, **args):
        return guard.guard({'tool_name': tool, 'tool_input': args}, self.root, self.repo)

    def test_read_tools_and_cross_board_inspection_remain_available(self):
        for tool in ['read_file', 'search']:
            self.assertEqual({}, self.call(tool, board='another-board'))
        for command in [f'python3 {self.root}/scripts/steward-board-read.py --boards',
                        f'python3 {self.root}/scripts/steward-board-read.py --board pcops --query "SELECT * FROM tasks"']:
            self.assertEqual('modify', self.call('terminal', command=command)['action'])

    def test_changes_and_arbitrary_execution_are_blocked(self):
        for tool in ['kanban_list', 'kanban_show', 'kanban_attachments', 'kanban_create', 'kanban_comment', 'kanban_unblock', 'kanban_link', 'write_file',
                     'patch', 'memory', 'cronjob', 'delegate_task', 'process']:
            self.assertEqual('block', self.call(tool)['action'])
        for command in ['hermes kanban list', 'hermes kanban show t_example',
                        'hermes kanban --board pcops unblock t_example', 'hermes kanban create change',
                        'hermes cron pause job', 'git commit -m change', 'python3 -c "print(1)"',
                        'sqlite3 board.db "DELETE FROM tasks"', 'sudo systemctl restart hermes',
                        'git diff --output=/tmp/changed', 'git show --ext-diff HEAD']:
            self.assertEqual('block', self.call('terminal', command=command)['action'], command)

    def test_shell_injection_cannot_write_a_file(self):
        subprocess.run(['git', 'init', '-q', str(self.repo)], check=True)
        sentinel = self.repo / 'should-not-exist'
        command = f'git -C {self.repo} status --short && touch {sentinel}'
        result = self.call('terminal', command=command)
        self.assertEqual('modify', result['action'])
        subprocess.run(result['args']['command'], shell=True, capture_output=True)
        self.assertFalse(sentinel.exists())
        command = f'git -C {self.repo} log "$(touch {sentinel})"'
        result = self.call('terminal', command=command)
        subprocess.run(result['args']['command'], shell=True, capture_output=True)
        self.assertFalse(sentinel.exists())

    def test_report_senders_are_not_steward_tools(self):
        command = "~/.hermes/scripts/simplex-send-group.sh 1 <<'REPORT'\nProposed: $(touch nope)\nREPORT"
        for invalid in [command, command + '\ntouch nope', command.replace("'REPORT'", 'REPORT'),
                        command.replace('.sh 1', '.sh 3')]:
            self.assertEqual('block', self.call('terminal', command=invalid)['action'])

    def test_board_queries_cannot_write_or_attach(self):
        path = self.root / 'kanban/boards/one/kanban.db'
        path.parent.mkdir(parents=True)
        with closing(sqlite3.connect(path)) as db:
            db.execute('CREATE TABLE tasks (id TEXT, status TEXT)')
            db.execute("INSERT INTO tasks VALUES ('t_example','blocked')")
            db.commit()
        before = path.read_bytes()
        result = reader.query(self.root, 'one', 'SELECT * FROM tasks')
        self.assertEqual([{'id': 't_example', 'status': 'blocked'}], result['rows'])
        for sql in ["UPDATE tasks SET status='ready'", 'CREATE TABLE changed (id TEXT)',
                    "ATTACH DATABASE '/tmp/steward-bypass.db' AS other", "SELECT load_extension('x')"]:
            with self.assertRaises(sqlite3.DatabaseError):
                reader.query(self.root, 'one', sql)
        self.assertEqual(before, path.read_bytes())
        with self.assertRaises(ValueError):
            reader.query(self.root, '../one', 'SELECT 1')
        archive = self.root / 'kanban/boards/_archived/old-board/kanban.db'
        archive.parent.mkdir(parents=True)
        archive.write_bytes(before)
        self.assertEqual(result, reader.query(self.root, '_archived/old-board', 'SELECT * FROM tasks'))

    def test_install_replaces_old_powers_and_existing_cron_prompts(self):
        profile = self.root / 'profiles/board-steward'
        profile.mkdir(parents=True)
        (profile / 'SOUL.md').write_text('Old grant: restore scripts and unblock cards.')
        (profile / 'config.yaml').write_text('model: {default: keep-model}\nhooks:\n  post_tool_call:\n    - command: echo keep-hook\n')
        (profile / 'profile.yaml').write_text('name: board-steward\ndescription: Old mutator\n')
        jobs_path = profile / 'cron/jobs.json'
        jobs_path.parent.mkdir()
        jobs = [{'id': 'daily', 'name': 'hermes daily steward', 'prompt': 'Unblock cards',
                 'enabled': False, 'schedule': {'kind': 'cron', 'expr': '0 8 * * *'}, 'skills': []},
                {'id': 'opportunities', 'name': 'steward opportunity scan', 'prompt': 'Create cards',
                 'enabled': True, 'schedule': {'minutes': 120}, 'skills': []}]
        jobs_path.write_text(json.dumps({'jobs': jobs}))
        before = {path: path.read_bytes() for path in profile.rglob('*') if path.is_file()}
        self.assertEqual(1, installer.install(self.root, self.repo, check=True))
        self.assertEqual(before, {path: path.read_bytes() for path in profile.rglob('*') if path.is_file()})
        calls = []
        def edit(command, **kwargs):
            calls.append(command)
            job = next(job for job in jobs if job['id'] == command[5])
            for flag, key in [('--prompt', 'prompt'), ('--script', 'script'),
                              ('--monitor-script', 'monitor_script'), ('--workdir', 'workdir'), ('--deliver', 'deliver')]:
                if flag in command:
                    job[key] = command[command.index(flag) + 1]
            job['skills'] = ['board-steward']
            if '--schedule' in command:
                job['schedule'] = {'kind': 'cron', 'expr': command[command.index('--schedule') + 1]}
            jobs_path.write_text(json.dumps({'jobs': jobs}))
        with patch.object(installer.subprocess, 'run', edit):
            self.assertEqual(0, installer.install(self.root, self.repo))
            self.assertEqual(0, installer.install(self.root, self.repo, check=True))
            self.assertEqual(0, installer.install(self.root, self.repo))
        self.assertEqual(2, len(calls))
        self.assertFalse(jobs[0]['enabled'])
        self.assertEqual({'kind': 'cron', 'expr': '0 7 * * *'}, jobs[0]['schedule'])
        self.assertEqual({'minutes': 120}, jobs[1]['schedule'])
        # Schedule-only drift must also be repaired without resetting other jobs.
        jobs[0]['schedule']['expr'] = '0 8 * * *'
        jobs_path.write_text(json.dumps({'jobs': jobs}))
        with patch.object(installer.subprocess, 'run', edit):
            self.assertEqual(1, installer.install(self.root, self.repo, check=True))
            self.assertEqual(0, installer.install(self.root, self.repo))
            self.assertEqual(0, installer.install(self.root, self.repo, check=True))
        self.assertEqual(3, len(calls))
        self.assertEqual({'kind': 'cron', 'expr': '0 7 * * *'}, jobs[0]['schedule'])
        config = (profile / 'config.yaml').read_text()
        self.assertIn('model: {default: keep-model}', config)
        self.assertIn('post_tool_call:\n    - command: echo keep-hook', config)
        self.assertIn('fail_closed: true', config)
        self.assertIn('hooks_auto_accept: true', config)
        self.assertIn('read-only observer', (profile / 'SOUL.md').read_text())
        self.assertIn('copyable external-agent handoff', jobs[1]['prompt'])
        self.assertTrue((self.root / 'backups/steward-readonly').is_dir())

    def test_daily_snapshot_includes_yesterday_and_excludes_older_activity(self):
        boards = self.root / 'kanban/boards'
        board = boards / 'one'
        board.mkdir(parents=True)
        now = int(time.time())
        with closing(sqlite3.connect(board / 'kanban.db')) as db:
            db.executescript('''
                CREATE TABLE tasks (id, title, assignee, status, block_kind,
                    block_recurrences, consecutive_failures, last_failure_error,
                    completed_at, worker_pid, last_heartbeat_at, body);
                CREATE TABLE task_runs (task_id, profile, status, outcome,
                    summary, error, started_at, ended_at);
            ''')
            for tid, age in [('yesterday', 20 * 3600), ('older', 25 * 3600)]:
                db.execute('INSERT INTO tasks VALUES (?, ?, ?, ?, NULL, 0, 0, NULL, ?, NULL, NULL, NULL)',
                           (tid, tid, 'worker', 'done', now - age))
                db.execute('INSERT INTO task_runs VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
                           (tid, 'worker', 'failed', 'gave_up', '', 'failure', now - age, now - age + 60))
            db.commit()
        with patch.object(snapshot, 'BOARDS', boards):
            output = '\n'.join(snapshot.snapshot_board('one'))
        self.assertIn('LAST 24H DONE (1)', output)
        self.assertIn('LAST 24H FAILED RUNS (1)', output)
        self.assertIn('yesterday', output)
        self.assertNotIn('older', output)

unittest.main(argv=['steward'], verbosity=2)
PY
