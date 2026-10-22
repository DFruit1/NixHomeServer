#!/usr/bin/env bash
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if [[ "${HERMES_FIXTURE_ACTIVE:-}" != 1 ]]; then
  exec python3 -B "$repo/scripts/hermes/fixture-runner.py" --repo "$repo" --suite "$repo/scripts/tests/test-hermes-workspace-repair.sh"
fi
fixture="$(mktemp -d /tmp/hermes-workspace-repair.XXXXXX)"
trap 'rm -rf "$fixture"' EXIT
python3 -B - "$repo" "$fixture" <<'PY'
import copy
from contextlib import closing
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

    def test_readonly_evidence_legacy_default_and_symlink_escape(self):
        import sqlite3
        reader=repair.NativeBoards._module('steward-board-read.py')
        root=self.root/'read-root';root.mkdir();legacy=root/'kanban.db'
        with closing(sqlite3.connect(legacy)) as db:
            db.execute('CREATE TABLE evidence(value TEXT)');db.execute("INSERT INTO evidence VALUES('original')");db.commit()
        before=legacy.read_bytes()
        self.assertEqual([{'value':'original'}],reader.query(root,'default','SELECT * FROM evidence')['rows'])
        with self.assertRaises(sqlite3.DatabaseError):reader.query(root,'default',"UPDATE evidence SET value='changed'")
        self.assertEqual(before,legacy.read_bytes())
        outside=self.root/'outside.db';legacy.rename(outside);legacy.symlink_to(outside)
        with self.assertRaises(ValueError):reader.query(root,'default','SELECT * FROM evidence')
        self.assertEqual(before,outside.read_bytes())

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


_NATIVE_PARENT = r'''
import importlib.util,json,os,sqlite3,subprocess,sys,time
from pathlib import Path
source,root,child=sys.argv[1:];source=Path(source);root=Path(root)
sys.path.insert(0,str(source));import worker_origin as origin
path=Path(os.environ['HERMES_KANBAN_DB']);pid=os.getpid();fingerprint=origin.process_fingerprint()
with sqlite3.connect(path) as db:
 db.execute("UPDATE tasks SET worker_pid=?,worker_started_at=?,claim_expires=? WHERE id='t_actor'",(pid,fingerprint,int(time.time())+600))
 db.execute("UPDATE task_runs SET worker_pid=?,worker_started_at=?,claim_expires=? WHERE id=42",(pid,fingerprint,int(time.time())+600))
binding=origin._native_binding();assert binding is not None
from hermes_cli import kanban_db as kb
assert 'two' in {row['slug'] for row in kb.list_boards(include_archived=True)},'Actual native catalog missed board two'
probe=subprocess.run([os.environ['HERMES_BIN'],'kanban','--board','two','list','--archived','--json'],capture_output=True,text=True)
assert probe.returncode==0,probe.stderr
assert any(x['id']=='t_one' for x in json.loads(probe.stdout)),'Native worker pin did not constrain explicit foreign board'
profile=os.environ['HERMES_PROFILE']
state=root/'hermes/profiles'/profile/'state.db';state.parent.mkdir(parents=True,exist_ok=True)
with sqlite3.connect(state) as db:
 db.execute('CREATE TABLE sessions(id TEXT,source TEXT,profile_name TEXT,started_at REAL,ended_at REAL,origin_json TEXT)')
 db.execute('INSERT INTO sessions VALUES (?,?,?,?,?,?)',('fixture-session','kanban',profile,time.time()-1,None,json.dumps({'native_worker':binding})))
env=dict(os.environ)
for key in ('HERMES_KANBAN_TASK','HERMES_KANBAN_RUN_ID','HERMES_KANBAN_CLAIM_LOCK'):env.pop(key,None)
env.update(HERMES_DELEGATED_CHILD_CONTEXT=str(root/'hermes'),HERMES_SESSION_ID='fixture-session')
# Native top-level launcher records a real, kernel-bound terminal launch.
proc=subprocess.Popen([sys.executable,'-B','-c','import sys;sys.stdin.readline();\n'+child,str(source),str(root)],env=env,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
if (root/'delegated').exists():
 from agent.delegation_context import delegated_child_context
 with delegated_child_context():origin.record_launch(proc)
else:origin.record_launch(proc)
out,err=proc.communicate('go\n',timeout=60)
if proc.returncode:raise RuntimeError(err)
print(out.strip())
'''
_NATIVE_CHILD = r'''
import importlib.util,json,os,subprocess,sys
from pathlib import Path
source,root=map(Path,sys.argv[1:]);sys.path.insert(0,str(source))
spec=importlib.util.spec_from_file_location('repair',source/'repair-task-workspace.py');repair=importlib.util.module_from_spec(spec);spec.loader.exec_module(repair)
plan=json.loads((root/'plan.json').read_text())
# The scrubbed field-tool CLI refuses even list. The native parent above also
# proves explicit --board two remains pinned to one in the actual worker.
probe=subprocess.run([os.environ['HERMES_BIN'],'kanban','--board','two','list','--archived','--json'],capture_output=True,text=True)
assert probe.returncode!=0 and 'delegate_task child contexts' in probe.stderr,probe.stderr
before={name:(root/'hermes/kanban/boards'/name/'kanban.db').read_bytes() for name in ('one','two')}
try:
 # Caller overrides must not choose board metadata or a fake CLI.
 os.environ['HERMES_BIN']=str(root/'forged-hermes')
 os.environ['HERMES_ROOT']=str(root/'forged-root')
 native=repair.NativeBoards(repair.Runner())
 preview=repair.repair_workspace(plan['repo'],'one','t_one',plan['revision'],plan['tree'],native,apply=False)
 result=repair.repair_workspace(plan['repo'],'one','t_one',plan['revision'],plan['tree'],native,apply=True)
 print(json.dumps({'status':result['status'],'preview':preview['status'],'forged_cli_called':(root/'forged-called').exists(),'preserved_pins':os.environ.get('HERMES_KANBAN_TASK') is None and os.environ['HERMES_DELEGATED_CHILD_CONTEXT']==str(root/'hermes')}))
except repair.Refused as exc:print(json.dumps({'status':'refused','reason':str(exc)}))
assert all((root/'hermes/kanban/boards'/name/'kanban.db').read_bytes()==value for name,value in before.items()),'Board bytes changed'
'''


