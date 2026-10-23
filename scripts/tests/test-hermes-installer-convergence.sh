#!/usr/bin/env bash
# The four role-scoping installers share one live root, so each one must leave
# every other one's `--check` green once a single install pass has run. They are
# tested separately elsewhere; this suite covers the shared-root contract, which
# is what the live `--check` commands actually assert.
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
python3 -B - "$repo" <<'PY'
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

SOURCE = Path(sys.argv[1]) / 'scripts/hermes'
sys.path.insert(0, str(SOURCE))


def module(name, filename):
    spec = importlib.util.spec_from_file_location(name, SOURCE / filename)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


instruction = module('instruction', 'install-instruction-policy.py')
worker = module('worker', 'install-worker-policy.py')
memory = module('memory', 'install-memory-policy.py')
steward = module('steward', 'install-steward-readonly.py')
admission = module('admission', 'memory-policy.py')
taskforce = module('taskforce', 'install-review-taskforce.py')

PROFILES = instruction.PROFILES
LANES = ('head-coordinator', 'standard-implementer', 'local-implementer',
         'feature-reviewer', 'project-auditor')
STEWARD = 'board-steward'
FULL_FLEET = (SOURCE / 'taskforce/owner-blocker-authoring.md').read_text()
# Independent expectation of the documented role/skill table: a role home must
# hold exactly these maintained skills, and its ownership ledger must pin the
# same set. Restating it here is deliberate; deriving it from the installer
# tables would only prove the tables agree with themselves.
ENTITLED = {
    'default': {'systematic-debugging'},
    'head-coordinator': {'nixhomeserver-safe-change', 'nixhomeserver-shutdown-guard',
                         'nixhomeserver-module-change', 'systematic-debugging',
                         'kanban-orchestration', 'requesting-code-review', 'sdlc-review'},
    STEWARD: {'board-steward'},
    'standard-implementer': {'nixhomeserver-safe-change', 'nixhomeserver-module-change',
                             'nixhomeserver-shutdown-guard', 'systematic-debugging',
                             'requesting-code-review', 'sdlc-review'},
    'local-implementer': {'nixhomeserver-safe-change', 'nixhomeserver-module-change',
                          'nixhomeserver-shutdown-guard', 'systematic-debugging',
                          'requesting-code-review', 'sdlc-review'},
    'feature-reviewer': {'nixhomeserver-safe-change', 'nixhomeserver-module-change',
                         'systematic-debugging', 'requesting-code-review', 'sdlc-review',
                         'taskforce-feature-audit'},
    'project-auditor': {'nixhomeserver-safe-change', 'nixhomeserver-module-change',
                        'systematic-debugging', 'requesting-code-review', 'sdlc-review'},
}
ORDERS = (('instruction', 'worker', 'memory', 'steward'),
          ('steward', 'memory', 'worker', 'instruction'),
          ('memory', 'instruction', 'steward', 'worker'))


def cron_runner(jobs_path):
    """Stand in for `hermes cron create|edit` against the profile's jobs file."""
    def run(command, **kwargs):
        assert command[:5] == ['hermes', '--profile', STEWARD, 'cron', command[4]], command
        jobs = json.loads(jobs_path.read_text()).get('jobs', []) if jobs_path.exists() else []
        if command[4] == 'create':
            name = command[command.index('--name') + 1]
            job = {'id': name.replace(' ', '-'), 'name': name, 'prompt': command[6],
                   'schedule': {'expr': command[5]},
                   'skills': [command[command.index('--skill') + 1]], 'context_from': []}
            jobs.append(job)
        else:
            job = next(job for job in jobs if job['id'] == command[5])
            job['prompt'] = command[command.index('--prompt') + 1]
            if command[command.index('--add-skill') + 1] not in job['skills']:
                job['skills'].append(command[command.index('--add-skill') + 1])
            if '--schedule' in command:
                job['schedule'] = {'expr': command[command.index('--schedule') + 1]}
        for flag in ('--script', '--monitor-script', '--workdir', '--deliver'):
            if flag in command:
                job[flag[2:].replace('-', '_')] = command[command.index(flag) + 1]
        job['context_from'] = ['self'] if '--continuity' in command else []
        jobs_path.write_text(json.dumps({'jobs': jobs}, indent=2) + '\n')
        jobs_path.chmod(0o600)
        return subprocess.CompletedProcess(command, 0)
    return run


