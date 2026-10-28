#!/usr/bin/env bash
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
python3 -B - "$repo" <<'PY'
from contextlib import closing
import importlib.util
import hashlib
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

source = Path(sys.argv[1]) / 'scripts/hermes'
sys.path.insert(0, str(source))

def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, source / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class StewardPolicyTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        import card_policy_audit
        cls.audit = card_policy_audit

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='hermes-steward-policy-test-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.now = int(time.time())
        for profile in ('standard-implementer', 'head-coordinator'):
            home = self.root / 'profiles' / profile
            home.mkdir(parents=True)
            (home / 'state.db').touch()
        self.db = self.root / 'kanban/boards/test/kanban.db'
        self.db.parent.mkdir(parents=True)
        with closing(sqlite3.connect(self.db)) as db, db:
            db.executescript('''
                CREATE TABLE tasks(id TEXT PRIMARY KEY,title TEXT,body TEXT,status TEXT,
                    block_kind TEXT,created_by TEXT,assignee TEXT);
                CREATE TABLE task_comments(id INTEGER PRIMARY KEY,task_id TEXT,author TEXT,
                    body TEXT,created_at INTEGER);
                CREATE TABLE task_links(parent_id TEXT,child_id TEXT);
                INSERT INTO tasks VALUES('t_one','Fix retries','Goal: Fix retries.','ready',
                    NULL,'head-coordinator','standard-implementer');
            ''')

    def comment(self, body, author='standard-implementer', created=None):
        with closing(sqlite3.connect(self.db)) as db, db:
            return db.execute('INSERT INTO task_comments(task_id,author,body,created_at) VALUES(?,?,?,?)',
                              ('t_one', author, body, self.now if created is None else created)).lastrowid

    def collect(self):
        return self.audit.collect(self.root, now=self.now)

    def test_clean_or_guard_rejected_writes_do_not_become_monitor_findings(self):
        self.assertEqual({'findings': [], 'warnings': []}, self.collect())
        self.comment('Update: Fixed retries.\nEvidence: Tests pass.\nNext: Review this task.')
        self.assertEqual([], self.collect()['findings'])

    def test_persisted_comment_bypass_is_reported_without_mutation_or_clock_churn(self):
        self.comment('Update: Fixed.\nEvidence: ' + 'x' * 400 + '\nNext: Review.')
        before = self.db.read_bytes()
        result = self.collect()
        self.assertEqual(before, self.db.read_bytes())
        finding, = result['findings']
        self.assertEqual('comment-format', finding['rule'])
        self.assertEqual('standard-implementer', finding['author'])
        self.assertEqual(result, self.audit.collect(self.root, now=self.now + 1))
        self.assertNotIn('x' * 20, json.dumps(self.audit.monitor_lines(self.root, now=self.now)))

    def test_dependencies_and_missing_graph_links_survive_unguarded_writes(self):
        self.comment('Update: Prepared.\nEvidence: Tests pass.\nNext: Wait for t_input.')
        with closing(sqlite3.connect(self.db)) as db, db:
            db.execute("UPDATE tasks SET status='blocked', block_kind='dependency'")
        self.assertEqual({'dependency-prose', 'unlinked-dependency'},
                         {f['rule'] for f in self.collect()['findings']})
        with closing(sqlite3.connect(self.db)) as db, db:
            db.execute("INSERT INTO task_links VALUES('t_input','t_one')")
        self.assertEqual({'dependency-prose'}, {f['rule'] for f in self.collect()['findings']})

    def test_native_protocols_owner_quotes_and_old_comment_format_are_not_reaudited(self):
        self.comment('A native transition waiting on t_input.', 'hermes-system')
        self.comment('Owner reply received: Wait for t_input.', 'head-coordinator')
        self.comment(json.dumps({'deployment_decision': {'reason': 'Wait for t_input.'}}), 'head-coordinator')
        self.comment('Historical verbose note. ' * 30, created=1)
        self.assertEqual([], self.collect()['findings'])

    def test_current_open_card_prose_is_checked_but_long_body_guidance_is_not_a_violation(self):
        with closing(sqlite3.connect(self.db)) as db, db:
            db.execute('UPDATE tasks SET body=?', ('Goal: Investigate.\nNotes: ' + 'scope ' * 300,))
        self.assertEqual([], self.collect()['findings'])
        with closing(sqlite3.connect(self.db)) as db, db:
            db.execute("UPDATE tasks SET body='Goal: Resume after t_input completes.'")
        finding, = self.collect()['findings']
        self.assertEqual('dependency-prose', finding['rule'])
        self.assertEqual('card', finding['location'])

    def test_exceeded_comment_budget_is_a_coordinator_finding(self):
        for _ in range(6):
            self.comment('Update: Fixed.\nEvidence: Tests pass.\nNext: None.')
        finding, = self.collect()['findings']
        self.assertEqual('comment-budget', finding['rule'])
        self.assertEqual('head-coordinator', self.audit.recipient(self.root, finding))

    def test_unreadable_board_is_unknown_instead_of_a_clean_audit(self):
        broken = self.root / 'kanban/boards/broken/kanban.db'
        broken.parent.mkdir()
        broken.write_text('not a database')
        self.assertTrue(self.collect()['warnings'])

    def test_old_over_budget_history_does_not_masquerade_as_a_fresh_guard_escape(self):
        for _ in range(6):
            self.comment('Historical note.', created=1)
        self.assertEqual([], self.collect()['findings'])

    def test_activation_grandfathers_existing_comments_without_hiding_new_escapes(self):
        self.comment('An old unstructured note.', created=self.now - 5)
        activation = self.root / self.audit.ACTIVATION
        activation.parent.mkdir()
        activation.write_text(json.dumps(dict(version=1, comment_since=self.now)))
        self.assertEqual([], self.collect()['findings'])
        self.comment('A new unstructured note.')
        self.assertEqual(1, len(self.collect()['findings']))

    def test_malformed_activation_is_unknown_instead_of_retroactive_findings(self):
        activation = self.root / self.audit.ACTIVATION
        activation.parent.mkdir()
        activation.write_text('[]')
        result = self.collect()
        self.assertEqual([], result['findings'])
        self.assertTrue(result['warnings'])

    def test_monitor_output_is_bounded_and_reports_omitted_findings(self):
        for _ in range(27):
            self.comment('A persisted unstructured note.')
        lines = self.audit.monitor_lines(self.root, self.now)
        self.assertEqual(24, sum(line.startswith('CARD_POLICY ') for line in lines))
        self.assertTrue(any(line.startswith('CARD_POLICY_MORE ') for line in lines))

    def test_handoff_receipt_suppresses_repeat_wakes_without_claiming_correction(self):
        self.comment('Persisted unstructured update.')
        item, = self.collect()['findings']
        key = hashlib.sha256(('steward-handoff:' + self.audit.report_request_id(item)).encode()).hexdigest()
        receipt = self.root / 'profiles/board-steward/cron/bot_chat_pending' / (key + '.json')
        receipt.parent.mkdir(parents=True)
        receipt.write_text(json.dumps(dict(id=key, status='queued', profile='standard-implementer')))
        lines = self.audit.monitor_lines(self.root, self.now)
        self.assertFalse(any(line.startswith('CARD_POLICY ') for line in lines))
        self.assertIn('handoff-only-not-corrected', '\n'.join(lines))
        self.assertEqual(1, len(self.collect()['findings']))
        receipt.write_text('{}')
        lines = self.audit.monitor_lines(self.root, self.now)
        self.assertFalse(any(line.startswith('CARD_POLICY ') for line in lines))
        self.assertTrue(any(line.startswith('CARD_POLICY_UNKNOWN ') for line in lines))

    def test_policy_report_uses_verified_author_and_deduplicates_without_changing_cards(self):
        handoff = load('policy_handoff', 'steward-coordinator-request.py')
        self.comment('A persisted unstructured update that bypassed the guard.')
        item, = self.collect()['findings']
        records = {}
        class Delivery:
            def defer(_, key, job, content, profile, home):
                value = dict(status='queued', profile=profile, content=content)
                if key in records:
                    self.assertEqual(records[key], value)
                records[key] = value
                return value
        before = self.db.read_bytes()
        args = dict(policy=(item['key'], item['version'], True))
        first = handoff.queue_request(self.root, None, None, Delivery(), **args)
        self.assertEqual(first, handoff.queue_request(self.root, None, None, Delivery(), **args))
        self.assertEqual('standard-implementer', first['target'])
        self.assertEqual(1, len(records))
        self.assertEqual(before, self.db.read_bytes())
        self.assertIn('preserve gates and historical comments', records[first['delivery_id']]['content'])
        with closing(sqlite3.connect(self.db)) as db, db:
            db.execute("UPDATE task_comments SET body='Update: Fixed.\nEvidence: Tests pass.\nNext: None.'")
        with self.assertRaisesRegex(ValueError, 'changed or cleared'):
            handoff.queue_request(self.root, None, None, Delivery(), **args)

    def test_author_routing_never_substitutes_the_assignee_or_an_owner(self):
        self.comment('Persisted unstructured update.', 'worker')
        item, = self.collect()['findings']
        self.assertEqual('head-coordinator', self.audit.recipient(self.root, item))
        for author in ('owner', '../standard-implementer', 'missing-profile'):
            self.assertEqual('head-coordinator', self.audit.recipient(self.root, dict(item, author=author)))

    def test_author_report_survives_the_native_interpreter_bridge_with_worker_pins(self):
        self.comment('An unstructured update persisted outside the guard.')
        item, = self.collect()['findings']
        scripts = self.root / 'scripts'
        scripts.mkdir()
        for name in ('steward-coordinator-request.py','card_policy_audit.py',
                     'owner-blocker-authoring-guard.py','card-dependency-guard.py'):
            (scripts / name).write_bytes((source / name).read_bytes())
        native = self.root / 'hermes-agent'
        (native / 'cron').mkdir(parents=True)
        (native / 'cron/__init__.py').write_text('')
        (native / 'cron/bot_chat_delivery.py').write_text(
            'import os\ndef defer(key, job, content, profile, home):\n'
            '    assert profile == "standard-implementer"\n'
            '    assert os.environ["HERMES_KANBAN_TASK"] == "t_preserved"\n'
            '    assert os.environ["HERMES_DELEGATED_CHILD_CONTEXT"] == "preserved"\n'
            '    return {"status":"queued"}\n')
        subprocess.run([sys.executable,'-m','venv','--without-pip',str(native / '.venv')], check=True)
        env = dict(os.environ, HERMES_ROOT=str(self.root), HERMES_KANBAN_TASK='t_preserved',
                   HERMES_DELEGATED_CHILD_CONTEXT='preserved')
        result = subprocess.run([sys.executable,'-I','-B',str(scripts / 'steward-coordinator-request.py'),
            '--policy-report',item['key'],item['version'],'--to-author'], env=env, text=True, capture_output=True)
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        self.assertEqual('standard-implementer', json.loads(result.stdout)['target'])

    def test_policy_reporting_helper_is_a_narrow_readonly_exception(self):
        guard = load('policy_steward_guard', 'steward-readonly-guard.py')
        command = f'python3 {self.root}/scripts/steward-coordinator-request.py --policy-report ' + 'a' * 24 + ' ' + 'b' * 64
        for tail in ('', ' --to-author'):
            request = dict(tool_name='terminal', tool_input=dict(command=command + tail))
            self.assertEqual('modify', guard.guard(request, self.root, source.parent.parent).get('action'))
        request['tool_input']['command'] = command + ' --target owner'
        self.assertEqual('block', guard.guard(request, self.root, source.parent.parent).get('action'))
        request = dict(tool_name='message_agent', tool_input=dict(target='standard-implementer', message='Do work.'))
        self.assertEqual('block', guard.guard(request, self.root, source.parent.parent).get('action'))

    def test_scoped_install_updates_only_monitor_policy_and_its_existing_prompt(self):
        installer = load('policy_installer', 'install-steward-readonly.py')
        home = self.root / 'profiles/board-steward'
        home.mkdir()
        (home / 'SOUL.md').write_text('# Steward\n')
        config = home / 'config.yaml'
        config.write_text('model: preserve\nagent: {max_turns: 42}\n')
        jobs = home / 'cron/jobs.json'
        jobs.parent.mkdir()
        before = dict(id='existing', name='steward opportunity scan', monitor_script='steward-opportunity-scan.py',
                      prompt='old', enabled=False, schedule={'minutes': 120}, skills=['board-steward'])
        jobs.write_text(json.dumps({'jobs': [before]}))
        def native(command, **kwargs):
            self.assertEqual(['hermes','--profile','board-steward','cron','edit','existing','--prompt'], command[:7])
            jobs.write_text(json.dumps({'jobs': [dict(before, prompt=command[7])]}))
        original = config.read_bytes(), self.db.read_bytes()
        with patch.object(installer.subprocess, 'run', native):
            self.assertEqual(1, installer.install(self.root, source.parent.parent, check=True, policy_monitor_only=True))
            self.assertFalse((self.root / 'scripts').exists())
            self.assertEqual(0, installer.install(self.root, source.parent.parent, policy_monitor_only=True))
            self.assertEqual(0, installer.install(self.root, source.parent.parent, check=True, policy_monitor_only=True))
        self.assertEqual(original, (config.read_bytes(), self.db.read_bytes()))
        updated, = json.loads(jobs.read_text())['jobs']
        self.assertEqual(before, dict(updated, prompt='old'))
        self.assertIn('CARD_POLICY', updated['prompt'])


unittest.main(argv=['steward-card-policy'], verbosity=2)
PY
