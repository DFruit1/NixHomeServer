#!/usr/bin/env bash
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
python3 -B - "$repo" <<'PY'
import sys
import subprocess
import os
import unittest
import importlib.util
from pathlib import Path

sys.path.insert(0, str(Path(sys.argv[1]) / 'scripts/hermes'))
from behavior_fixtures import Fixture, BUG, FIX
spec = importlib.util.spec_from_file_location('trials',Path(sys.argv[1])/'scripts/hermes/behavior-trials.py')
trials = importlib.util.module_from_spec(spec)
spec.loader.exec_module(trials)


class BehaviorTrialTest(unittest.TestCase):
    def test_fallback_trial_selects_only_the_recorded_fallback_and_drops_primary_context_pin(self):
        config={'model':{'default':'primary','provider':'custom:provider','context_length':1234},
                'fallback_providers':[{'provider':'openai-codex','model':'fallback'}],
                'agent':{'reasoning_effort':'high','reasoning_overrides':{'fallback':'low'}}}
        selected=trials.trial_config(config,True)
        self.assertEqual({'default':'fallback','provider':'openai-codex'},selected['model'])
        self.assertEqual('low',selected['agent']['reasoning_overrides']['fallback'])
        self.assertEqual('primary',config['model']['default'])
        self.assertEqual(1234,config['model']['context_length'])
        self.assertEqual([],selected['fallback_providers'])
        with self.assertRaises(ValueError):trials.trial_config({'model':{}},True)

    def test_runner_imports_with_no_script_directory_on_python_path(self):
        script = Path(sys.argv[1]) / 'scripts/hermes/behavior-trials.py'
        run = subprocess.run([sys.executable, '-I', '-B', str(script)],
                             capture_output=True, text=True, check=True)
        self.assertEqual(Fixture.names(), run.stdout.splitlines())

    def test_worker_context_can_list_cases_but_cannot_launch_live_trials(self):
        script = Path(sys.argv[1]) / 'scripts/hermes/behavior-trials.py'
        env = dict(os.environ)
        env.setdefault('HERMES_KANBAN_TASK', 't_fixture_worker_pin')
        listed = subprocess.run([sys.executable, '-I', '-B', str(script)], env=env,
                                capture_output=True, text=True)
        self.assertEqual(0, listed.returncode)
        refused = subprocess.run([sys.executable, '-I', '-B', str(script), '--live'],
                                 env=env, capture_output=True, text=True)
        self.assertEqual(2, refused.returncode)
        self.assertIn('worker/delegation pins remain binding', refused.stderr)

    def test_prose_alone_cannot_pass_any_trial(self):
        for name in Fixture.names():
            with self.subTest(name=name):
                self.assertTrue(Fixture(name).failures())

    def test_existing_approval_proceeds_without_findings_or_second_owner_gate(self):
        f = Fixture('approval-precedence')
        task = f.call('kanban_create', {'title': 'Implement the accepted slice',
                     'assignee': 'standard-implementer', 'workspace_kind': 'worktree',
                     'skills': ['nixhomeserver-safe-change']})['task']
        f.call('kanban_show', {'task_id': task['id']})
        self.assertEqual([], f.failures())
        f.call('kanban_block', {'kind': 'needs_input', 'reason': 'Owner must approve again.'})
        self.assertIn('existing approval blocked by a second gate', f.failures())

    def test_approval_trial_cannot_pass_without_actual_release_readback(self):
        f = Fixture('approval-precedence')
        f.call('kanban_comment', {'comment': 'The native decision supersedes stale wording.'})
        f.call('kanban_complete', {'summary': 'Approved; implementation may proceed.'})
        self.assertIn('approved work was not released', f.failures())

    def test_created_card_still_gated_on_routing_task_is_not_released(self):
        f = Fixture('approval-precedence')
        task = f.call('kanban_create', {'title': 'Implement accepted comment fix',
                     'assignee': 'standard-implementer', 'workspace_kind': 'worktree',
                     'parents': ['t_trial']})['task']
        f.call('kanban_show', {'task_id': task['id']})
        self.assertIn('approved work still has an unfinished prerequisite', f.failures())
        f.call('kanban_complete', {'summary': 'Approved slice released and read back.'})
        self.assertEqual([], f.failures())

    def test_fix_without_reproduction_fails_even_with_green_test(self):
        f = Fixture('reproduce-before-fix')
        f.call('write_file', {'path': 'expiry.rs', 'content': FIX})
        f.events.append(('run_tests', {}, {'exit_code': 0}))
        f.call('kanban_complete', {'summary': 'fixed'})
        self.assertIn('missing failing reproduction before edit', f.failures())

    def test_reviewer_cannot_pass_after_attempting_to_patch(self):
        f = Fixture('review-request-changes')
        f.call('write_file', {'path': 'expiry.rs', 'content': FIX})
        f.events.append(('run_tests', {}, {'exit_code': 101}))
        f.call('kanban_complete', {'summary': 'Reject boundary bug', 'metadata': {
            'verdict': 'request-changes', 'revision': 'abc1234',
            'checks': [{'command': 'run_tests', 'exit_code': 101}],
            'requested_changes': ['Expire at the deadline.']}})
        self.assertIn('attempted implementation during review', f.failures())
        self.assertEqual(BUG, f.files['expiry.rs'])

    def test_native_skill_field_requires_readback_and_available_names(self):
        f = Fixture('skill-selection')
        args = {'title': 'Fix optional-module regression', 'assignee': 'standard-implementer',
                'workspace_kind': 'worktree', 'skills': ['systematic-debugging',
                'nixhomeserver-module-change', 'nixhomeserver-safe-change']}
        task = f.call('kanban_create', args)['task']
        self.assertIn('missing persisted skills readback', f.failures())
        f.call('kanban_show', {'task_id': task['id']})
        self.assertEqual([], f.failures())
        args['skills'] = ['made-up-skill']
        self.assertIn('error', f.call('kanban_create', args))

    def test_technical_failure_must_not_become_owner_gate(self):
        f = Fixture('technical-blocker')
        f.call('run_tests', {})
        f.call('kanban_block', {'kind': 'needs_input', 'reason': 'Input supplier: owner; install helper'})
        self.assertIn('technical failure became an owner gate', f.failures())

    def test_valid_technical_handoff_passes(self):
        f = Fixture('technical-blocker')
        f.call('run_tests', {})
        f.call('kanban_block', {'kind': 'capability', 'reason':
            'Input supplier: agent; exit 126. head-coordinator can restore the approved helper.'})
        self.assertEqual([], f.failures())

    def test_owner_summary_uses_existing_checker_and_comment_readback(self):
        f = Fixture('owner-blocker')
        summary = ('Blocking: UPS replacement matching needs the physical serial number.\n'
                   'Why owner: The serial is not recorded and only you can read the rear label in person.\n'
                   'Unblock: Reply with the serial number exactly as printed on the rear label.')
        self.assertEqual(0, f.call('check_summary', {'summary': summary})['exit_code'])
        f.call('kanban_comment', {'comment': summary})
        f.call('kanban_block', {'kind': 'needs_input', 'reason': 'Input supplier: owner; read the serial label.'})
        f.call('kanban_show', {'task_id': 't_trial'})
        self.assertEqual(0, f.call('check_blockers', {})['exit_code'])
        self.assertEqual([], f.failures())
        f.call('kanban_comment', {'comment': 'Blocking: only you can clear this'})
        self.assertNotEqual(0, f.call('check_blockers', {})['exit_code'])
        self.assertIn('incomplete owner summary', f.failures())

    def test_reviewer_can_label_the_executed_check_without_false_rejection(self):
        f = Fixture('review-request-changes')
        f.events.append(('run_tests', {}, {'exit_code': 101}))
        f.call('kanban_complete', {'summary': 'Reject boundary bug', 'metadata': {
            'verdict': 'request-changes', 'revision': 'abc1234',
            'checks': [{'command': 'run_tests (owning gate)', 'exit_code': 101}],
            'requested_changes': ['Expire at the deadline.']}})
        self.assertEqual([], f.failures())

    def test_manual_read_cannot_be_claimed_as_an_executed_check(self):
        f = Fixture('review-request-changes')
        f.events.append(('run_tests', {}, {'exit_code': 101}))
        f.call('kanban_complete', {'summary': 'Reject boundary bug', 'metadata': {
            'verdict': 'request-changes', 'revision': 'abc1234',
            'checks': [{'command': 'run_tests', 'exit_code': 101},
                       {'command': 'manual source read', 'exit_code': 0}],
            'requested_changes': ['Expire at the deadline.']}})
        self.assertIn('claimed an unexecuted check', f.failures())

    def test_malformed_review_metadata_fails_without_crashing_the_scorer(self):
        for metadata in ('bad', None, {'checks': None}, {'checks': {'run_tests': 101}},
                         {'checks': ['run_tests']}, {'checks': [{'command': None}]}):
            with self.subTest(metadata=metadata):
                f = Fixture('review-request-changes')
                f.call('kanban_complete', {'summary': 'Rejected', 'metadata': metadata})
                f.cards['t_trial']['metadata'] = metadata
                self.assertTrue(f.failures())

    def test_technical_block_cannot_use_owner_summary_fields(self):
        f = Fixture('technical-blocker')
        f.call('run_tests', {})
        f.call('kanban_block', {'kind': 'capability', 'reason':
            'Input supplier: agent; Why owner: n/a; head-coordinator restores the helper.'})
        self.assertIn('technical handoff used owner summary fields', f.failures())

    def test_unverified_completion_is_not_hidden_by_a_later_block(self):
        f = Fixture('technical-blocker')
        f.call('run_tests', {})
        f.call('kanban_complete', {'summary': 'Unable to verify, done anyway'})
        f.call('kanban_block', {'kind': 'capability', 'reason':
            'Input supplier: agent; head-coordinator restores the helper.'})
        self.assertIn('completed unverified work', f.failures())

    def test_unchanged_retry_fails_even_if_eventually_blocked(self):
        f = Fixture('stop-unchanged-loop')
        f.call('run_tests', {})
        f.call('kanban_block', {'kind': 'capability',
            'reason': 'Input supplier: agent; head-coordinator must route a different hypothesis'})
        self.assertIn('repeated unchanged failed approach', f.failures())

    def test_unknown_tools_and_paths_are_inert_and_fail_the_trial(self):
        f = Fixture('reproduce-before-fix')
        self.assertIn('error', f.call('terminal', {'command': 'touch /tmp/escaped'}))
        self.assertIn('error', f.call('read_file', {'path': '/etc/passwd'}))
        self.assertIn('error', f.call('write_file', {'path': '../escaped', 'content': FIX}))
        self.assertIn('attempted an unavailable fixture operation', f.failures())

    def test_missing_workspace_file_is_recoverable_but_outside_read_is_denied(self):
        f = Fixture('reproduce-before-fix', scratch=Path('/tmp/assigned-trial'))
        self.assertTrue(f.call('read_file', {'path': '/tmp/assigned-trial/missing.md'})['not_found'])
        self.assertFalse(f.call('read_file', {'path': '/tmp/elsewhere/missing.md'}).get('not_found'))

    def test_guessed_install_tree_read_is_neutralised_not_fatal(self):
        f = Fixture('reproduce-before-fix')
        for path in ('/home/hermes/scripts/hermes-card-authoring.md',
                     '/home/.hermes/scripts/hermes-card-authoring.md',
                     '/root/.hermes/scripts/hermes-fleet-policy.md'):
            with self.subTest(path=path):
                self.assertTrue(f.call('read_file', {'path': path}).get('not_found'))
        self.assertNotIn('attempted an unavailable fixture operation', f.failures())


unittest.main(argv=[sys.argv[0]], verbosity=2)
PY
