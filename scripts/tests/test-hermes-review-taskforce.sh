#!/usr/bin/env bash
set -euo pipefail
TESTS_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
python3 -B - "$TESTS_REPO_ROOT" <<'PY'
from contextlib import closing
import hashlib
import importlib.util
import json
import os
import sqlite3
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import sys

spec = importlib.util.spec_from_file_location('taskforce', Path(sys.argv[1]) / 'scripts/hermes/review-taskforce.py')
tf = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tf)
installer_spec = importlib.util.spec_from_file_location('installer', Path(sys.argv[1]) / 'scripts/hermes/install-review-taskforce.py')
installer = importlib.util.module_from_spec(installer_spec)
installer_spec.loader.exec_module(installer)

class TaskforceTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        (self.root / 'repo').mkdir()
        self.calls = []
        self.tasks = []
        self.now = 1791500000
        for slug, cadence in [('daily', 'daily'), ('weekly', 'weekly'), ('off', 'off')]:
            board = self.root / 'kanban/boards' / slug
            board.mkdir(parents=True)
            (board / 'board.json').write_text(json.dumps({'default_workdir': str(self.root / 'repo')}))
            tf.configure(self.root, slug, cadence)
        self.api = patch.object(tf, 'hermes', self.fake_hermes)
        self.api.start()
        self.addCleanup(self.api.stop)
        self.inventory = patch.object(tf, "board_tasks", lambda root, board: self.tasks)
        self.inventory.start()
        self.addCleanup(self.inventory.stop)

    def fake_hermes(self, board, *args):
        self.calls.append((board, args))
        if args[0] == 'list':
            return self.tasks
        return {'id': 't_opportunity', 'assignee': 'project-auditor'}

    def test_read_only_inventory_under_delegated_worker_fence(self):
        self.inventory.stop()
        fields = 'id TEXT, title TEXT, body TEXT, assignee TEXT, status TEXT, tenant TEXT, created_by TEXT'
        for board, task_id in [('daily', 't_daily'), ('weekly', 't_weekly'), ('off', None)]:
            path = self.root / 'kanban/boards' / board / 'kanban.db'
            with closing(sqlite3.connect(path)) as db:
                db.execute('CREATE TABLE tasks (' + fields + ')')
                if task_id is None:
                    continue
                db.execute('INSERT INTO tasks VALUES (?, ?, ?, ?, ?, ?, ?)',
                           (task_id, 'Active implementation', 'Change: modules/immich/default.nix',
                            'standard-implementer', 'running', 'normal', 'user'))
                db.commit()
        fence = {'HERMES_DELEGATED_CHILD_CONTEXT': str(self.root / 'kanban/boards/daily'),
                 'HERMES_KANBAN_DB': str(self.root / 'kanban/boards/daily/kanban.db')}
        before = {p: p.read_bytes() for p in self.root.glob('kanban/boards/*/kanban.db')}
        with patch.dict(os.environ, fence), patch.object(tf, 'hermes', side_effect=AssertionError('CLI read')):
            status = tf.board_status(self.root, 'daily')
            self.assertEqual(['t_daily'], [t['id'] for t in status['tasks']])
            conflicts = tf.scope_conflicts(self.root, 'daily', ['modules/immich/'])
            self.assertEqual({'t_daily', 't_weekly'}, {t['task_id'] for t in conflicts})
            self.assertEqual(fence['HERMES_DELEGATED_CHILD_CONTEXT'],
                             os.environ['HERMES_DELEGATED_CHILD_CONTEXT'])
        self.assertEqual(before, {p: p.read_bytes() for p in before})
        (self.root / 'kanban/boards/off/kanban.db').unlink()
        with self.assertRaises(sqlite3.OperationalError):
            tf.board_tasks(self.root, 'off')
        self.assertFalse((self.root / 'kanban/boards/off/kanban.db').exists())

    def test_cadence_and_on_demand_disabled(self):
        tf.tick(self.root, self.now)
        self.assertEqual(2, len([c for c in self.calls if c[1][0] == 'create']))
        self.calls.clear()
        tf.tick(self.root, self.now + 3600)
        self.assertFalse(any(c[1][0] == 'create' for c in self.calls))
        tf.tick(self.root, self.now + 86400)
        creates = [c for c in self.calls if c[1][0] == 'create']
        self.assertEqual(['daily'], [c[0] for c in creates])
        body = creates[0][1][creates[0][1].index('--body') + 1]
        self.assertLessEqual(len(body.splitlines()), 15)
        self.assertLessEqual(len(body), 1000)
        self.assertTrue(all(len(line) < 90 for line in body.splitlines()))

    def test_pending_opportunity_prevents_queue_growth(self):
        self.tasks = [{'id': 't_old', 'assignee': 'project-auditor', 'tenant': tf.TENANT,
                       'title': tf.OPPORTUNITY_TITLE, 'status': 'blocked'}]
        tf.tick(self.root, self.now)
        self.assertFalse(any(c[1][0] == 'create' for c in self.calls))

    def test_failed_create_does_not_advance_schedule(self):
        def fail(board, *args):
            if args[0] == 'create':
                raise RuntimeError('offline')
            return []
        with patch.object(tf, 'hermes', fail):
            with self.assertRaises(RuntimeError):
                tf.tick(self.root, self.now)
        tf.tick(self.root, self.now)
        self.assertTrue(any(c[1][0] == 'create' for c in self.calls))

    def test_configure_preserves_findings_and_validates_inputs(self):
        document = tf.review_dir(self.root, 'daily') / 'FINDINGS.md'
        document.write_text('existing decisions\n')
        tf.configure(self.root, 'daily', 'weekly')
        self.assertEqual('existing decisions\n', document.read_text())
        with self.assertRaises(ValueError):
            tf.configure(self.root, '../escape', 'daily')
        with self.assertRaises(ValueError):
            tf.configure(self.root, 'daily', 'every-minute')
        with self.assertRaises(ValueError):
            tf.configure(self.root, 'daily', 'custom', 0)

    def test_only_reviewer_writes_with_stale_write_protection(self):
        path = tf.review_dir(self.root, 'daily') / 'FINDINGS.md'
        previous = tf.digest(path)
        with patch.dict(os.environ, {'HERMES_PROFILE': 'feature-reviewer'}):
            with self.assertRaises(PermissionError):
                tf.write_document(self.root, 'daily', 'FINDINGS.md', '# Findings\n', previous)
        with patch.dict(os.environ, {'HERMES_PROFILE': 'project-auditor'}):
            tf.write_document(self.root, 'daily', 'FINDINGS.md', '# Findings\n', previous)
            with self.assertRaises(ValueError):
                tf.write_document(self.root, 'daily', 'FINDINGS.md', '# Lost update\n', previous)
            tf.write_document(self.root, 'daily', 'plans/batch-1.md', '# Plan\n', None)
            tf.write_document(self.root, 'daily', 'plans/batch-1.md', '# Plan\n', None)
            with self.assertRaises(ValueError):
                tf.write_document(self.root, 'daily', 'plans/batch-1.md', '# Changed\n', None)
        self.assertEqual('# Findings\n', path.read_text())

    def test_conflicting_or_unknown_active_work_blocks_audit(self):
        self.tasks = [{'id': 't_impl', 'assignee': 'standard-implementer', 'status': 'running',
                       'body': 'Change: modules/immich/default.nix — adjust limits', 'title': 'Fix Immich'}]
        self.assertTrue(tf.scope_conflicts(self.root, 'daily', ['modules/immich/']))
        self.assertFalse(tf.scope_conflicts(self.root, 'daily', ['modules/paperless/']))
        self.tasks[0]['body'] = 'Implement the requested changes'
        self.assertTrue(tf.scope_conflicts(self.root, 'daily', ['modules/paperless/']))
        self.tasks[0]['status'] = 'done'
        self.assertFalse(tf.scope_conflicts(self.root, 'daily', ['modules/immich/']))

    def test_disabled_default_and_custom_cadence(self):
        board = self.root / 'kanban/boards/unconfigured'
        board.mkdir()
        (board / 'board.json').write_text('{}')
        tf.configure(self.root, 'daily', 'custom', 48)
        tf.tick(self.root, self.now)
        self.calls.clear()
        tf.tick(self.root, self.now + 86400)
        self.assertFalse(any(c[0] == 'daily' and c[1][0] == 'create' for c in self.calls))
        self.assertFalse(any(c[0] == 'unconfigured' for c in self.calls))

    def test_new_board_supports_on_demand_without_enabling_schedules(self):
        board = self.root / 'kanban/boards/newproject'
        board.mkdir()
        (board / 'board.json').write_text('{}')
        status = tf.board_status(self.root, 'newproject')
        self.assertEqual('off', status['config']['cadence'])
        self.assertEqual('missing', status['findings_sha256'])
        self.assertFalse((board / 'review-taskforce').exists())
        with patch.dict(os.environ, {'HERMES_PROFILE': 'project-auditor'}):
            tf.write_document(self.root, 'newproject', 'FINDINGS.md', '# First audit\n', 'missing')
        self.assertFalse((board / 'review-taskforce/config.json').exists())

    def test_one_broken_board_does_not_starve_other_projects(self):
        def one_failure(board, *args):
            if board == 'daily' and args[0] == 'create':
                raise RuntimeError('offline')
            return self.fake_hermes(board, *args)
        with patch.object(tf, 'hermes', one_failure):
            with self.assertRaises(RuntimeError):
                tf.tick(self.root, self.now)
        self.assertTrue(any(c[0] == 'weekly' and c[1][0] == 'create' for c in self.calls))

    def good_report(self, **overrides):
        report = {
            'slice': 'homepage canary', 'question': 'Does an interrupted run certify a pass?',
            'scope_paths': ['modules/Core_Modules/homepage/canary.nix'],
            'revision': 'a' * 40, 'outcome': 'findings', 'priority_served': 'P3',
            'findings': [{
                'file': 'modules/Core_Modules/homepage/canary.nix', 'line': 78,
                'severity': 'medium', 'axis': 'correctness',
                'evidence': 'assert reads latest.json only', 'suggested_fix': 'invalidate',
                'benefit': 'no stale pass', 'tradeoffs': 'state model work',
                'verification': 'bash scripts/tests/test-canary-render-check.sh', 'confidence': 'verified',
            }],
            'checked_and_clean': ['trigger exit-75 overlap guard'],
            'unknowns': ['systemd stop ordering'],
            'checks': [{'command': 'true', 'exit_code': 0}],
        }
        report.update(overrides)
        return report

    def test_validate_report_accepts_and_rejects(self):
        self.assertEqual([], tf.validate_report(self.good_report()))
        self.assertIn('revision must be a non-empty string', tf.validate_report(self.good_report(revision=None)))
        self.assertIn('outcome must be one of', tf.validate_report(self.good_report(outcome='audit'))[0])
        findings = self.good_report()['findings'][0]
        findings['severity'] = 'high'
        self.assertTrue(any('severity high requires an executed check' in v
                            for v in tf.validate_report(self.good_report(findings=[findings], checks=[]))))
        findings['confidence'] = 'inferred'
        self.assertIn('findings[0] severity high requires confidence verified',
                      tf.validate_report(self.good_report(findings=[findings])))
        self.assertTrue(any('scope_paths entry is not project-relative' in v
                            for v in tf.validate_report(self.good_report(scope_paths=['/etc/passwd']))))
        self.assertIn('outcome findings requires at least one finding',
                      tf.validate_report(self.good_report(findings=[])))
        self.assertTrue(any('checks[0] needs an integer exit_code' in v
                            for v in tf.validate_report(self.good_report(checks=[{'command': 'true'}]))))
        leaked = self.good_report()['findings'][0]
        leaked['evidence'] = '-----BEGIN OPENSSH PRIVATE KEY-----'
        self.assertTrue(any('possible secret material' in v
                            for v in tf.validate_report(self.good_report(findings=[leaked]))))
        self.assertEqual([], tf.validate_report(self.good_report(outcome='clean', findings=[])))

    def test_reports_namespace_roles_and_immutability(self):
        with patch.dict(os.environ, {'HERMES_PROFILE': 'feature-reviewer'}):
            tf.write_document(self.root, 'daily', 'reports/t_1-canary.md', '# Report\n', None)
            tf.write_document(self.root, 'daily', 'reports/t_1-canary.md', '# Report\n', None)
            with self.assertRaises(ValueError):
                tf.write_document(self.root, 'daily', 'reports/t_1-canary.md', '# Rewrite\n', None)
            with self.assertRaises(PermissionError):
                tf.write_document(self.root, 'daily', 'plans/batch-1.md', '# Plan\n', None)
        with self.assertRaises(ValueError):
            tf.write_document(self.root, 'daily', 'audits/t_1.md', '# Anywhere\n', None)
        self.assertEqual('# Report\n',
                         (tf.review_dir(self.root, 'daily') / 'reports/t_1-canary.md').read_text())

    def test_classify_trips_approval_rules(self):
        hits = tf.classify_paths(self.root, 'daily', ['custom_apps/rust/apps/media-manager/Cargo.toml'])
        self.assertEqual(['2'], [hit['rule'] for hit in hits])
        hits = tf.classify_paths(self.root, 'daily', ['modules/Core_Modules/homepage/canary.nix',
                                                     'custom_apps/node/apps/homepage/src/client/styles.css',
                                                     'modules/immich/default.nix'])
        self.assertEqual({'1', '3'}, {hit['rule'] for hit in hits})
        self.assertEqual([], tf.classify_paths(self.root, 'daily', ['modules/immich/default.nix']))
        with self.assertRaises(ValueError):
            tf.classify_paths(self.root, 'daily', ['/etc'])
        override = tf.review_dir(self.root, 'daily') / 'classify.json'
        override.write_text(json.dumps({'rules': {'5': {'label': 'docs', 'paths': ('documentation',)}}}))
        self.assertEqual([{'rule': '5', 'label': 'docs', 'path': 'documentation/operations.md',
                           'reasons': ['under documentation/']}],
                         tf.classify_paths(self.root, 'daily', ['documentation/operations.md']))

    def test_findings_index_links_and_chain_cap(self):
        with patch.dict(os.environ, {'HERMES_PROFILE': 'standard-implementer'}):
            with self.assertRaises(PermissionError):
                tf.findings_mint(self.root, 'daily')
        with patch.dict(os.environ, {'HERMES_PROFILE': 'project-auditor'}):
            self.assertEqual('CI-001', tf.findings_mint(self.root, 'daily')['id'])
            tf.findings_mint(self.root, 'daily', 'CI-COV-002', feature='canary')
            with self.assertRaises(ValueError):
                tf.findings_mint(self.root, 'daily', 'CI-COV-002')
            tf.findings_link(self.root, 'daily', 'CI-COV-002', 't_audit1', 'audit')
            tf.findings_link(self.root, 'daily', 'CI-COV-002', 't_audit1', 'audit')
            tf.findings_link(self.root, 'daily', 'CI-COV-002', 't_assess1', 'assessment')
            tf.findings_set_status(self.root, 'daily', 'CI-COV-002', 'deferred')
            with self.assertRaises(ValueError):
                tf.findings_link(self.root, 'daily', 'CI-NOPE', 't_x', 'audit')
        self.assertEqual(['CI-001', 'CI-COV-002'], [e['id'] for e in tf.findings_load(self.root, 'daily')])
        entry = tf.finding_entry(self.root, 'daily', 'CI-COV-002')
        self.assertEqual({('t_audit1', 'audit'), ('t_assess1', 'assessment')},
                         {(t['task_id'], t['role']) for t in entry['tasks']})
        self.assertEqual('deferred', entry['status'])
        self.tasks = [{'id': 't_audit2', 'assignee': tf.REVIEWER, 'tenant': tf.TENANT,
                       'status': 'done', 'body': 'Notes:\n- Read CI-COV-002 in FINDINGS.md.', 'title': 'Audit'}]
        audits = tf.finding_audit_count(self.root, 'daily', 'CI-COV-002')
        self.assertEqual({'t_audit1', 't_audit2'}, audits)
        with patch.dict(os.environ, {'HERMES_PROFILE': 'project-auditor'}):
            tf.configure(self.root, 'daily', 'daily', max_audits_per_finding=2)
        self.assertFalse(tf.chain_check(self.root, 'daily', 'CI-COV-002'))
        tf.configure(self.root, 'daily', 'daily', max_audits_per_finding=3)
        self.assertTrue(tf.chain_check(self.root, 'daily', 'CI-COV-002'))

    def test_record_audit_feeds_state_and_suppression(self):
        path = tf.review_dir(self.root, 'daily') / 'report-metadata.json'
        path.write_text(json.dumps(self.good_report()))
        with patch.dict(os.environ, {'HERMES_PROFILE': 'feature-reviewer'}):
            tf.record_audit(self.root, 'daily', 't_audit1', metadata=str(path), duration_seconds=900)
        metrics = tf.read_jsonl(tf.metrics_index(self.root, 'daily'))
        self.assertEqual(1, len(metrics))
        self.assertEqual('findings', metrics[0]['outcome'])
        self.assertEqual(1, metrics[0]['findings'])
        self.assertEqual(900, metrics[0]['duration_seconds'])
        tf.tick(self.root, self.now)
        body = [c[1][c[1].index('--body') + 1] for c in self.calls if c[1][0] == 'create' and c[0] == 'daily'][0]
        self.assertIn('State: 0 open findings; last audit t_audit1: findings (1 finding).', body)
        self.assertLessEqual(len(body.splitlines()), 15)
        self.assertLessEqual(len(body), 1000)
        self.assertTrue(all(len(line) < 90 for line in body.splitlines()))
        for index in range(3):
            with patch.dict(os.environ, {'HERMES_PROFILE': 'feature-reviewer'}):
                tf.record_audit(self.root, 'daily', f't_clean{index}', outcome='clean')
        self.calls.clear()
        tf.tick(self.root, self.now + 86400)
        self.assertFalse(any(c[1][0] == 'create' for c in self.calls))
        with patch.dict(os.environ, {'HERMES_PROFILE': 'feature-reviewer'}):
            tf.record_audit(self.root, 'daily', 't_defer', outcome='deferred_active_work')
        tf.tick(self.root, self.now + 2 * 86400)
        self.assertTrue(any(c[0] == 'daily' and c[1][0] == 'create' for c in self.calls))

    def test_pending_implementer_work_warns_without_blocking(self):
        self.tasks = [{'id': 't_queued', 'assignee': 'standard-implementer', 'status': 'ready',
                       'body': 'Change: modules/immich/default.nix — adjust limits', 'title': 'Fix Immich'}]
        self.assertFalse(tf.scope_conflicts(self.root, 'daily', ['modules/immich/']))
        pending = tf.pending_overlaps(self.root, 'daily', ['modules/immich/'])
        self.assertEqual(['t_queued'], [task['task_id'] for task in pending])
        self.tasks = [{'id': 't_running', 'assignee': 'local-implementer', 'status': 'running',
                       'body': 'Scope: modules/immich/\nNotes:\n- unrelated', 'title': 'Fix Immich'}]
        self.assertEqual(['t_running'], [t['task_id'] for t in tf.scope_conflicts(self.root, 'daily', ['modules/immich/'])])

    def test_installer_preserves_unrelated_policies_and_is_idempotent(self):
        head = ('# head-coordinator\n\n## Tiers\n'
                '| `feature-reviewer` | One named feature/module/subsystem needs a focused correctness/reliability/performance audit. Cheap, runs often. |\n'
                'Scoped audit needed → `feature-reviewer`.\n'
                '## Requesting an audit on demand\nOld direct routing.\n'
                '## Deploy gate\nPreserve this deploy policy.\n')
        for name in installer.DESCRIPTIONS:
            directory = self.root / 'profiles' / name
            directory.mkdir(parents=True)
            (directory / 'SOUL.md').write_text(head if name == 'head-coordinator' else
                '# Profile\n\n- **Never leave your workspace.**\n\n## Whole-change-set deploy review\nPreserve verifier.\n')
            (directory / 'profile.yaml').write_text('description: old role\ndescription_auto: false\nprevious_names:\n  - old-name\n')
            (directory / 'config.yaml').write_text('model:\n  default: unchanged-model\nplatform_toolsets:\n  cli: [file, terminal]\n  desktop: [file, terminal]\n')
        original = (self.root / 'profiles/head-coordinator/SOUL.md').read_text()
        self.assertEqual(1, installer.install(self.root, check=True, cron=False))
        self.assertEqual(original, (self.root / 'profiles/head-coordinator/SOUL.md').read_text())
        installer.install(self.root, cron=False)
        self.assertEqual(0, installer.install(self.root, check=True, cron=False))
        installed_head = (self.root / 'profiles/head-coordinator/SOUL.md').read_text()
        self.assertIn('Preserve this deploy policy.', installed_head)
        self.assertNotIn('Old direct routing.', installed_head)
        self.assertIn('explicit architecture, software stack,', installed_head)
        self.assertIn('previous_names:', (self.root / 'profiles/project-auditor/profile.yaml').read_text())
        self.assertIn('unchanged-model', (self.root / 'profiles/project-auditor/config.yaml').read_text())
        self.assertIn('kanban', (self.root / 'profiles/project-auditor/config.yaml').read_text())
        self.assertIn('desktop: [file, terminal, kanban]', (self.root / 'profiles/project-auditor/config.yaml').read_text())
        self.assertTrue((self.root / 'scripts/review-taskforce-approval.md').is_file())

unittest.main(argv=['taskforce'], verbosity=2)
PY
