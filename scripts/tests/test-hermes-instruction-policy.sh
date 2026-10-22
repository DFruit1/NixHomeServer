#!/usr/bin/env bash
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
python3 -B - "$repo" <<'PY'
import importlib.util
import json
import re
from pathlib import Path
import tempfile
import unittest
import sys
from unittest.mock import patch

source = Path(sys.argv[1]) / 'scripts/hermes'
# The installers import sibling helpers (hermes_common, hermes_config) by
# module name; loading them from this suite needs their directory on sys.path.
sys.path.insert(0, str(source))
spec = importlib.util.spec_from_file_location('instructions', source / 'install-instruction-policy.py')
policy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(policy)


def load_installer(name, filename):
    """Load a sibling composition installer as this suite loads policy."""
    module_spec = importlib.util.spec_from_file_location(name, source / filename)
    module = importlib.util.module_from_spec(module_spec)
    module_spec.loader.exec_module(module)
    return module


class InstructionPolicyTest(unittest.TestCase):
    def test_installed_review_instructions_deliver_exact_completion_scope(self):
        policy.install(self.root)
        text = (self.root / 'scripts/hermes-review-evidence.md').read_text()
        self.assertIn('Pass explicit `board` and `task_id` to `kanban_complete`', text)
        self.assertIn('shell-hook subprocess removes worker task/run identity', text)
        self.assertIn('stop-on-refusal', text)
        self.assertIn('never infer scope from cwd', text)
        rule = 'Pass explicit `board` and `task_id` to `kanban_complete`'
        for name in policy.REVIEW_SKILL_PROFILES:
            self.assertIn(rule, (self.root / 'profiles' / name / 'SOUL.md').read_text(), name)
        self.assertIn(rule, (self.root / 'scripts/hermes-fleet-policy.md').read_text())
        self.assertNotIn(rule, (self.root / 'profiles/board-steward/SOUL.md').read_text())

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

    def test_workspace_repair_and_readonly_inventory_ship_together(self):
        pending=policy.changes(self.root)
        for filename in ('repair-task-workspace.py','steward-board-read.py'):
            self.assertEqual((source/filename).read_text(),pending[self.root/'scripts'/filename])
        self.assertEqual((source.parents[1]/'documentation/hermes-workspace-repair.md').read_text(),
                         pending[self.root/'scripts/hermes-workspace-repair.md'])

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
            if name == 'board-steward':
                # The read-only steward carries a bounded boundary, not lane rules.
                self.assertIn('Fleet boundary', text)
                self.assertIn('hermes-fleet-policy.md', text)
                self.assertNotIn('Never remove worker pins', text)
            else:
                self.assertIn('Hermes fleet rules', text)
                self.assertIn('worker pins', text)
        # Fleet rules reach plain-directory projects without creating project files.
        self.assertFalse((self.root / 'AGENTS.md').exists())

    def test_auditor_review_authority_reaches_legacy_intro_metadata_and_skills(self):
        auditor = self.root / 'profiles/project-auditor'
        old = ('Standing rules: never implement, never verify a\n'
               'diff or deploy range yourself (that verdict is `feature-reviewer`\'s card, not\n'
               'yours), never edit source, never forward a plan you have not assessed, and back\n'
               'every decision with the evidence you actually checked.')
        (auditor / 'SOUL.md').write_text('# project-auditor\n' + old + '\n\n## Operator note\nKeep this exact note.\n')
        (auditor / 'profile.yaml').write_text('name: project-auditor\ndescription: Never verifies.\n')
        policy.install(self.root)
        soul = (auditor / 'SOUL.md').read_text()
        self.assertNotIn('never verify a', soul)
        self.assertIn('Keep this exact note.', soul)
        self.assertIn('independent', (auditor / 'profile.yaml').read_text().lower())
        self.assertTrue((auditor / 'skills/devops/sdlc-review/SKILL.md').is_file())
        self.assertEqual(0, policy.install(self.root, check=True))

    def test_credential_only_routing_reaches_every_profile_and_local_role(self):
        local = self.root / 'profiles/local-implementer'
        soul = local / 'SOUL.md'
        soul.write_text('## Operator note\nKeep this exact note.\n'
                        '<!-- hermes-review-taskforce -->\n'
                        'Old broad private-data routing.\n'
                        '<!-- /hermes-review-taskforce -->\n')
        (local / 'profile.yaml').write_text('description: Confidential work only\nmodel: keep\n')
        policy.install(self.root)
        for name in policy.PROFILES:
            text = (self.root / 'profiles' / name / 'SOUL.md').read_text()
            if name == 'board-steward':
                # The steward never routes credentials or reclaims workers.
                self.assertNotIn('Credential-only local routing', text)
                self.assertIn('refusal stays refused', text)
                continue
            self.assertIn('Credential-only local routing', text)
            self.assertIn('only the smallest step', text.lower())
            self.assertIn('running worker', text)
        self.assertNotIn('Old broad private-data routing', soul.read_text())
        self.assertIn('Keep this exact note.', soul.read_text())
        self.assertIn('model: keep', (local / 'profile.yaml').read_text())
        self.assertIn('actual passwords', (local / 'profile.yaml').read_text())
        self.assertEqual(0, policy.install(self.root, check=True))

    def test_readonly_steward_gets_a_bounded_fleet_block_from_every_writer(self):
        # The steward cannot commit, publish, author owner gates or judge work,
        # so the fleet's lane procedures are replaced by a boundary that points
        # at the full policy instead of widening its permissions. Every
        # installer that rewrites a profile SOUL must compose the same block.
        policy.install(self.root)
        steward_path = self.root / 'profiles/board-steward/SOUL.md'
        steward = steward_path.read_text()
        self.assertIn('Fleet boundary', steward)
        self.assertIn('~/.hermes/scripts/hermes-fleet-policy.md', steward)
        self.assertIn('it grants nothing', steward)
        for excluded in ('## Hermes fleet rules', 'Never remove worker pins',
                         'Credential-only local routing', 'Workers never publish',
                         'Only head-coordinator authors owner gates',
                         'Independent acceptance belongs to feature-reviewer',
                         'Before committing, inspect git status'):
            self.assertNotIn(excluded, steward)
        for name in policy.PROFILES:
            if name != 'board-steward':
                self.assertIn('## Hermes fleet rules',
                              (self.root / 'profiles' / name / 'SOUL.md').read_text())
        spec = importlib.util.spec_from_file_location('steward_installer',
                                                      source / 'install-steward-readonly.py')
        steward_installer = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(steward_installer)
        refreshed = steward_installer.steward_soul('# board-steward\n', policy)
        self.assertIn('Fleet boundary', refreshed)
        self.assertNotIn('Never remove worker pins', refreshed)
        self.assertIn('read-only observer', refreshed)
        # Re-composing an installed steward SOUL is a fixed point.
        installed = steward_installer.steward_soul(steward, policy)
        self.assertEqual(installed, steward_installer.steward_soul(installed, policy))
        self.assertEqual(0, policy.install(self.root, check=True))

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
        self.assertNotIn('At most one dependency repair', reference.read_text())
        self.assertIn('compact_complete', reference.read_text())
        self.assertIn('--runtime-profile',
                      (self.root / 'scripts/hermes-behavior-trials.md').read_text())
        # Instruction-policy composition budget. This fixture is composed by
        # `policy.install` only: fleet policy, autonomy, taskforce, owner alerts
        # and routing. It omits the four blocks other installers add on top
        # (worker budgets, memory, cron, owner chat); the complete coordinator
        # prompt has its own guard below. This ceiling exists to catch silent
        # growth here: adding a block requires trimming elsewhere or a recorded
        # decision, not a bigger number.
        self.assertLess(len(result.split()), 1500)
        self.assertEqual(0, policy.install(self.root, check=True))

    # Ceiling for the complete composed coordinator prompt: every managed block
    # the five owning installers add. 1,821 words measured at d3b356a2, recorded
    # at 1,850 on 2026-10-22 (plan §11). Reaching it requires a decision, not an
    # edit here, and it is not a target.
    COMPLETE_PROMPT_CEILING = 1850

    def test_complete_coordinator_prompt_within_its_recorded_budget(self):
        worker = load_installer('worker', 'install-worker-policy.py')
        memory = load_installer('memory', 'install-memory-policy.py')
        cron = load_installer('cron', 'install-cron-policy.py')
        owner_chat = load_installer('owner_chat', 'install-owner-chat-policy.py')
        policy.install(self.root)
        soul = self.root / 'profiles/head-coordinator/SOUL.md'
        soul.write_text(worker.instruction(soul.read_text()))
        soul.write_text(memory.instructions(soul.read_text(), 'head-coordinator'))
        soul.write_text(cron.instructions(soul.read_text()))
        soul.write_text(policy.block(soul.read_text(), owner_chat.MARKER,
                                     owner_chat.END_MARKER, owner_chat.POLICY))
        composed = soul.read_text()
        # Count only managed blocks; the fixture's seed heading is not prompt.
        blocks = [match.group(0) for match in re.finditer(
            r'<!-- ([^/\n][^\n]*?) -->.*?<!-- /\1 -->', composed, re.S)]
        self.assertEqual(10, len(blocks),
                         'all five owning installers must compose their blocks')
        words = sum(len(block.split()) for block in blocks)
        self.assertLessEqual(words, self.COMPLETE_PROMPT_CEILING,
                             f'{words} composed words over the recorded budget')

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
        self.assertTrue((self.root / 'profiles/head-coordinator/skills/software-development/systematic-debugging/SKILL.md').is_file())
        self.assertTrue((self.root / 'profiles/head-coordinator/skills/devops/nixhomeserver-shutdown-guard/SKILL.md').is_file())
        self.assertTrue((self.root / 'profiles/project-auditor/skills/software-development/systematic-debugging/SKILL.md').is_file())
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


    def test_review_skills_exclude_readonly_profiles_and_root(self):
        # Stale copies this installer previously installed at the excluded
        # scopes: root (routing-only default) and board-steward (read-only).
        # Project-auditor is now independently review-capable. Only identical copies are
        # removed; an independently edited copy is preserved untouched.
        review_sources = {'requesting-code-review.md':
                          source / 'instructions/requesting-code-review.md',
                          'sdlc-review.md': source / 'instructions/sdlc-review.md'}
        stale = [
            self.root / 'skills/software-development/requesting-code-review/SKILL.md',
            self.root / 'skills/devops/sdlc-review/SKILL.md',
            self.root / 'profiles/board-steward/skills/software-development/requesting-code-review/SKILL.md',
            self.root / 'profiles/board-steward/skills/devops/sdlc-review/SKILL.md',
        ]
        for path in stale:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(review_sources['requesting-code-review.md' if 'requesting-code-review' in path.parts else 'sdlc-review.md'].read_text())
        edited = self.root / 'profiles/board-steward/skills/software-development/independent-recipe/SKILL.md'
        edited.parent.mkdir(parents=True, exist_ok=True)
        edited.write_text('Operator-edited review recipe; never deleted.\n')
        self.assertEqual(1, policy.install(self.root, check=True))
        for path in stale:
            self.assertTrue(path.exists())
        self.assertEqual(0, policy.install(self.root))
        self.assertEqual(0, policy.install(self.root, check=True))
        for path in stale:
            self.assertFalse(path.exists())
        self.assertTrue(edited.exists())
        for name in policy.REVIEW_SKILL_PROFILES:
            home = self.root / 'profiles' / name
            self.assertEqual(review_sources['requesting-code-review.md'].read_bytes(),
                             (home / 'skills/software-development/requesting-code-review/SKILL.md').read_bytes())
            self.assertEqual(review_sources['sdlc-review.md'].read_bytes(),
                             (home / 'skills/devops/sdlc-review/SKILL.md').read_bytes())
        archived = {p.read_bytes() for p in (self.root / 'backups/instruction-policy').rglob('*')
                    if p.is_file()}
        self.assertIn(review_sources['sdlc-review.md'].read_bytes(), archived)

    def test_root_scope_carries_the_adapted_systematic_debugging_skill(self):
        # An unadapted upstream copy at root scope resolves for root-scoped
        # sessions and for any profile without its own copy; the installer
        # now converges it to the fleet-adapted source, with a backup.
        root_skill = self.root / 'skills/software-development/systematic-debugging/SKILL.md'
        root_skill.parent.mkdir(parents=True)
        root_skill.write_text('# Upstream unadapted debugging skill\n')
        policy.install(self.root, skills_only=True)
        self.assertEqual((source / 'instructions/systematic-debugging.md').read_bytes(),
                         root_skill.read_bytes())
        self.assertTrue((root_skill.parent / 'LICENSE').is_file())
        archived = {p.read_bytes() for p in (self.root / 'backups/instruction-policy').rglob('*')
                    if p.is_file()}
        self.assertIn(b'# Upstream unadapted debugging skill\n', archived)

    def test_skill_references_are_tracked_sources(self):
        # The live skills reference these procedures; losing the tracked
        # source would lose them on rebuild, which is how they became
        # stale installed-only copies in the first place.
        policy.install(self.root)
        orchestration = self.root / 'profiles/head-coordinator/skills/devops/kanban-orchestration'
        self.assertEqual((source / 'instructions/queue-recovery.md').read_bytes(),
                         (orchestration / 'references/queue-recovery.md').read_bytes())
        self.assertEqual((source / 'instructions/source-to-service-planning.md').read_bytes(),
                         (orchestration / 'references/source-to-service-planning.md').read_bytes())
        audit = self.root / 'profiles/feature-reviewer/skills/autonomous-ai-agents/taskforce-feature-audit'
        self.assertEqual((source / 'instructions/offline-state-probe.md').read_bytes(),
                         (audit / 'references/offline-state-probe.md').read_bytes())
        self.assertEqual(0, policy.install(self.root, check=True))


unittest.main(argv=['instruction-policy'], verbosity=2)
PY
