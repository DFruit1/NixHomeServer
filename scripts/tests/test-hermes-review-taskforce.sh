#!/usr/bin/env bash
set -euo pipefail
TESTS_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
python3 -B - "$TESTS_REPO_ROOT" <<'PY'
import hashlib
import importlib.util
import json
import os
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

    def fake_hermes(self, board, *args):
        self.calls.append((board, args))
        if args[0] == 'list':
            return self.tasks
        return {'id': 't_opportunity', 'assignee': 'project-auditor'}

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
