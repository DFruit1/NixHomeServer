#!/usr/bin/env bash
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
python3 -B - "$repo" <<'PY'
from contextlib import closing
import contextlib
import datetime
import importlib.util
import io
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
# The installers import sibling helpers (hermes_common, hermes_config) by
# module name; loading them from this suite needs their directory on sys.path.
sys.path.insert(0, str(SOURCE))
def module(name, filename):
    spec = importlib.util.spec_from_file_location(name, SOURCE / filename)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result
guard = module('guard', 'steward-readonly-guard.py')
reader = module('reader', 'steward-board-read.py')
installer = module('installer', 'install-steward-readonly.py')
snapshot = module('snapshot', 'kanban-daily-steward.py')
window = module('window', 'daily-steward-window.py')
usage = module('usage', 'usage-pace.py')
handoff = module('handoff', 'steward-coordinator-request.py')

class StewardTest(unittest.TestCase):
    def test_managed_hooks_reject_orphan_duplicate_and_reversed_markers(self):
        marker = '    # nixhomeserver-steward-readonly:'
        start, end = marker + 'start\n', marker + 'end\n'
        for section in (start, end, start + end + end, start + start + end, end + start):
            with self.subTest(section=section):
                with self.assertRaises(ValueError):
                    installer.readonly_hook('hooks:\n  pre_tool_call:\n' + section, 'python3 guard.py')
        text = 'hooks:\n  pre_tool_call:\n' + start + end.rstrip('\n')
        updated = installer.readonly_hook(text, 'python3 guard.py')
        self.assertEqual(updated, installer.readonly_hook(updated, 'python3 guard.py'))

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
                        f'python3 {self.root}/scripts/kanban-performance.py --json',
                        f'python3 {self.root}/scripts/kanban-blockers.py --board pcops --json',
                        f'python3 {self.root}/scripts/steward-board-read.py --board pcops --query "SELECT * FROM tasks"',
                        f'python3 {self.root}/scripts/kanban-owner-alerts.py --details blockers',
                        f'python3 {self.root}/scripts/kanban-owner-alerts.py --check-blockers',
                        f'python3 {self.root}/scripts/kanban-owner-alerts.py --resolve D1',
                        f'python3 {self.root}/scripts/kanban-owner-alerts.py --check-summary -']:
            self.assertEqual('modify', self.call('terminal', command=command)['action'])

    def test_coordinator_handoff_can_request_actions_outside_steward_scope(self):
        self.assertEqual({}, self.call('message_agent', target='head-coordinator',
            message='Please repair the tracked script through its installer and record the result.'))
        for target in ['standard-implementer', 'owner', 'peer/head-coordinator',
                       'head-coordinator@remote', '@head-coordinator', '', None]:
            self.assertEqual('block', self.call('message_agent', target=target,
                message='Please write the fix.')['action'])
        for message in ['', '   ', None, {}, 42]:
            self.assertEqual('block', self.call('message_agent', target='head-coordinator',
                message=message)['action'])
        self.assertEqual('block', self.call('delegate_task', target='head-coordinator',
            task='Write the fix.')['action'])

    def test_discovery_and_simplex_handoff_are_available_without_generic_dispatch(self):
        for tool in ['tool_search', 'tool_describe']:
            self.assertEqual({}, self.call(tool, queries=['message_agent'], names=['message_agent']))
        self.assertEqual('block', self.call('tool_call', name='write_file', arguments={})['action'])
        command = (f'python3 {self.root}/scripts/steward-coordinator-request.py '
                   '--request-id owner-request-1 --message "Request a consolidated question list"')
        self.assertEqual('modify', self.call('terminal', command=command)['action'])
        for tail in ['--target standard-implementer', '--script evil.py', '--install']:
            self.assertEqual('block', self.call('terminal', command=command+' '+tail)['action'])

    def test_simplex_request_reuses_native_queue_with_fixed_target_and_stable_id(self):
        target = self.root / 'profiles/head-coordinator'
        target.mkdir(parents=True)
        (target / 'state.db').touch()
        records = {}
        class Delivery:
            def defer(_, key, job, content, profile, home):
                record = dict(status='queued', content=content, profile=profile, home=home)
                if key in records and records[key] != record:
                    raise ValueError('delivery id already belongs to a different payload')
                records[key] = record
                return record
        delivery = Delivery()
        first = handoff.queue_request(self.root, 'owner-1', 'Please write the fix.', delivery)
        self.assertEqual(first, handoff.queue_request(self.root, 'owner-1', 'Please write the fix.', delivery))
        self.assertEqual(1, len(records))
        record = records[first['delivery_id']]
        self.assertEqual(('head-coordinator', target), (record['profile'], record['home']))
        self.assertIn('not owner approval', record['content'])
        self.assertEqual('queued', first['status'])
        with self.assertRaises(ValueError):
            handoff.queue_request(self.root, 'owner-1', 'Different request.', delivery)
        for bad in ['', ' ', None, 'x' * 24001]:
            with self.assertRaises(ValueError):
                handoff.queue_request(self.root, 'bad', bad, delivery)
        (target / 'state.db').unlink()
        with self.assertRaises(ValueError):
            handoff.queue_request(self.root, 'missing', 'Please act.', delivery)

    def test_changes_and_arbitrary_execution_are_blocked(self):
        for tool in ['kanban_list', 'kanban_show', 'kanban_attachments', 'kanban_create', 'kanban_comment', 'kanban_unblock', 'kanban_link', 'write_file',
                     'patch', 'memory', 'cronjob', 'delegate_task', 'process']:
            self.assertEqual('block', self.call(tool)['action'])
        for command in ['hermes kanban list', 'hermes kanban show t_example',
                        'hermes kanban --board pcops unblock t_example', 'hermes kanban create change',
                        'hermes cron pause job', 'git commit -m change', 'python3 -c "print(1)"',
                        'sqlite3 board.db "DELETE FROM tasks"', 'sudo systemctl restart hermes',
                        'git diff --output=/tmp/changed', 'git show --ext-diff HEAD',
                        f'python3 {self.root}/scripts/kanban-owner-alerts.py --send-decisions',
                        f'python3 {self.root}/scripts/kanban-owner-alerts.py --install',
                        f'python3 {self.root}/scripts/kanban-owner-alerts.py --dry-run',
                        f'python3 {self.root}/scripts/kanban-owner-alerts.py']:
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
        (profile / 'config.yaml').write_text('model: {default: keep-model}\nhooks:\n  post_tool_call:\n    - command: echo keep-hook\n'
            'platform_toolsets:\n  cli: [file, terminal, memory, kanban]\n'
            '  desktop:\n    - web\n    - skills\n  simplex: [web, todo]\n  telegram: [web]\n')
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
            if command[4] == 'create':
                job = {'id': 'stalls', 'name': command[command.index('--name') + 1],
                       'prompt': command[6].strip(), 'schedule': {'kind': 'cron', 'expr': command[5]},
                       'enabled': True}
                jobs.append(job)
            else:
                job = next(job for job in jobs if job['id'] == command[5])
            for flag, key in [('--prompt', 'prompt'), ('--script', 'script'),
                              ('--monitor-script', 'monitor_script'), ('--workdir', 'workdir'), ('--deliver', 'deliver')]:
                if flag in command:
                    job[key] = command[command.index(flag) + 1]
            job['skills'] = ['board-steward']
            if '--continuity' in command:
                job['context_from'] = ['self']
            elif '--no-continuity' in command:
                job['context_from'] = [ref for ref in job.get('context_from', []) if ref != 'self']
            if '--schedule' in command:
                job['schedule'] = {'kind': 'cron', 'expr': command[command.index('--schedule') + 1]}
            jobs_path.write_text(json.dumps({'jobs': jobs}))
        with patch.object(installer.subprocess, 'run', edit):
            self.assertEqual(0, installer.install(self.root, self.repo))
            self.assertEqual(0, installer.install(self.root, self.repo, check=True))
            from hermes_config import compact
            path = profile / 'config.yaml'
            path.write_text(compact(path.read_text(), '# Copied reference comment\n'))
            self.assertEqual(0, installer.install(self.root, self.repo, check=True))
            self.assertEqual(0, installer.install(self.root, self.repo))
        self.assertEqual(3, len(calls))
        # Daily comparison needs its previous answer; stall timing now belongs
        # to the machine ledger and must not inherit a narrative clock.
        jobs[0]['context_from'] = []
        jobs[2]['context_from'] = ['self']
        jobs_path.write_text(json.dumps({'jobs': jobs}))
        with patch.object(installer.subprocess, 'run', edit):
            self.assertEqual(1, installer.install(self.root, self.repo, check=True))
            self.assertEqual(0, installer.install(self.root, self.repo))
            self.assertEqual(0, installer.install(self.root, self.repo, check=True))
        self.assertEqual(['self'], jobs[0]['context_from'])
        self.assertEqual([], jobs[2]['context_from'])
        self.assertEqual('bot-chat:head-coordinator', jobs[2]['deliver'])
        self.assertEqual({'kind': 'cron', 'expr': '0 */4 * * *'}, jobs[2]['schedule'])
        self.assertEqual('kanban-daily-steward.py', jobs[2]['script'])
        # The daily window remains; the cron policy wraps the stall collector
        # with bounded, due-only evidence without changing its stored schedule.
        self.assertEqual('daily-steward-window.py', jobs[0]['script'])
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
        self.assertEqual(6, len(calls))
        self.assertEqual({'kind': 'cron', 'expr': '0 7 * * *'}, jobs[0]['schedule'])
        config = (profile / 'config.yaml').read_text()
        self.assertIn('model: {default: keep-model}', config)
        self.assertIn('post_tool_call:\n    - command: echo keep-hook', config)
        self.assertIn('fail_closed: true', config)
        self.assertIn('hooks_auto_accept: true', config)
        from hermes_config import document
        tools = document(config)['platform_toolsets']
        for platform in ('cli', 'desktop', 'simplex'):
            self.assertEqual(['file', 'terminal', 'skills', 'clarify'], tools[platform])
        self.assertEqual(['web'], tools['telegram'])
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

    def test_daily_window_catches_up_only_in_window_and_once_per_day(self):
        # 07:00 is the only scheduled slot; a missed run catches up inside
        # 07:00-17:00 exactly once and stays silent outside the window.
        yes = datetime.datetime(2026, 10, 13, 9, 0)
        self.assertTrue(window.should_emit(yes, None))
        self.assertTrue(window.should_emit(yes, datetime.date(2026, 10, 12)))
        self.assertFalse(window.should_emit(yes, datetime.date(2026, 10, 13)))  # already today
        self.assertFalse(window.should_emit(datetime.datetime(2026, 10, 13, 6, 59),
                                            datetime.date(2026, 10, 12)))       # too early
        self.assertFalse(window.should_emit(datetime.datetime(2026, 10, 13, 17, 0),
                                            datetime.date(2026, 10, 12)))       # 5pm waits for 7am
        self.assertFalse(window.should_emit(datetime.datetime(2026, 10, 13, 22, 30), None))

    def test_daily_window_marker_round_trips(self):
        window.record_emit(self.root, datetime.datetime(2026, 10, 13, 9, 0))
        self.assertEqual(datetime.date(2026, 10, 13), window.last_emit_date(self.root))
        self.assertIsNone(window.last_emit_date(self.root / 'absent'))

    def test_daily_window_reopens_the_day_after_a_delivery_failure(self):
        # A catch-up that fires before the SimpleX daemons are up fails delivery;
        # the day must stay eligible so a later manual run still reaches the owner.
        cron = self.root / 'profiles/board-steward/cron'
        cron.mkdir(parents=True)
        jobs = cron / 'jobs.json'
        jobs.write_text(json.dumps({'jobs': [
            {'name': 'hermes daily steward', 'last_delivery_error': 'SimpleX send failed'}]}))
        self.assertTrue(window.delivery_failed(self.root))
        now = datetime.datetime(2026, 10, 13, 9, 0)
        self.assertFalse(window.should_emit(now, now.date(), False))
        self.assertTrue(window.should_emit(now, now.date(), True))
        jobs.write_text(json.dumps({'jobs': [
            {'name': 'hermes daily steward', 'last_delivery_error': None}]}))
        self.assertFalse(window.delivery_failed(self.root))

    def test_daily_window_suppress_prints_the_wake_gate(self):
        # Outside the window the last stdout line must be the Hermes wake gate,
        # which skips the agent run and delivery entirely.
        with patch.dict(window.os.environ, {'HERMES_ROOT': str(self.root)}):
            with patch.object(window, 'should_emit', return_value=False):
                buf = io.StringIO()
                with contextlib.redirect_stdout(buf):
                    window.main()
        self.assertEqual('{"wakeAgent": false}', buf.getvalue().strip().splitlines()[-1])

    def test_daily_window_emit_runs_collectors_and_records_marker(self):
        loaded, calls = [], []
        class FakeCollector:
            def main(self):
                calls.append('main')
                print('=== KANBAN DAILY SNAPSHOT fixture ===')
        def fake_load(name):
            loaded.append(name)
            return FakeCollector()
        with patch.dict(window.os.environ, {'HERMES_ROOT': str(self.root)}):
            with patch.object(window, 'should_emit', return_value=True):
                with patch.object(window, 'load_collector', fake_load):
                    buf = io.StringIO()
                    with contextlib.redirect_stdout(buf):
                        window.main()
        self.assertEqual(list(window.COLLECTORS), loaded)
        self.assertEqual(['main'] * len(window.COLLECTORS), calls)
        self.assertIn('KANBAN DAILY SNAPSHOT', buf.getvalue())
        self.assertEqual(datetime.date.today(), window.last_emit_date(self.root))

    def test_usage_pace_reads_local_spend_without_secrets(self):
        self.root.mkdir(parents=True, exist_ok=True)
        state = self.root / 'state.db'
        stamp = int(time.time())
        with closing(sqlite3.connect(state)) as db:
            db.execute('CREATE TABLE sessions (id TEXT PRIMARY KEY, model TEXT,'
                       ' input_tokens INTEGER, output_tokens INTEGER, cache_read_tokens INTEGER,'
                       ' started_at REAL)')
            db.execute("INSERT INTO sessions VALUES ('s1','m',1000,500,0,?)", (stamp - 3600,))
            db.commit()
        ocdb = self.root / 'opencode.db'
        with closing(sqlite3.connect(ocdb)) as db:
            db.execute('CREATE TABLE session (id TEXT PRIMARY KEY, cost REAL, tokens_input INTEGER,'
                       ' tokens_output INTEGER, time_updated INTEGER)')
            db.execute("INSERT INTO session VALUES ('x',0.5,2000,1000,?)", (stamp * 1000 - 3600_000,))
            db.commit()
        env = {'HERMES_ROOT': str(self.root), 'OPENCODE_DB': str(ocdb), 'HERMES_BIN': '/nonexistent',
               'OPENCODE_AUTH': str(self.root / 'absent-auth.json'),
               'T3_CACHE_DIR': str(self.root / 'absent-t3')}
        with patch.dict(usage.os.environ, env):
            self.assertEqual([1, 1500, 0.0], usage.hermes_spend()['24h'])
            self.assertEqual([1, 3000, 0.5], usage.opencode_spend()['24h'])
            self.assertEqual(({}, 'no OpenCode credential'), usage.opencode_live())
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                usage.main()
        out = buf.getvalue()
        self.assertIn('USAGE PACE', out)
        self.assertIn('hermes 24h', out)
        self.assertIn('opencode 24h', out)
        self.assertIn('unavailable', out)

    def test_usage_pace_reports_opencode_go_windows_from_zen(self):
        # Same source the T3 Code usage tab reads: the opencode-go key in the
        # OpenCode auth file, queried against the Zen usage endpoint.
        auth = self.root / 'auth.json'
        self.root.mkdir(parents=True, exist_ok=True)
        auth.write_text(json.dumps({'opencode-go': {'type': 'api', 'key': 'secret-key'}}))
        seen = {}

        def fake_get(url, headers, timeout=15):
            seen['url'] = url
            seen['headers'] = headers
            return {'usage': {
                'rolling': {'status': 'ok', 'percent': 1, 'resetsAt': '2026-10-14T02:15:05.000Z'},
                'weekly': {'status': 'ok', 'percent': 44, 'resetsAt': '2026-10-19T00:00:00.000Z'},
                'monthly': {'status': 'ok', 'percent': 77, 'resetsAt': '2026-10-28T12:50:54.000Z'}}}

        env = {'OPENCODE_AUTH': str(auth), 'USAGE_PACE_NOW': '2026-10-14T09:00:00+11:00',
               'HERMES_BIN': '/nonexistent', 'T3_CACHE_DIR': str(self.root / 'absent-t3')}
        with patch.dict(usage.os.environ, env):
            with patch.object(usage, 'http_get_json', fake_get):
                lines = usage.account_limit_lines()
        text = '\n'.join(lines)
        self.assertEqual('https://opencode.ai/zen/go/v1/usage', seen['url'])
        self.assertEqual('Bearer secret-key', seen['headers']['Authorization'])
        self.assertIn('OpenCode', lines)
        self.assertIn('- 5-Hour: 99% left, resets in 4h 15m (Under pace)', text)
        self.assertIn('- Weekly: 56% left, resets in 5d 2h (OVER PACE)', text)
        self.assertIn('- Monthly: 23% left, resets in 14d 14h (OVER PACE)', text)
        self.assertNotIn('secret-key', text)

    def test_usage_pace_reuses_t3_code_assessments(self):
        # T3 resolves the windows (including windowDurationMins, which the raw
        # endpoints omit) and defines the pace rule; the collector reuses both,
        # so the report reads the same as the T3 usage tab.
        cache = self.root / 't3'
        cache.mkdir(parents=True, exist_ok=True)
        (cache / 'codex.json').write_text(json.dumps({'usageLimits': {
            'windows': [{'id': 'primary', 'kind': 'weekly', 'label': 'Weekly',
                         'usedPercent': 25, 'windowDurationMins': 10080,
                         'resetsAt': '2026-10-20T05:04:13.000Z'}],
            'resetCredits': {'availableCount': 1}}}))
        (cache / 'opencode.json').write_text(json.dumps({'usageLimits': {
            'windows': [{'id': 'go_rolling', 'kind': 'session', 'label': 'Go \u00b7 Session',
                         'windowDurationMins': 300, 'usedPercent': 16,
                         'resetsAt': '2026-10-14T02:15:05.000Z'}]}}))
        env = {'T3_CACHE_DIR': str(cache), 'HERMES_BIN': '/nonexistent',
               'OPENCODE_AUTH': str(self.root / 'absent-auth.json'),
               'USAGE_PACE_NOW': '2026-10-14T09:00:00+11:00'}
        with patch.dict(usage.os.environ, env):
            lines = usage.account_limit_lines()
        self.assertEqual(['Codex', '- Weekly: 75% left, resets in 6d 7h (OVER PACE)',
                          '- Banked resets: 1', 'OpenCode',
                          '- 5-Hour: 84% left, resets in 4h 15m (On pace)'], lines)

    def test_usage_pace_opencode_go_degrades_without_leaking(self):
        auth = self.root / 'auth.json'
        self.root.mkdir(parents=True, exist_ok=True)
        auth.write_text(json.dumps({'opencode-go': {'type': 'api', 'key': 'secret-key'}}))
        import urllib.error
        env = {'OPENCODE_AUTH': str(auth), 'HERMES_BIN': '/nonexistent',
               'T3_CACHE_DIR': str(self.root / 'absent-t3')}
        with patch.dict(usage.os.environ, env):
            with patch.object(usage, 'http_get_json',
                              side_effect=urllib.error.HTTPError('u', 403, 'Forbidden', {}, None)):
                self.assertEqual(({}, 'usage request failed: HTTP 403'), usage.opencode_live())
                lines = usage.account_limit_lines()
        self.assertIn('- unavailable (usage request failed: HTTP 403)', lines)
        self.assertNotIn('secret-key', '\n'.join(lines))

unittest.main(argv=['steward'], verbosity=2)
PY
