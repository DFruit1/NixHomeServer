#!/usr/bin/env bash
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fixture="$(mktemp -d /tmp/hermes-workspace-repair.XXXXXX)"
trap 'rm -rf "$fixture"' EXIT
python3 -B - "$repo" "$fixture" <<'PY'
import copy
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import unittest
from unittest.mock import patch

ROOT = Path(sys.argv[1])
SCRATCH = Path(sys.argv[2])
spec = importlib.util.spec_from_file_location('workspace_repair', ROOT/'scripts/hermes/repair-task-workspace.py')
repair = importlib.util.module_from_spec(spec)
spec.loader.exec_module(repair)

class Native:
    def __init__(self, task):
        self.task = task
        self.tasks = [('one',task)]
        self.runs = []
    def inventory(self):
        return copy.deepcopy(self.tasks)
    def details(self, board, task_id):
        return {'task':copy.deepcopy(self.task),'runs':copy.deepcopy(self.runs)}

class WorkspaceRepairTest(unittest.TestCase):
    def setUp(self):
        self.root = SCRATCH/self._testMethodName
        self.root.mkdir()
        self.repo = self.root/'repo'
        self.repo.mkdir()
        self.git(self.repo,'init','-q','--initial-branch=master')
        self.git(self.repo,'config','user.name','fixture')
        self.git(self.repo,'config','user.email','fixture@example.invalid')
        (self.repo/'source').write_text('approved')
        self.git(self.repo,'add','source'); self.git(self.repo,'commit','-qm','approved')
        self.commit = self.git(self.repo,'rev-parse','HEAD')
        self.tree = self.git(self.repo,'rev-parse','HEAD^{tree}')
        self.target = self.repo/'.worktrees/t_one'
        self.target.parent.mkdir()
        self.task = {'id':'t_one','status':'blocked','workspace_kind':'worktree',
                     'workspace_path':str(self.target),'branch_name':'wt/t_one'}
        self.native = Native(self.task)

    def git(self,path,*args):
        return subprocess.check_output(['git','-C',str(path),*args],text=True).strip()

    def run_repair(self, apply=True):
        return repair.repair_workspace(self.repo,'one','t_one',self.commit,self.tree,
                                       self.native,apply=apply)

    def assert_exact(self):
        self.assertEqual(str(self.target),self.git(self.target,'rev-parse','--show-toplevel'))
        self.assertEqual(self.commit,self.git(self.target,'rev-parse','HEAD'))
        self.assertEqual(self.tree,self.git(self.target,'rev-parse','HEAD^{tree}'))
        self.assertEqual('',self.git(self.target,'status','--porcelain'))

    def test_missing_checkout_is_created_at_exact_pinned_source(self):
        self.assertFalse(self.target.exists())
        result = self.run_repair()
        self.assertEqual('prepared',result['status'])
        self.assert_exact()
        self.assertFalse(result['inputs_verified'])
        self.assertFalse(result['unblocked'])
        self.assertEqual('blocked',self.native.task['status'])

    def test_parent_git_discovery_never_counts_as_valid_checkout(self):
        self.target.mkdir()
        (self.target/'evidence').write_bytes(b'keep exact old bytes')
        self.assertEqual(str(self.repo),self.git(self.target,'rev-parse','--show-toplevel'))
        self.assertIsNone(repair.exact_root(self.target))
        result = self.run_repair()
        self.assert_exact()
        preserved = Path(result['preserved_path'])
        self.assertEqual(b'keep exact old bytes',(preserved/'evidence').read_bytes())

    def test_wrong_dirty_checkout_and_original_branch_are_preserved(self):
        (self.repo/'source').write_text('old source')
        self.git(self.repo,'commit','-qam','wrong source')
        old = self.git(self.repo,'rev-parse','HEAD')
        self.git(self.repo,'worktree','add','-qb','wt/t_one',str(self.target),old)
        (self.target/'source').write_text('uncommitted original work')
        (self.target/'.tmp').mkdir()
        (self.target/'.tmp/input').write_bytes(b'retained input')
        result = self.run_repair()
        self.assert_exact()
        preserved = Path(result['preserved_path'])
        self.assertEqual('uncommitted original work',(preserved/'source').read_text())
        self.assertEqual(b'retained input',(preserved/'.tmp/input').read_bytes())
        self.assertEqual(old,self.git(self.repo,'rev-parse','wt/t_one'))
        self.assertEqual('wt/t_one',self.git(preserved,'branch','--show-current'))

    def test_active_owner_and_shared_alias_refuse_without_mutations(self):
        for status in ('running','ready','review'):
            self.task['status'] = status
            with self.assertRaises(repair.Refused): self.run_repair()
            self.assertFalse(self.target.exists())
        self.task['status'] = 'blocked'
        alias = {**self.task,'id':'t_other','status':'done','workspace_path':str(self.target/'..'/'t_one')}
        self.native.tasks.append(('other',alias))
        with self.assertRaisesRegex(repair.Refused,'SHARED_WORKSPACE'): self.run_repair()
        self.assertFalse(self.target.exists())

    def test_wrong_tree_symlink_foreign_repo_and_primary_root_refuse(self):
        self.tree = '0'*40
        with self.assertRaises(repair.Refused): self.run_repair()
        self.tree = self.git(self.repo,'rev-parse',self.commit+'^{tree}')
        self.target.symlink_to(self.repo,target_is_directory=True)
        with self.assertRaises(repair.Refused): self.run_repair()
        self.target.unlink()
        self.target.mkdir()
        self.git(self.target,'init','-q','--initial-branch=master')
        with self.assertRaisesRegex(repair.Refused,'FOREIGN_REPOSITORY'): self.run_repair()
        self.task['workspace_path'] = str(self.repo)
        with self.assertRaises(repair.Refused): self.run_repair()

    def test_inspection_is_read_only_and_exact_checkout_is_idempotent(self):
        before = self.git(self.repo,'worktree','list','--porcelain')
        result = self.run_repair(apply=False)
        self.assertEqual('repair_needed',result['status'])
        self.assertFalse(self.target.exists())
        self.assertEqual(before,self.git(self.repo,'worktree','list','--porcelain'))
        self.run_repair()
        (self.target/'.tmp').mkdir()
        (self.target/'.tmp/input').write_text('retained')
        result = self.run_repair()
        self.assertEqual('already_prepared',result['status'])
        self.assertIsNone(result['preserved_path'])
        self.assertEqual('retained',(self.target/'.tmp/input').read_text())

    def test_native_binding_change_after_preservation_returns_partial_receipt(self):
        self.target.mkdir()
        (self.target/'input').write_text('original')
        original = repair.preserve_workspace
        def preserve(*args,**kwargs):
            result = original(*args,**kwargs)
            self.task['status'] = 'running'
            return result
        with patch.object(repair,'preserve_workspace',side_effect=preserve):
            with self.assertRaises(repair.PartialRepair) as caught: self.run_repair()
        self.assertEqual('partial',caught.exception.receipt['status'])
        preserved = Path(caught.exception.receipt['preserved_path'])
        self.assertEqual('original',(preserved/'input').read_text())
        self.assertFalse(self.target.exists())

    def test_active_native_run_and_uncleared_process_refuse(self):
        self.native.runs = [{'id':1,'status':'running','worker_pid':None}]
        with self.assertRaisesRegex(repair.Refused,'OWNER_RUN_ACTIVE'): self.run_repair()
        self.native.runs = [{'id':1,'status':'blocked','worker_pid':123}]
        with self.assertRaisesRegex(repair.Refused,'OWNER_PROCESS_NOT_CLEARED'): self.run_repair()
        self.assertFalse(self.target.exists())

    def test_stale_registration_refuses_without_pruning_or_branch_loss(self):
        self.git(self.repo,'worktree','add','-qb','wt/t_one',str(self.target),self.commit)
        moved = self.target.with_name('unrecorded-manual-move')
        self.target.rename(moved)
        before = self.git(self.repo,'worktree','list','--porcelain')
        with self.assertRaisesRegex(repair.Refused,'STALE_WORKTREE_REGISTRATION'): self.run_repair()
        self.assertEqual(before,self.git(self.repo,'worktree','list','--porcelain'))
        self.assertEqual(self.commit,self.git(self.repo,'rev-parse','wt/t_one'))
        self.assertTrue((moved/'source').is_file())

    def test_native_adapter_includes_archived_boards_when_checking_aliases(self):
        owner = self.task
        alias = {**owner,'id':'t_archived'}
        class Cli:
            def call(self, argv):
                if argv[2:4] == ['boards','list']:
                    boards = [{'slug':'one'}]
                    if '--all' in argv: boards.append({'slug':'archived'})
                    return json.dumps(boards)
                if 'show' in argv:
                    return json.dumps({'task':owner,'runs':[]})
                return json.dumps([alias if 'archived' in argv else owner])
        self.native = repair.NativeBoards(Cli())
        with self.assertRaisesRegex(repair.Refused,'SHARED_WORKSPACE archived/t_archived'):
            self.run_repair()
        self.assertFalse(self.target.exists())

    def test_worker_profile_identity_is_preserved_and_refused_for_effects(self):
        with patch.dict(repair.os.environ,{'HERMES_PROFILE_NAME':'feature-reviewer',
                                         'HERMES_KANBAN_TASK':'t_one'}):
            with self.assertRaisesRegex(repair.Refused,'COORDINATOR_REPAIR_REQUIRED'):
                self.run_repair()
            self.assertEqual('t_one',repair.os.environ['HERMES_KANBAN_TASK'])
        self.assertFalse(self.target.exists())

    def test_add_failure_preserves_previous_tree_and_never_unblocks(self):
        self.target.mkdir()
        (self.target/'evidence').write_text('original')
        with patch.object(repair,'create_workspace',side_effect=repair.Refused('fixture add failed')):
            with self.assertRaises(repair.PartialRepair) as caught: self.run_repair()
        self.assertEqual('original',(Path(caught.exception.receipt['preserved_path'])/'evidence').read_text())
        self.assertEqual('blocked',self.task['status'])

unittest.main(argv=['workspace-repair-tests'])
PY
