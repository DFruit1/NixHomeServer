#!/usr/bin/env bash
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
python3 -B - "$repo" <<'PY'
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
import sys

source = Path(sys.argv[1]) / 'scripts/hermes'
spec = importlib.util.spec_from_file_location('instructions', source / 'install-instruction-policy.py')
policy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(policy)


class InstructionPolicyTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='nixhomeserver-instruction-policy-test-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        for name in policy.PROFILES:
            home = self.root / 'profiles' / name
            home.mkdir(parents=True)
            (home / 'SOUL.md').write_text('# ' + name + '\n\n## Operator note\nKeep this exact note.\n')
            (home / 'config.yaml').write_text('model: unchanged\napprovals: unchanged\n')
        (self.root / 'profiles/head-coordinator/cron').mkdir()
        self.jobs = self.root / 'profiles/head-coordinator/cron/jobs.json'
        self.jobs.write_text(json.dumps({'jobs': [{'name': 'kanban idle recovery',
            'prompt': 'Receipt: preserve exact task, custody, owner and no-retry conditions.'}]}))
        self.metadata = self.root / 'profiles/standard-implementer/profile.yaml'
        self.metadata.write_text('description: Old fixed-model promise\ndescription_auto: false\nprevious_names: [bulk-go]\n')

    def test_install_is_reversible_idempotent_and_keeps_runtime_settings(self):
        settings = {p: p.read_bytes() for p in self.root.glob('profiles/*/config.yaml')}
        settings[self.jobs] = self.jobs.read_bytes()
        original = self.root / 'profiles/head-coordinator/SOUL.md'
        before = original.read_bytes()
        self.assertEqual(1, policy.install(self.root, check=True))
        self.assertEqual(before, original.read_bytes())
        self.assertEqual(0, policy.install(self.root))
        self.assertEqual(0, policy.install(self.root, check=True))
        self.assertTrue(any(p.read_bytes() == before for p in
                            (self.root / 'backups/instruction-policy').rglob('*') if p.is_file()))
        self.assertEqual(settings, {p: p.read_bytes() for p in settings})
        self.assertIn('previous_names: [bulk-go]', self.metadata.read_text())
        self.assertIn('Models and fallbacks come from configuration', self.metadata.read_text())
        for name in policy.PROFILES:
            text = (self.root / 'profiles' / name / 'SOUL.md').read_text()
            self.assertIn('Keep this exact note.', text)
            self.assertIn('Hermes fleet rules', text)
            self.assertIn('worker pins', text)
        # Fleet rules reach plain-directory projects without creating project files.
        self.assertFalse((self.root / 'AGENTS.md').exists())

    def test_legacy_coordinator_migration_preserves_independent_policy(self):
        text = ('# head-coordinator\n\nOld introduction.\n## Tiers\nOld routing.\n'
                '## Operator note\nKeep this exact note.\n'
                '<!-- hermes-review-taskforce -->\nKeep taskforce.\n'
                '<!-- /hermes-review-taskforce -->\n'
                '## Deploy gate (guarded test & switch)\nOld deploy.\n'
                '## Board health\nOld health.\n'
                '<!-- kanban-owner-alerts -->\nKeep authenticated replies.\n'
                '<!-- /kanban-owner-alerts -->\n')
        target = self.root / 'profiles/head-coordinator/SOUL.md'
        target.write_text(text)
        policy.install(self.root)
        result = target.read_text()
        for retained in ['Keep this exact note.', 'Review and improvement',
                         'Record the verbatim authenticated owner reply FIRST']:
            self.assertIn(retained, result)
        self.assertNotIn('Old routing.', result)
        self.assertIn('nix run .#deploy', result)
        self.assertIn('WORKER_FAILED_BLOCKED', result)
        reference = self.root / 'scripts/hermes-coordinator-reference.md'
        self.assertIn('At most one dependency repair', reference.read_text())
        self.assertIn('compact_complete', reference.read_text())
        self.assertLess(len(result.split()), 1500)
        self.assertEqual(0, policy.install(self.root, check=True))

    def test_ambiguous_managed_blocks_fail_before_any_write(self):
        target = self.root / 'profiles/standard-implementer/SOUL.md'
        target.write_text(policy.FLEET_START + '\nMissing end\n')
        before = {p: p.read_bytes() for p in self.root.rglob('*') if p.is_file()}
        with self.assertRaises(ValueError):
            policy.install(self.root)
        self.assertEqual(before, {p: p.read_bytes() for p in self.root.rglob('*') if p.is_file()})


unittest.main(argv=['instruction-policy'], verbosity=2)
PY