class NativePinnedWorkspaceTest(unittest.TestCase):
    def probe(self,alias=False,profile='head-coordinator',delegated=False,legacy_alias=False,symlink_board=False,archive_alias=False,nested_artifact=False):
        import os,sqlite3,time
        native=Path(os.environ['HERMES_FIXTURE_NATIVE_PYTHON']).parents[2]
        sys.path.insert(0,str(native))
        from hermes_cli import kanban_db_connect as kbc, kanban_db as kb
        fixture=WorkspaceRepairTest('test_missing_checkout_is_created_at_exact_pinned_source')
        fixture._testMethodName='native-'+self._testMethodName
        fixture.setUp();root=fixture.root
        hermes=root/'hermes';dbpath=hermes/'kanban/boards/one/kanban.db'
        now=int(time.time());work=root/'coordinator';work.mkdir()
        for board in ('default','one','two'):
            path=hermes/'kanban.db' if board=='default' else hermes/'kanban/boards'/board/'kanban.db'
            path.parent.mkdir(parents=True,exist_ok=True)
            with closing(kbc.connect(db_path=path)) as db:
                if board=='one':
                    db.execute("INSERT INTO tasks(id,title,status,assignee,created_at,workspace_kind,workspace_path,branch_name) VALUES('t_one','Parked repair','blocked','feature-reviewer',?,'worktree',?,'wt/t_one')",(now,str(fixture.target)))
                    kb._append_event(db,'t_one','blocked',{'reason':'Input supplier: agent. Fixture source missing','kind':'capability'})
                    db.execute("INSERT INTO tasks(id,title,status,assignee,created_at,workspace_kind,workspace_path,current_run_id,claim_lock,claim_expires) VALUES('t_actor','Native coordinator','running','head-coordinator',?,'dir',?,42,'fixture',?)",(now,str(work),now+600))
                    db.execute("INSERT INTO task_runs(id,task_id,status,profile,started_at,claim_lock,claim_expires) VALUES(42,'t_actor','running','head-coordinator',?,'fixture',?)",(now-5,now+600))
                elif (board=='two' and alias) or (board=='default' and legacy_alias):
                    if board=='two':
                        db.executemany("INSERT INTO tasks(id,title,status,created_at,workspace_kind) VALUES(?,'Other historical card','archived',?,'scratch')",[(f't_a{i:03d}',now) for i in range(200)])
                    db.execute("INSERT INTO tasks(id,title,status,created_at,workspace_kind,workspace_path) VALUES('t_foreign','Retained foreign alias','archived',?,'dir',?)",(now,str(fixture.target)))
                db.commit()
        if archive_alias:
            original=hermes/'kanban/boards/two';archived=hermes/'kanban/boards/_archived/two-1790000000';archived.parent.mkdir();original.rename(archived);original.mkdir()
            with closing(kbc.connect(db_path=original/'kanban.db')):pass
        if nested_artifact:
            fake=hermes/'kanban/boards/one/workspaces/fixture/kanban.db';fake.parent.mkdir(parents=True);fake.write_bytes(b'not a board database')
        if symlink_board:
            original=hermes/'kanban/boards/two';moved=root/'outside-board';original.rename(moved);original.symlink_to(moved,target_is_directory=True)
        if profile!='head-coordinator':
            with sqlite3.connect(dbpath) as db:
                db.execute("UPDATE tasks SET assignee=? WHERE id='t_actor'",(profile,));db.execute('UPDATE task_runs SET profile=? WHERE id=42',(profile,))
        if delegated:(root/'delegated').touch()
        forged=root/'forged-hermes';forged.write_text('#!/bin/sh\ntouch '+str(root/'forged-called')+'\nprintf \'[]\\n\'\n');forged.chmod(0o700)
        (root/'plan.json').write_text(json.dumps(dict(repo=str(fixture.repo),revision=fixture.commit,tree=fixture.tree)))
        cli=root/'native-hermes';cli.write_text('#!'+str(Path(os.environ['HERMES_FIXTURE_NATIVE_PYTHON']))+'\nimport runpy,sys\nsys.path.insert(0,'+repr(str(native))+')\nrunpy.run_module("hermes_cli.main",run_name="__main__",alter_sys=True)\n');cli.chmod(0o700)
        env=dict(os.environ,HERMES_ROOT=str(hermes),HERMES_HOME=str(hermes/'profiles/head-coordinator'),HERMES_KANBAN_HOME=str(hermes),HERMES_KANBAN_TASK='t_actor',HERMES_KANBAN_RUN_ID='42',HERMES_KANBAN_CLAIM_LOCK='fixture',HERMES_KANBAN_BOARD='one',HERMES_KANBAN_DB=str(dbpath),HERMES_KANBAN_WORKSPACE=str(work),HERMES_PROFILE=profile,HERMES_SESSION_ID='fixture-session',HERMES_BIN=str(cli))
        result=subprocess.run([str(Path(os.environ['HERMES_FIXTURE_NATIVE_PYTHON'])),'-B','-c',_NATIVE_PARENT,str(ROOT/'scripts/hermes'),str(root),_NATIVE_CHILD],env=env,capture_output=True,text=True,timeout=90)
        self.assertEqual(0,result.returncode,result.stderr)
        return json.loads(result.stdout),fixture

    def test_native_coordinator_unique_workspace_can_preview_and_apply_without_pin_changes(self):
        result,fixture=self.probe()
        self.assertEqual('prepared',result['status'],result)
        self.assertEqual('repair_needed',result['preview']);self.assertTrue(result['preserved_pins'])
        self.assertFalse(result['forged_cli_called'])
        fixture.assert_exact()

    def test_native_untrusted_role_and_actual_delegated_launch_refuse_before_effects(self):
        for profile,delegated in (('standard-implementer',False),('head-coordinator',True)):
            with self.subTest(profile=profile,delegated=delegated):
                # Each probe has an exclusive native board/worker process.
                self._testMethodName += '-'+profile
                result,fixture=self.probe(profile=profile,delegated=delegated)
                self.assertEqual('refused',result['status'],result)
                self.assertIn('AUTHENTICATED_COORDINATOR_REQUIRED',result['reason'])
                self.assertFalse(fixture.target.exists())

    def test_native_legacy_default_board_alias_is_not_missed(self):
        result,fixture=self.probe(legacy_alias=True)
        self.assertEqual('refused',result['status'],result)
        self.assertIn('SHARED_WORKSPACE default/t_foreign',result['reason'])
        self.assertFalse(fixture.target.exists())

    def test_native_archive_container_preserves_retained_alias_ownership(self):
        result,fixture=self.probe(alias=True,archive_alias=True)
        self.assertEqual('refused',result['status'],result)
        self.assertIn('SHARED_WORKSPACE _archived/two-1790000000/t_foreign',result['reason'])
        self.assertFalse(fixture.target.exists())

    def test_workspace_artifact_named_database_is_not_a_native_board(self):
        result,fixture=self.probe(nested_artifact=True)
        self.assertEqual('prepared',result['status'],result)
        fixture.assert_exact()

    def test_native_visible_symlink_board_cannot_hide_foreign_workspace_alias(self):
        result,fixture=self.probe(alias=True,symlink_board=True)
        self.assertEqual('refused',result['status'],result)
        self.assertIn('BOARD_DIRECTORY_SYMLINK',result['reason'])
        self.assertFalse(fixture.target.exists())

    def test_native_coordinator_foreign_archived_alias_is_seen_and_refused(self):
        result,fixture=self.probe(alias=True)
        self.assertEqual('refused',result['status'],result)
        self.assertIn('SHARED_WORKSPACE two/t_foreign',result['reason'])
        self.assertFalse(fixture.target.exists())

unittest.main(argv=['workspace-repair-tests'],verbosity=2)
PY
