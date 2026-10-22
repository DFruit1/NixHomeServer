#!/usr/bin/env bash
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
python3 -B - "$repo" <<'PY'
import importlib.util
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(sys.argv[1]) / 'scripts/hermes'))
import fleet_workflow as workflow


class WorkflowTest(unittest.TestCase):
    def test_one_proactive_chain_per_board(self):
        for status in ('ready', 'running', 'review', 'blocked', 'scheduled', 'triage'):
            self.assertFalse(workflow.proactive_allowed([
                {'status': status, 'tenant': 'continuous-improvement'}]))
        self.assertTrue(workflow.proactive_allowed([
            {'status': 'done', 'tenant': 'continuous-improvement'}]))

    def test_repairs_and_rework_take_precedence(self):
        for row in ({'status': 'blocked', 'block_kind': 'capability'},
                    {'status': 'triage', 'consecutive_failures': 2},
                    {'status': 'ready', 'last_outcome': 'changes_requested'},
                    {'status': 'running', 'created_by': 'fleet-supervisor'}):
            self.assertFalse(workflow.proactive_allowed([row]), row)
        for row in ({'status': 'blocked', 'block_kind': 'needs_input'},
                    {'status': 'running', 'tenant': 'implementation'},
                    {'status': 'done', 'block_kind': 'capability'}):
            self.assertTrue(workflow.proactive_allowed([row]), row)

    def test_v1_requires_matching_revision_and_independence(self):
        handoff = {'implementer': 'standard-implementer', 'reviewer': 'feature-reviewer',
                   'metadata': {'revision': 'a' * 40, 'plan_author': 'head-coordinator'}}
        accepted = {'revision': 'a' * 40,
                    'independence': {'plan_author': False, 'implementer': False}}
        workflow.acceptance(handoff, accepted, 'feature-reviewer')
        for changed in ({**accepted, 'revision': 'b' * 40},
                        {'revision': 'a' * 40},
                        {**accepted, 'independence': {'plan_author': True, 'implementer': False}}):
            with self.assertRaises(ValueError):
                workflow.acceptance(handoff, changed, 'feature-reviewer')
        handoff['metadata']['plan_author'] = 'feature-reviewer'
        with self.assertRaises(ValueError):
            workflow.acceptance(handoff, accepted, 'feature-reviewer')

    def test_only_explicit_version_selects_new_contract(self):
        self.assertTrue(workflow.native_contract('Goal: fix\nWorkflow: native-review-v1\n'))
        self.assertFalse(workflow.native_contract('Legacy task with native review in prose'))


unittest.main(argv=[sys.argv[0]])
PY