class SharedRootTest(unittest.TestCase):
    def test_taskforce_refresh_preserves_shared_authority_and_descriptions(self):
        for name in ('head-coordinator', 'project-auditor', 'feature-reviewer'):
            config = self.root / 'profiles' / name / 'config.yaml'
            config.write_text(config.read_text() + '\nplatform_toolsets:\n  cli: [file, terminal]\n')
        self.pass_over(ORDERS[0])
        with patch.object(steward.subprocess, 'run', cron_runner(self.jobs_path)):
            self.assertEqual(0, taskforce.install(self.root, cron=False))
        self.assertEqual(0, instruction.install(self.root, check=True))
        for name, description in taskforce.DESCRIPTIONS.items():
            import yaml
            actual = yaml.safe_load((self.root / 'profiles' / name / 'profile.yaml').read_text())
            self.assertEqual(description, actual['description'])
        self.assertIn('independent', (self.root / 'profiles/project-auditor/profile.yaml').read_text())

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='hermes-installer-convergence-')
        self.addCleanup(self.tmp.cleanup)
        self.fresh_root()

    def fresh_root(self):
        base = Path(self.tmp.name) / f'run{len(list(Path(self.tmp.name).iterdir()))}'
        self.root = base / 'hermes'
        self.repo = base / 'repo'
        self.repo.mkdir(parents=True)
        self.legacy_root()

    def legacy_root(self):
        """A pre-scoping root: every role carries the full fleet block."""
        # The live routing-only default profile never carried the fleet block;
        # it still carries the worker-budget and learning blocks removed below.
        self.root.mkdir(parents=True)
        (self.root / 'SOUL.md').write_text(
            '# default\n\nRetired routing profile: send the work to a lane.\n'
            '## Operator note\nKeep this exact note.\n\n'
            '<!-- hermes-worker-budgets -->\nOld root budget block.\n<!-- /hermes-worker-budgets -->\n\n'
            '<!-- hermes-memory-policy -->\nOld root learning block.\n<!-- /hermes-memory-policy -->\n')
        (self.root / 'config.yaml').write_text(
            'model: {provider: custom, default: fixture}\n'
            'memory:\n  nudge_interval: 10\nskills:\n  creation_nudge_interval: 10\n')
        # Copies at root scope that the routing-only profile must not resolve.
        for skill, target in instruction.REVIEW_SKILLS:
            stale = self.root / 'skills' / target
            stale.parent.mkdir(parents=True, exist_ok=True)
            stale.write_text((SOURCE / 'instructions' / skill).read_text())
        for name in PROFILES:
            home = self.root / 'profiles' / name
            home.mkdir(parents=True)
            (home / 'SOUL.md').write_text(
                f'# {name}\n\n## Operator note\nKeep this exact note.\n\n'
                '<!-- kanban-owner-blocker-authoring -->\n' + FULL_FLEET.rstrip()
                + '\n<!-- /kanban-owner-blocker-authoring -->\n\n'
                '<!-- hermes-memory-policy -->\nOld learning block.\n<!-- /hermes-memory-policy -->\n')
            (home / 'config.yaml').write_text(
                'model: {provider: custom, default: fixture}\n'
                'memory:\n  nudge_interval: 10\nskills:\n  creation_nudge_interval: 10\n')
            (home / 'profile.yaml').write_text(f'name: {name}\ndescription: Old description\n')
        # Learning keeps unrelated ownership records in the same ledger.
        ledger = self.root / 'profiles/standard-implementer/skills/.usage.json'
        ledger.parent.mkdir(parents=True)
        self.agent_entry = {'created_by': 'agent', 'pinned': False, 'use_count': 3}
        ledger.write_text(json.dumps({'hand-written-skill': self.agent_entry}, indent=2) + '\n')
        jobs_path = self.root / 'profiles/board-steward/cron/jobs.json'
        jobs_path.parent.mkdir(parents=True)
        jobs_path.write_text(json.dumps({'jobs': [
            {'id': 'daily', 'name': 'hermes daily steward', 'prompt': 'old prompt',
             'enabled': True, 'schedule': {'expr': '0 8 * * *'}, 'skills': []},
            {'id': 'opportunities', 'name': 'steward opportunity scan', 'prompt': 'old prompt',
             'enabled': True, 'skills': []}]}, indent=2) + '\n')
        self.jobs_path = jobs_path
        native = self.root / 'hermes-agent/hermes_cli'
        native.mkdir(parents=True)
        # Native files the worker and memory installers adapt or rewrite.
        (native / 'kanban_db.py').write_text(
            'def create():\n    assignee = _canonical_assignee(assignee)\n'
            '    if not title:\n        raise ValueError()\n'
            'def unblock():\n    with write_txn(conn):\n'
            '        resume_status = (\n            "ready"\n        )\n')
        (native / 'kanban_db_dispatch.py').write_text(
            'def dispatch():\n'
            "    # Per-profile cap: one profile's local model / API quota / browser pool\n"
            '    if claimed is None:\n        return False\n    try:\n'
            '        resolved_branch_name = None\n'
            '    except Exception:\n        pass\n'
            '    try:\n        pid = _call_spawn_fn(spawn)\n'
            '    except Exception:\n        pass\n'
            '    if lane == \"review\":\n'
            '        claimed.skills = list(dict.fromkeys([*(claimed.skills or []), \"sdlc-review\"]))\n'
            '    return True\n'
            'def reservation():\n    for row in rows:\n'
            '        if check_respawn_guard(conn, row["id"], lane="review") is None:\n'
            '            return True\n    return False\n')
        # Native model-facing seams the worker installer also adapts.
        tools = self.root / 'hermes-agent/tools'
        tools.mkdir(parents=True)
        (tools / 'kanban_tools.py').write_text(
            'def _handle_create(args):\n'
            '    parents = _coerce_str_list(args.get("parents") or [], "parents", "task ids")\n'
            '    with _board(args.get("board")) as (kb, conn):\n'
            '        from gateway.session_context import get_session_env\n'
            '        return kb.create_task(conn, title=title,\n'
            '            board=args.get("board"),\n'
            '        )\n')
        (tools / 'kanban_tools_schemas.py').write_text(
            '_DESC_BOARD = (\n'
            '    "Kanban board slug to target. When omitted, the call resolves the "\n'
            '    "active board the usual way: HERMES_KANBAN_DB env → "\n'
            '    "HERMES_KANBAN_BOARD env → the \'current\' symlink under the kanban "\n'
            '    "home → \'default\'. Pass an explicit slug only when the caller (e.g. "\n'
            '    "a Telegram routing layer) needs to override the env-pinned active "\n'
            '    "board for this one call."\n'
            ')\n'
            'KANBAN_CREATE_SCHEMA = _schema(\n'
            '    "kanban_create",\n'
            '    ("Create a task."),\n'
            '    {},\n'
            '    ["title", "assignee"],\n'
            ')\n')
        review = self.root / 'hermes-agent/agent/background_review.py'
        review.parent.mkdir(parents=True)
        review.write_text('\n'.join(f'PROMPT{i} = (\n{old}\n)'
                                    for i, (old, _) in enumerate(memory.PROMPT_EDITS)))

    def call(self, name, check):
        if name == 'instruction':
            return instruction.install(self.root, check)
        if name == 'worker':
            return worker.install(self.root, check)
        if name == 'memory':
            return memory.install(self.root, check)
        return steward.install(self.root, self.repo, check)

    def pass_over(self, order):
        """One install pass in `order`, standing in for the live cron CLI."""
        with patch.object(steward.subprocess, 'run', cron_runner(self.jobs_path)):
            for name in order:
                self.assertEqual(0, self.call(name, False), name)

    def checks(self):
        return {name: self.call(name, True) for name in
                ('instruction', 'worker', 'memory', 'steward')}

    def test_checks_report_the_legacy_root_without_writing_it(self):
        before = {path: path.read_bytes() for path in self.root.rglob('*') if path.is_file()}
        self.assertEqual({'instruction': 1, 'worker': 1, 'memory': 1, 'steward': 1},
                         self.checks(),
                         'a pre-scoping root must be reported as drift, not silently accepted')
        self.assertEqual(before, {path: path.read_bytes() for path in self.root.rglob('*')
                                  if path.is_file()},
                         '--check must never write')

    def test_every_installer_check_is_green_after_one_pass_in_any_order(self):
        for index, order in enumerate(ORDERS):
            with self.subTest(order=' → '.join(order)):
                if index:
                    self.fresh_root()
                self.pass_over(order)
                self.assertEqual({'instruction': 0, 'worker': 0, 'memory': 0, 'steward': 0},
                                 self.checks(),
                                 'the shared root must converge in install order '
                                 + ' → '.join(order))
                self.assertEqual({'instruction': 0, 'worker': 0, 'memory': 0, 'steward': 0},
                                 self.checks(),
                                 'a converged root must stay converged')

    def test_role_scoping_survives_a_shared_install(self):
        self.pass_over(('instruction', 'worker', 'memory', 'steward'))
        root_soul = (self.root / 'SOUL.md').read_text()
        for marker in ('<!-- kanban-owner-blocker-authoring -->', '<!-- hermes-worker-budgets -->',
                       '<!-- hermes-memory-policy -->', '<!-- hermes-task-skills -->'):
            self.assertNotIn(marker, root_soul, f'routing-only root kept {marker}')
        self.assertIn('Keep this exact note.', root_soul)
        self.assertIn('<!-- hermes-review-taskforce -->', root_soul)
        steward_soul = (self.root / 'profiles' / STEWARD / 'SOUL.md').read_text()
        self.assertIn('## Fleet boundary', steward_soul)
        self.assertNotIn('## Hermes fleet rules', steward_soul,
                         'the read-only steward receives the bounded boundary, not the lane policy')
        self.assertIn('read-only observer', steward_soul)
        for lane_rule in ('Never remove worker pins', 'Worker lanes stop at a local commit',
                          'Independent acceptance belongs to feature-reviewer'):
            self.assertNotIn(lane_rule, steward_soul,
                             'the read-only steward must not receive lane rules')
        self.assertNotIn('<!-- hermes-worker-budgets -->', steward_soul)
        for name in LANES:
            soul = (self.root / 'profiles' / name / 'SOUL.md').read_text()
            self.assertIn('## Hermes fleet rules', soul, name)
            self.assertIn('<!-- hermes-memory-policy -->', soul, name)
            self.assertIn('Keep this exact note.', soul, name)
        # The stale root-scope review skills are owned by the instruction
        # installer and must be removed so the routing-only profile cannot
        # resolve them.
        for _, target in instruction.REVIEW_SKILLS:
            self.assertFalse((self.root / 'skills' / target).exists(), target)

    def test_ledgers_pin_exactly_the_tracked_entitlement(self):
        self.pass_over(('instruction', 'worker', 'memory', 'steward'))
        for home in ('default',) + PROFILES:
            with self.subTest(profile=home):
                directory = self.root if home == 'default' else self.root / 'profiles' / home
                presented = {name for name in admission.MANAGED_SKILLS
                             if any((directory / 'skills').glob(f'*/{name}/SKILL.md'))}
                self.assertEqual(ENTITLED[home], presented, f'{home} installed managed skills')
                expected = {name: {'pinned': True} for name in ENTITLED[home]}
                if home == 'standard-implementer':
                    expected['hand-written-skill'] = self.agent_entry
                ledger = directory / 'skills/.usage.json'
                self.assertTrue(ledger.is_file(), f'{home} ownership ledger missing')
                self.assertEqual(expected, json.loads(ledger.read_text()),
                                 f'{home} ownership ledger')


if __name__ == '__main__':
    unittest.main(argv=['installer-convergence'], verbosity=2)
PY
