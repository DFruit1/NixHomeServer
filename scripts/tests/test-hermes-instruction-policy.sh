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
from unittest.mock import patch

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
        for script in ('daily-steward-window.py','kanban-performance.py','kanban-blockers.py'):
            self.assertEqual((source / script).read_bytes(),
                (self.root / 'profiles/board-steward/scripts' / script).read_bytes())
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
        self.assertIn('--runtime-profile',
                      (self.root / 'scripts/hermes-behavior-trials.md').read_text())
        self.assertLess(len(result.split()), 1500)
        self.assertEqual(0, policy.install(self.root, check=True))

    def test_ambiguous_managed_blocks_fail_before_any_write(self):
        target = self.root / 'profiles/standard-implementer/SOUL.md'
        target.write_text(policy.FLEET_START + '\nMissing end\n')
        before = {p: p.read_bytes() for p in self.root.rglob('*') if p.is_file()}
        with self.assertRaises(ValueError):
            policy.install(self.root)
        self.assertEqual(before, {p: p.read_bytes() for p in self.root.rglob('*') if p.is_file()})

    def test_skills_only_reuses_project_sources_without_changing_runtime_settings(self):
        before = {p: p.read_bytes() for p in self.root.rglob('*') if p.is_file()}
        self.assertEqual(1, policy.install(self.root, check=True, skills_only=True))
        self.assertEqual(before, {p: p.read_bytes() for p in self.root.rglob('*') if p.is_file()})
        self.assertEqual(0, policy.install(self.root, skills_only=True))
        self.assertEqual(0, policy.install(self.root, check=True, skills_only=True))
        for path, original in before.items():
            if path.name != 'SOUL.md':
                self.assertEqual(original, path.read_bytes())
        for profile in ('standard-implementer', 'local-implementer', 'feature-reviewer'):
            home = self.root / 'profiles' / profile
            for skill in ('nixhomeserver-safe-change', 'nixhomeserver-module-change'):
                self.assertEqual((source.parents[1] / '.agents/skills' / skill / 'SKILL.md').read_bytes(),
                                 (home / 'skills/devops' / skill / 'SKILL.md').read_bytes())
            debug = home / 'skills/software-development/systematic-debugging/SKILL.md'
            self.assertEqual((source / 'instructions/systematic-debugging.md').read_bytes(), debug.read_bytes())
            self.assertTrue((debug.parent / 'LICENSE').is_file())
        self.assertFalse((self.root / 'profiles/board-steward/skills').exists())
        self.assertEqual(before[self.root / 'profiles/board-steward/SOUL.md'],
                         (self.root / 'profiles/board-steward/SOUL.md').read_bytes())
        self.assertFalse((self.root / 'profiles/head-coordinator/skills/software-development').exists())
        self.assertTrue((self.root / 'profiles/head-coordinator/skills/devops/nixhomeserver-shutdown-guard/SKILL.md').is_file())
        self.assertFalse((self.root / 'profiles/project-auditor/skills/software-development').exists())
        self.assertFalse((self.root / 'scripts/hermes-fleet-policy.md').exists())

    def test_skills_install_rejects_ambiguous_routing_before_any_write(self):
        target = self.root / 'profiles/feature-reviewer/SOUL.md'
        target.write_text('<!-- hermes-task-skills -->\nMissing end\n')
        before = {p: p.read_bytes() for p in self.root.rglob('*') if p.is_file()}
        with self.assertRaises(ValueError):
            policy.install(self.root, skills_only=True)
        self.assertEqual(before, {p: p.read_bytes() for p in self.root.rglob('*') if p.is_file()})

    def test_skill_refresh_preserves_and_backs_up_existing_profile_edits(self):
        default = self.root / 'SOUL.md'
        default.write_text('Retired routing profile; preserve.\n')
        target = self.root / 'profiles/local-implementer/skills/software-development/systematic-debugging/SKILL.md'
        target.parent.mkdir(parents=True)
        target.write_text('Existing customized debugging recipe.\n')
        original = target.read_bytes()
        unrelated = target.parent.parent / 'operator-skill/SKILL.md'
        unrelated.parent.mkdir()
        unrelated.write_text('Independent skill; preserve.\n')
        policy.install(self.root, skills_only=True)
        self.assertEqual('Retired routing profile; preserve.\n', default.read_text())
        self.assertEqual('Independent skill; preserve.\n', unrelated.read_text())
        self.assertTrue(any(p.read_bytes() == original for p in
                            (self.root / 'backups/instruction-policy').rglob('*') if p.is_file()))
        self.assertFalse(any(p.name == 'config.yaml' for p in policy.skill_changes(self.root)))
        # Changes to a canonical project skill propagate through the same installer.
        replacement = self.root / 'updated-project-skill.md'
        replacement.write_text('---\nname: nixhomeserver-safe-change\ndescription: Updated procedure\n---\n')
        sources = dict(policy.SKILL_SOURCES)
        sources['nixhomeserver-safe-change'] = (replacement, 'devops/nixhomeserver-safe-change/SKILL.md')
        with patch.dict(policy.SKILL_SOURCES, sources, clear=True):
            policy.install(self.root, skills_only=True)
            self.assertEqual(replacement.read_bytes(), (self.root /
                'profiles/local-implementer/skills/devops/nixhomeserver-safe-change/SKILL.md').read_bytes())


unittest.main(argv=['instruction-policy'], verbosity=2)
PY
