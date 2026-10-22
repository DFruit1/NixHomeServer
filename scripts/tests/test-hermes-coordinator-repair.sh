#!/usr/bin/env bash
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if [[ -n "${HERMES_KANBAN_TASK:-}${HERMES_KANBAN_RUN_ID:-}${HERMES_DELEGATED_CHILD_CONTEXT:-}" && "${HERMES_FIXTURE_ACTIVE:-}" != 1 ]]; then
  echo 'Use the authorised fixture-runner for native synthetic tests' >&2
  exit 2
fi
python3 -B - "$repo" <<'PY'
import importlib.util
import json
import os
import subprocess
from pathlib import Path
import sys
import tempfile
import time
import types
import unittest
from unittest.mock import patch

source=Path(sys.argv[1])/'scripts/hermes'
native=(Path(os.environ['HERMES_FIXTURE_NATIVE_PYTHON']).parents[2] if os.environ.get('HERMES_FIXTURE_NATIVE_PYTHON') else Path.home()/'.hermes/hermes-agent')
sys.path[:0]=[str(source),str(native)]
from hermes_cli import kanban_db as kb,kanban_db_connect as kbc
from agent.delegation_context import delegated_child_context
import worker_origin, resume_recovered, coordinator_repair as repair, deadlock_recovery as monitor
sys.modules['hermes_cli.nixhomeserver_worker_origin']=worker_origin
sys.modules['hermes_cli.nixhomeserver_resume_recovered']=resume_recovered
sys.modules['hermes_cli.nixhomeserver_coordinator_repair']=repair
sys.modules['cron.nixhomeserver_capability_recovery']=monitor.recovery
from coordinator_repair_adapter import adapt,EDITS

class RepairTest(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(prefix='coordinator-repair-');self.addCleanup(self.tmp.cleanup)
        self.root=Path(self.tmp.name);self.path=self.root/'kanban/boards/testboard/kanban.db';self.path.parent.mkdir(parents=True)
        self.work=self.root/'work';self.work.mkdir()
        self.path.with_name('board.json').write_text(json.dumps({'default_workdir':str(self.work)}))
        self.conn=kbc.connect(db_path=self.path);self.addCleanup(self.conn.close)
        self.actor=kb.create_task(self.conn,title='Coordinator',assignee='head-coordinator',workspace_kind='scratch')
        self.target=kb.create_task(self.conn,title='Missing skill',assignee='feature-reviewer',skills=['kanban-orchestration'],max_runtime_seconds=900,max_retries=1,triage=True,workspace_kind='scratch')
        now=int(time.time());self.now=now
        with kb.write_txn(self.conn):
            self.conn.execute("UPDATE tasks SET status='running',worker_pid=?,worker_started_at=?,claim_lock='proof',claim_expires=?,workspace_path=?,current_run_id=42 WHERE id=?",(os.getpid(),worker_origin.process_fingerprint(),now+600,str(self.work),self.actor))
            self.conn.execute("INSERT INTO task_runs(id,task_id,status,profile,worker_pid,worker_started_at,claim_lock,claim_expires,started_at) VALUES(42,?,'running','head-coordinator',?,?,'proof',?,?)",(self.actor,os.getpid(),worker_origin.process_fingerprint(),now+600,now))
        self.env=patch.dict(os.environ,{'HERMES_ROOT':str(self.root),'HERMES_KANBAN_TASK':self.actor,'HERMES_KANBAN_RUN_ID':'42','HERMES_KANBAN_BOARD':'testboard','HERMES_KANBAN_DB':str(self.path),'HERMES_KANBAN_WORKSPACE':str(self.work),'HERMES_PROFILE':'head-coordinator','HERMES_KANBAN_CLAIM_LOCK':'proof'})
        self.env.start();self.addCleanup(self.env.stop)

    def apply(self,changes=None,**kwargs):
        version=repair.amend(kb,self.conn,self.target)['version']
        return repair.amend(kb,self.conn,self.target,expected_version=version,changes=changes or {'skills':[]},reason='Supersede invalid coordinator-only preload; same review scope',**kwargs)

    def hold(self):
        self.conn.execute("UPDATE tasks SET status='ready' WHERE id=?",(self.target,));self.conn.commit()
        self.assertTrue(kb.block_task(self.conn,self.target,reason='Input supplier: agent. Missing skill',kind='capability'))

    def test_actual_native_identity_and_exact_field_readback(self):
        before=dict(self.conn.execute('SELECT * FROM tasks WHERE id=?',(self.target,)).fetchone())
        result=self.apply();self.assertTrue(result['applied'])
        after=dict(self.conn.execute('SELECT * FROM tasks WHERE id=?',(self.target,)).fetchone())
        before['skills']='[]';self.assertEqual(before,after)
        event=json.loads(self.conn.execute("SELECT payload FROM task_events WHERE task_id=? AND kind='coordinator_amended'",(self.target,)).fetchone()[0])
        self.assertEqual(42,event['actor_run']);self.assertEqual(self.actor,event['actor_task'])

    def test_stale_cas_refuses_all_changes(self):
        version=repair.amend(kb,self.conn,self.target)['version']
        kb.edit_task(self.conn,self.target,body='Concurrent approved amendment')
        with self.assertRaisesRegex(ValueError,'changed'):
            repair.amend(kb,self.conn,self.target,expected_version=version,changes={'skills':[]},reason='old scope')
        self.assertEqual('["kanban-orchestration"]',self.conn.execute('SELECT skills FROM tasks WHERE id=?',(self.target,)).fetchone()[0])

    def test_forged_delegated_wrong_board_and_active_target_refused(self):
        with delegated_child_context(),self.assertRaises(ValueError):self.apply()
        with patch.dict(os.environ,{'HERMES_KANBAN_RUN_ID':'43'}),self.assertRaises(ValueError):self.apply()
        other=kbc.connect(db_path=self.root/'other.db')
        try:
            with self.assertRaises(ValueError):repair.amend(kb,other,self.target)
        finally:other.close()
        for update in ("status='running'","worker_pid=999","claim_lock='lease'","claim_expires=1"):
            self.conn.execute('UPDATE tasks SET '+update+' WHERE id=?',(self.target,));self.conn.commit()
            with self.assertRaises(ValueError):self.apply()
            self.conn.execute("UPDATE tasks SET status='triage',worker_pid=NULL,claim_lock=NULL,claim_expires=NULL WHERE id=?",(self.target,));self.conn.commit()

    def test_forbidden_fields_and_evidence_fence_refused(self):
        for changes in ({'max_retries':4},{'result':'accept'},{'assignee':'head-coordinator'},{'body':'Recovery mode: evidence-only'},{'block_kind':'needs_input'}):
            with self.subTest(changes=changes),self.assertRaises(ValueError):self.apply(changes)

    def test_classify_real_untyped_failure_preserves_counter_and_cannot_retype_gate(self):
        self.conn.execute("UPDATE tasks SET status='blocked',consecutive_failures=1,last_failure_error='protocol violation' WHERE id=?",(self.target,))
        self.conn.execute("INSERT INTO task_runs(id,task_id,status,profile,started_at,ended_at,outcome) VALUES(43,?,'crashed','feature-reviewer',?,?,'crashed')",(self.target,self.now-20,self.now));self.conn.commit()
        version=repair.amend(kb,self.conn,self.target)['version']
        result=repair.amend(kb,self.conn,self.target,expected_version=version,changes={'block_kind':'capability'},reason='Input supplier: agent. Native missing terminal response; corrected skill/tool input is available.')
        self.assertTrue(result['applied'])
        row=self.conn.execute('SELECT status,block_kind,consecutive_failures,last_failure_error FROM tasks WHERE id=?',(self.target,)).fetchone()
        self.assertEqual(('blocked','capability',1,'protocol violation'),tuple(row))
        for kind in ('capability','needs_input'):
            self.conn.execute('UPDATE tasks SET block_kind=? WHERE id=?',(kind,self.target));self.conn.commit()
            with self.assertRaises(ValueError):self.apply({'block_kind':'capability'})

    def test_failed_reviewer_classification_and_versioned_resume_preserve_review_phase(self):
        self.conn.execute("UPDATE tasks SET status='blocked',max_retries=1,consecutive_failures=1,last_failure_error='protocol violation' WHERE id=?",(self.target,))
        self.conn.execute("INSERT INTO task_runs(id,task_id,status,profile,started_at,ended_at,outcome) VALUES(43,?,'crashed','feature-reviewer',?,?,'crashed')",(self.target,self.now-20,self.now))
        kb._append_event(self.conn,self.target,'gave_up',{'retry_status':'review','protocol_violation':True});self.conn.commit()
        version=repair.amend(kb,self.conn,self.target)['version']
        repair.amend(kb,self.conn,self.target,expected_version=version,changes={'block_kind':'capability','skills':[]},reason='Input supplier: agent. Removed unavailable coordinator-only skill from failed review.')
        hold=monitor.recovery.read_board(self.conn,self.root,'testboard',monitor.recovery.helper_identity(self.root))[0]
        result=resume_recovered.resume_recovered(kb,self.conn,self.target,hold['version'],'Actual preload repair read back; resume reviewer without replenishing allowances')
        self.assertEqual('review',result['status'])
        row=self.conn.execute('SELECT consecutive_failures,max_retries,last_failure_error FROM tasks WHERE id=?',(self.target,)).fetchone()
        self.assertEqual((1,1,'protocol violation'),tuple(row))

    def test_skill_catalog_missing_disabled_and_role_scope(self):
        with patch.object(repair,'available_skills',return_value={'systematic-debugging'}):
            for name in ('kanban-orchestration','disabled-skill'):
                with self.assertRaisesRegex(ValueError,'unavailable'):self.apply({'skills':[name]})
            self.apply({'skills':['systematic-debugging']})

    def test_one_measured_runtime_revision_without_resetting_retries(self):
        with self.assertRaises(ValueError):self.apply({'max_runtime_seconds':2700})
        self.conn.execute("INSERT INTO task_runs(id,task_id,status,profile,started_at,ended_at,outcome) VALUES(43,?,'timed_out','head-coordinator',?,?,'timed_out')",(self.target,self.now-1000,self.now));self.conn.commit()
        evidence={'run_id':43,'remaining_work':'four exact recovered producers','expected_completion':'within2700s','stop_condition':'stop on first refusal or failure'}
        self.apply({'max_runtime_seconds':2700},runtime_evidence=evidence)
        task=kb.get_task(self.conn,self.target);self.assertEqual(2700,task.max_runtime_seconds);self.assertEqual(1,task.max_retries)
        with self.assertRaisesRegex(ValueError,'Only one'):self.apply({'max_runtime_seconds':3000},runtime_evidence=evidence)

    def test_adapter_exact_seams_idempotence_and_fail_closed(self):
        for name in EDITS:
            data=(native/name).read_text();after=adapt(name,data)
            self.assertEqual(after,adapt(name,after))
            with self.assertRaises(ValueError):adapt(name,'# incompatible source')

    def test_actual_native_tool_visibility_and_handler(self):
        from recovered_resume_adapter import adapt as resume_adapt
        import tools.kanban_tools_schemas as schemas
        exec(compile(adapt('tools/kanban_tools_schemas.py',resume_adapt('tools/kanban_tools_schemas.py',(native/'tools/kanban_tools_schemas.py').read_text())),'fixture-schemas','exec'),schemas.__dict__)
        module=types.ModuleType('tools.fixture_coordinator_repair')
        exec(compile(adapt('tools/kanban_tools.py',resume_adapt('tools/kanban_tools.py',(native/'tools/kanban_tools.py').read_text())),'fixture-tools','exec'),module.__dict__)
        self.assertTrue(module._check_kanban_amend_mode())
        inspected=json.loads(module._handle_amend({'task_id':self.target}))
        self.assertIn('version',inspected)
        applied=json.loads(module._handle_amend({'task_id':self.target,'expected_version':inspected['version'],'changes':{'skills':[]},'reason':'Remove invalid role preload'}))
        self.assertTrue(applied['applied'])
        with delegated_child_context():
            self.assertFalse(module._check_kanban_amend_mode())
            self.assertIn('error',json.loads(module._handle_amend({'task_id':self.target})))
        with patch.dict(os.environ,{'HERMES_PROFILE':'standard-implementer'}):
            self.assertFalse(module._check_kanban_amend_mode())
            self.assertIn('error',json.loads(module._handle_amend({'task_id':self.target})))

    def test_actual_assignee_catalog_disabled_skill_and_malicious_workspace(self):
        (self.root/'hermes-agent').symlink_to(native,target_is_directory=True)
        profile=self.root/'profiles/feature-reviewer';profile.mkdir(parents=True)
        (profile/'config.yaml').write_text('skills:\n  disabled: [disabled-skill]\n')
        for name in ('available-skill','disabled-skill'):
            directory=profile/'skills'/name;directory.mkdir(parents=True)
            (directory/'SKILL.md').write_text('---\nname: '+name+'\ndescription: Fixture skill\n---\nInstructions.\n')
        attack=self.work/'tools';attack.mkdir()
        (attack/'__init__.py').write_text('raise RuntimeError("workspace package executed")')
        (attack/'skills_tool.py').write_text('raise RuntimeError("workspace skill module executed")')
        interpreters=[str(native/'.venv/bin/python')]
        launcher=native/'.hermes/bin/hermes'
        if launcher.is_file():
            # The actual gateway uses a bare managed interpreter, not .venv.
            # Its installed dependency generation needs passive activation.
            runtime=json.loads(subprocess.check_output([str(launcher),'--print-runtime-command'],text=True))
            interpreters.append(runtime[0])
        for interpreter in dict.fromkeys(interpreters):
            with self.subTest(interpreter=interpreter),patch.object(repair.sys,'executable',interpreter):
                names=repair.available_skills(self.root,'feature-reviewer',str(self.work))
                self.assertIn('available-skill',names);self.assertNotIn('disabled-skill',names)
                self.assertNotIn('kanban-orchestration',names)

    def test_catalog_timeout_is_a_capability_hold_not_dispatch_exception(self):
        import subprocess
        spec=importlib.util.spec_from_file_location('fixture_policy',source/'worker-policy.py')
        policy=importlib.util.module_from_spec(spec);spec.loader.exec_module(policy)
        with patch.object(repair,'available_skills',side_effect=subprocess.TimeoutExpired('catalog',20)):
            self.assertIn('catalog unavailable',policy.reason(self.conn,self.target))

    def test_catalog_refuses_pending_publication_without_runtime_config_recovery(self):
        fixture=self.root/'catalog-native';fixture.mkdir()
        state=fixture/'install-state';state.mkdir()
        pending=state/'publication.json';pending.write_text('{"pending":"preserve exactly"}')
        config=fixture/'config.yaml';config.write_text('preserve_config: true\n')
        modules={
            'pm/__init__.py':'',
            'pm/environments.py':'''def owning_home_root(native): return None
def install_state_dir(native): return native/'install-state'
def committed_venv(native): return None
def site_packages(environment): return environment
def venv_python_version(environment): return None
def activate_dependencies(native):
    from hermes_cli.runtime_state import recover_publication
    recover_publication(native)
''',
            'hermes_cli/__init__.py':'',
            'hermes_cli/runtime_state.py':'''from contextlib import contextmanager
@contextmanager
def runtime_lock(native,timeout=None): yield True
def lease_generation(environment): return lambda:None
def recover_publication(native):
    (native/'config.yaml').write_text('UNAUTHORIZED RECOVERY')
    (native/'install-state/publication.json').unlink()
''',
            'hermes_constants.py':'def set_hermes_home_override(home): return None\ndef reset_hermes_home_override(token): pass\n',
            'tools/__init__.py':'',
            'tools/skills_tool.py':'def _find_all_skills(): return [{"name":"fixture-skill"}]\n',
        }
        for relative,code in modules.items():
            path=fixture/relative;path.parent.mkdir(parents=True,exist_ok=True);path.write_text(code)
        args=[sys.executable,'-I','-B','-c',repair.CATALOG_PROGRAM,str(fixture)]
        result=subprocess.run(args,capture_output=True,text=True,timeout=10)
        self.assertNotEqual(0,result.returncode)
        self.assertEqual('{"pending":"preserve exactly"}',pending.read_text())
        self.assertEqual('preserve_config: true\n',config.read_text())
        pending.unlink()
        result=subprocess.run(args,capture_output=True,text=True,timeout=10)
        self.assertEqual(0,result.returncode,result.stderr);self.assertEqual(['fixture-skill'],json.loads(result.stdout))
        self.assertEqual('preserve_config: true\n',config.read_text())

    def test_final_native_catalog_failure_clears_prepared_claim_and_checks_actual_workspace(self):
        from worker_runtime_adapter import adapt as dispatch_adapt
        module=types.ModuleType('hermes_cli.fixture_repair_dispatch')
        sys.modules[module.__name__]=module;self.addCleanup(lambda:sys.modules.pop(module.__name__,None))
        exec(compile(dispatch_adapt('kanban_db_dispatch.py',(native/'hermes_cli/kanban_db_dispatch.py').read_text()),'fixture-dispatch','exec'),module.__dict__)
        spec=importlib.util.spec_from_file_location('fixture_final_policy',source/'worker-policy.py')
        policy=importlib.util.module_from_spec(spec);spec.loader.exec_module(policy)
        import hermes_cli
        sys.modules['hermes_cli.nixhomeserver_worker_policy']=policy
        self.addCleanup(lambda:sys.modules.pop('hermes_cli.nixhomeserver_worker_policy',None))
        prepared=self.root/'prepared';prepared.mkdir()
        self.conn.execute("UPDATE tasks SET status='ready',workspace_kind='dir',workspace_path=? WHERE id=?",(str(prepared),self.target));self.conn.commit()
        row=self.conn.execute('SELECT * FROM tasks WHERE id=?',(self.target,)).fetchone()
        original=policy.reason;calls=[]
        def reason(db,tid,assignee=None):
            calls.append(dict(db.execute('SELECT status,workspace_path FROM tasks WHERE id=?',(tid,)).fetchone()))
            return None if len(calls)==1 else original(db,tid,assignee)
        observed=[]
        def catalog(root,profile,workspace):
            observed.append(workspace)
            return set()
        result=module.DispatchResult()
        with patch.object(hermes_cli,'nixhomeserver_worker_policy',policy,create=True),patch.object(module,'_profile_exists_fn',return_value=lambda _:True),patch.object(policy,'reason',side_effect=reason),patch.object(repair,'available_skills',side_effect=catalog):
            consumed=module._dispatch_lane_task(self.conn,row,'feature-reviewer',result,lane='ready',dry_run=False,ttl_seconds=None,board='testboard',failure_limit=3,spawn_fn=lambda *a: self.fail('Missing skill spawned worker'),per_profile_caps=None,per_profile_running={})
        self.assertFalse(consumed);self.assertEqual([str(prepared)],observed,(result,calls,[dict(r) for r in self.conn.execute('SELECT kind,payload FROM task_events WHERE task_id=?',(self.target,))]))
        task=dict(self.conn.execute('SELECT * FROM tasks WHERE id=?',(self.target,)).fetchone())
        self.assertEqual('blocked',task['status']);self.assertIsNone(task['claim_lock']);self.assertIsNone(task['claim_expires'])
        run=self.conn.execute('SELECT outcome,ended_at FROM task_runs WHERE task_id=? ORDER BY id DESC LIMIT 1',(self.target,)).fetchone()
        self.assertEqual('blocked',run['outcome']);self.assertIsNotNone(run['ended_at'])

    def test_monitor_preview_no_writes_and_excludes_running_or_owner(self):
        self.hold()
        actions=monitor.tick(self.root,dry_run=True,now=self.now)
        self.assertEqual(1,len(actions));self.assertFalse((self.root/'runtime').exists())
        self.conn.execute("UPDATE tasks SET status='running' WHERE id=?",(self.target,));self.conn.commit()
        self.assertEqual([],monitor.tick(self.root,dry_run=True,now=self.now))

    def test_monitor_dedup_crash_retry_backoff_escalation_and_material_wake(self):
        self.hold()
        created={};calls=[]
        def create(board,*args):
            calls.append(args);key=args[args.index('--idempotency-key')+1]
            created.setdefault(key,{'id':'t_fixture_'+str(len(created))})
            return created[key]
        with patch.object(monitor,'atomic_write',side_effect=OSError('interrupted')):
            with self.assertRaises(OSError):monitor.tick(self.root,now=10000,create=create)
        monitor.tick(self.root,now=10000,create=create);self.assertEqual(1,len(created))
        self.assertEqual([],monitor.tick(self.root,now=10299,create=create))
        monitor.tick(self.root,now=10300,create=create)
        monitor.tick(self.root,now=11200,create=create)
        action=monitor.tick(self.root,now=14800,create=create);self.assertTrue(action[0]['audit'])
        self.assertEqual([],monitor.tick(self.root,now=30000,create=create))
        kb.add_comment(self.conn,self.target,author='head-coordinator',body='Another holding comment')
        self.assertEqual([],monitor.tick(self.root,now=30000,create=create))
        kb.edit_task(self.conn,self.target,body='Actual changed source input')
        self.assertFalse(monitor.tick(self.root,now=30000,create=create)[0]['audit'])

    def test_monitor_semantic_downstream_wait_and_native_open_dedup(self):
        child=kb.create_task(self.conn,title='Corrective producer',assignee='standard-implementer',triage=True,workspace_kind='scratch')
        kb.link_tasks(self.conn,self.target,child)
        self.conn.execute("UPDATE tasks SET status='todo',body=? WHERE id=?",('Wait for exact result from '+child,self.target));self.conn.commit()
        actions=monitor.tick(self.root,dry_run=True,now=self.now)
        self.assertEqual('possible-dependency-deadlock',actions[0]['issue']['kind'])
        kb.create_task(self.conn,title='Already queued',assignee='head-coordinator',created_by=monitor.CREATOR,workspace_kind='scratch')
        self.assertEqual([],monitor.tick(self.root,dry_run=True,now=self.now))

    def test_real_blocked_recovery_owner_and_noisy_failure_do_not_replenish_attempts(self):
        self.hold()
        def create(board,*args):
            tid=kb.create_task(self.conn,title=args[1],assignee='head-coordinator',created_by=monitor.CREATOR,triage=True,workspace_kind='scratch',idempotency_key=args[args.index('--idempotency-key')+1])
            return {'id':tid}
        action=monitor.tick(self.root,now=10000,create=create)[0]
        entry=json.loads((self.root/'runtime/deadlock-intake/state.json').read_text())[action['issue']['key']]
        owner=entry['task_id']
        self.assertEqual([],monitor.tick(self.root,now=20000,create=create))
        self.conn.execute("INSERT INTO task_runs(task_id,status,profile,started_at,ended_at,outcome) VALUES(?,'crashed','head-coordinator',10000,10005,'crashed')",(owner,));self.conn.commit()
        self.assertEqual(2,monitor.tick(self.root,now=20000,create=create)[0]['attempt'])
        # Identical target failure with volatile provenance is not new input.
        self.conn.execute("INSERT INTO task_runs(task_id,status,profile,started_at,ended_at,outcome,metadata) VALUES(?,'crashed','feature-reviewer',1,2,'crashed',?)",(self.target,json.dumps({'run_id':44,'pid':12345})));self.conn.commit()
        self.assertEqual(action['issue']['version'],monitor.observe(self.root,'testboard')[0]['version'])

    def test_installed_helper_change_wakes_exhausted_semantic_episode(self):
        self.hold();first=monitor.observe(self.root,'testboard')[0]['version']
        helper=self.root/'hermes-agent/hermes_cli/nixhomeserver_coordinator_repair.py';helper.parent.mkdir(parents=True)
        helper.write_text('# repaired helper implementation\n')
        self.assertNotEqual(first,monitor.observe(self.root,'testboard')[0]['version'])

    def test_parked_acknowledgment_expires_but_actual_remedy_writer_is_preserved(self):
        owner=kb.create_task(self.conn,title='Recovery owner',assignee='head-coordinator',created_by=monitor.CREATOR,triage=True,workspace_kind='scratch')
        self.conn.execute("UPDATE tasks SET status='ready' WHERE id=?",(owner,));self.conn.commit()
        kb.block_task(self.conn,owner,reason='Input supplier: agent. Waiting without supplied repair',kind='capability')
        self.assertTrue(monitor.previous_owner_active(self.root,'testboard',owner,self.now+100))
        self.assertFalse(monitor.previous_owner_active(self.root,'testboard',owner,self.now+1000))
        self.assertFalse(monitor.previous_owner_active(self.root,'testboard',owner,self.now+100,material_changed=True))
        remedy=kb.create_task(self.conn,title='Actual implementation remedy',assignee='standard-implementer',triage=True,workspace_kind='scratch')
        kb.link_tasks(self.conn,remedy,owner)
        self.conn.execute("UPDATE tasks SET status='blocked' WHERE id=?",(remedy,));self.conn.commit()
        self.assertFalse(monitor.previous_owner_active(self.root,'testboard',owner,self.now+1000))
        self.conn.execute("UPDATE tasks SET status='running',worker_pid=12345 WHERE id=?",(remedy,));self.conn.commit()
        self.assertTrue(monitor.previous_owner_active(self.root,'testboard',owner,self.now+1000,material_changed=True))

    def test_volatile_capability_reason_does_not_reset_attempt_episode(self):
        self.hold();first=monitor.observe(self.root,'testboard')[0]['version']
        with kb.write_txn(self.conn):
            kb._append_event(self.conn,self.target,'blocked',{'kind':'capability','reason':'Input supplier: agent. pid 24502 run 53 elapsed905 log /tmp/another-scratch/receipt not alive'})
        self.assertEqual(first,monitor.observe(self.root,'testboard')[0]['version'])

    def test_old_queued_owner_cannot_expire_and_parked_retry_only_resumes_same_owner(self):
        self.hold();created=[]
        def create(board,*args):
            tid=kb.create_task(self.conn,title=args[1],assignee='head-coordinator',created_by=monitor.CREATOR,workspace_kind='scratch')
            created.append((tid,args[args.index('--body')+1]));return {'id':tid}
        first=monitor.tick(self.root,now=self.now,create=create)[0]
        self.assertEqual([],monitor.tick(self.root,now=self.now+10000,create=create))
        owner=created[0][0]
        kb.block_task(self.conn,owner,reason='Input supplier: agent. Missing owner capability',kind='capability')
        next_action=monitor.tick(self.root,now=self.now+10000,create=create)[0]
        self.assertEqual(owner,next_action['issue']['recovery_owner'])
        self.assertIn('Scope: testboard/'+owner+' only',created[1][1])
        self.assertIn('Do not execute the original repair here',created[1][1])
        self.assertIn('guarded-resume that SAME owner',created[1][1])
        controller=created[1][0]
        # Preserve A even after controller B completes. Completion of B must
        # never transfer root repair ownership away from queued A.
        self.conn.execute("UPDATE tasks SET status='done' WHERE id=?",(controller,))
        self.conn.execute("UPDATE tasks SET status='ready' WHERE id=?",(owner,));self.conn.commit()
        self.assertEqual([],monitor.tick(self.root,now=self.now+20000,create=create))
        self.assertEqual(2,len(created))
        self.conn.execute("UPDATE tasks SET status='blocked' WHERE id=?",(owner,));self.conn.commit()
        another=monitor.tick(self.root,now=self.now+20000,create=create)[0]
        self.assertEqual(owner,another['issue']['recovery_owner'])
        self.assertIn('Scope: testboard/'+owner+' only',created[2][1])
        # A dependency-blocked owner remains queued even after its parent lands.
        self.conn.execute("UPDATE tasks SET status='todo' WHERE id=?",(owner,));self.conn.commit()
        self.assertTrue(monitor.previous_owner_active(self.root,'testboard',owner,self.now+10000))

    def feature(self, body='Goal: Requested search improvements.\nStable key: testboard/search'):
        tid=kb.create_task(self.conn,title='[FEATURE TRACKER] Search',body=body,assignee='head-coordinator',triage=True,workspace_kind='scratch')
        self.conn.execute('UPDATE tasks SET created_at=? WHERE id=?',(self.now-3*86400,tid));self.conn.commit()
        return tid

    def test_feature_tracker_orphan_is_intake_only_and_recent_demand_waits(self):
        from feature_flow import observe_features
        tracker=self.feature()
        issue=observe_features(self.conn,'testboard',self.now)[0]
        self.assertEqual(tracker,issue['task_id']);self.assertEqual('feature-delivery-gap',issue['kind'])
        self.assertEqual('triage',kb.get_task(self.conn,tracker).status)
        self.conn.execute('UPDATE tasks SET created_at=? WHERE id=?',(self.now,tracker));self.conn.commit()
        self.assertEqual([],observe_features(self.conn,'testboard',self.now))

    def test_feature_explicit_producer_suppresses_but_context_reference_does_not(self):
        from feature_flow import observe_features
        unrelated=kb.create_task(self.conn,title='Unrelated old context',assignee='standard-implementer',workspace_kind='scratch')
        tracker=self.feature('Goal: Search. Context: '+unrelated)
        self.assertEqual(1,len(observe_features(self.conn,'testboard',self.now)))
        producer=kb.create_task(self.conn,title='Search first slice',body='Feature tracker: testboard:'+tracker,assignee='standard-implementer',workspace_kind='scratch')
        self.assertEqual([],observe_features(self.conn,'testboard',self.now))
        self.conn.execute("UPDATE tasks SET status='done' WHERE id=?",(producer,));self.conn.commit()
        self.assertEqual(1,len(observe_features(self.conn,'testboard',self.now)))

    def test_stalled_feature_owner_reconciled_and_routing_churn_does_not_reset_inputs(self):
        from feature_flow import observe_features
        tracker=self.feature();initial=observe_features(self.conn,'testboard',self.now)[0]['version']
        route=kb.create_task(self.conn,title='Old feature routing',body='Feature tracker: testboard:'+tracker,assignee='head-coordinator',triage=True,workspace_kind='scratch')
        self.conn.execute("UPDATE tasks SET created_at=?,status='scheduled' WHERE id=?",(self.now-4*86400,route));self.conn.commit()
        issue=observe_features(self.conn,'testboard',self.now)[0]
        self.assertEqual([route],issue['existing_owners']);self.assertEqual(initial,issue['version'])
        kb.add_comment(self.conn,tracker,author='aging-escalation',body='Still waiting; new timestamp')
        self.assertEqual(initial,observe_features(self.conn,'testboard',self.now)[0]['version'])
        self.conn.execute("UPDATE tasks SET status='done' WHERE id=?",(route,));self.conn.commit()
        self.assertEqual(initial,observe_features(self.conn,'testboard',self.now)[0]['version'])

    def test_feature_disposition_requires_exact_scope_and_independent_evidence(self):
        from feature_flow import observe_features
        tracker=self.feature();version=observe_features(self.conn,'testboard',self.now)[0]['version']
        review=kb.create_task(self.conn,title='Accepted requested plan',assignee='feature-reviewer',triage=True,workspace_kind='scratch')
        route=kb.create_task(self.conn,title='Groundwater plan delivered',body='Feature tracker: testboard:'+tracker,assignee='head-coordinator',triage=True,workspace_kind='scratch')
        self.conn.execute("UPDATE tasks SET status='done' WHERE id IN (?,?)",(route,review))
        disposition={'tracker':tracker,'evidence_version':version,'state':'delivered_scope','evidence_task_id':review}
        self.conn.execute("INSERT INTO task_runs(id,task_id,status,profile,started_at,ended_at,outcome,metadata) VALUES(43,?,'done','head-coordinator',?,?,'completed',?)",(route,self.now-10,self.now,json.dumps({'feature_delivery':disposition})))
        self.conn.commit()
        kb.add_comment(self.conn,tracker,author='head-coordinator',body='Independent planning verdict '+review)
        self.assertEqual(1,len(observe_features(self.conn,'testboard',self.now)))
        self.conn.execute("INSERT INTO task_runs(id,task_id,status,profile,started_at,ended_at,outcome,metadata) VALUES(44,?,'done','feature-reviewer',?,?,'completed',?)",(review,self.now-20,self.now-15,json.dumps({'verdict':'accept','revision':'exact-plan-sha','checks':[{'command':'sha256sum accepted-plan','exit_code':0}]})));self.conn.commit()
        self.assertEqual([],observe_features(self.conn,'testboard',self.now))
        kb.edit_task(self.conn,tracker,body='Goal: Now implement a selected new requirement.')
        self.assertEqual(1,len(observe_features(self.conn,'testboard',self.now)))

    def test_feature_and_technical_intake_alternate_after_eligibility_and_survive_restart(self):
        self.hold();technical=monitor.observe(self.root,'testboard',self.now)[0]
        feature=dict(technical,key='testboard:t_feature:feature-delivery-gap',task_id='t_feature',kind='feature-delivery-gap',priority=-10)
        created=[]
        def create(board,*args):
            tid=kb.create_task(self.conn,title=args[1],assignee='head-coordinator',created_by=monitor.CREATOR,workspace_kind='scratch')
            created.append(tid);return {'id':tid}
        with patch.object(monitor,'observe',return_value=[technical,feature]):
            self.assertEqual('technical-hold',monitor.tick(self.root,now=self.now,create=create)[0]['issue']['kind'])
            # Ready owner blocks only its own candidate; feature is eligible.
            self.assertEqual('feature-delivery-gap',monitor.tick(self.root,now=self.now+1000,create=create)[0]['issue']['kind'])
            journal=json.loads((self.root/'runtime/deadlock-intake/state.json').read_text())
            self.assertEqual('feature',journal['_fairness']['testboard'])
            self.assertEqual([],monitor.tick(self.root,now=self.now+2000,create=create))
            self.assertEqual(2,len(created))
            # Completing the technical controller leaves that class eligible;
            # feature remains queued and must not consume a turn or duplicate.
            self.conn.execute("UPDATE tasks SET status='done' WHERE id=?",(created[0],));self.conn.commit()
            self.assertEqual('technical-hold',monitor.tick(self.root,now=self.now+3000,create=create)[0]['issue']['kind'])

    def test_feature_fairness_is_not_consumed_by_dry_run_or_failed_creation(self):
        self.feature()
        def fail(*args):raise RuntimeError('native create unavailable')
        with self.assertRaises(RuntimeError):monitor.tick(self.root,now=self.now,create=fail)
        self.assertFalse((self.root/'runtime/deadlock-intake/state.json').exists())
        self.assertEqual('feature-delivery-gap',monitor.tick(self.root,dry_run=True,now=self.now)[0]['issue']['kind'])
        self.assertFalse((self.root/'runtime/deadlock-intake/state.json').exists())

    def test_feature_owner_gate_and_actual_legacy_writer_are_preserved(self):
        from feature_flow import observe_features
        tracker=self.feature()
        gate=kb.create_task(self.conn,title='Real owner requirement',body='Feature tracker: testboard:'+tracker,assignee='head-coordinator',workspace_kind='scratch')
        kb.block_task(self.conn,gate,kind='needs_input',reason='Input supplier: owner. Physical calibration fact')
        self.assertEqual([],observe_features(self.conn,'testboard',self.now))
        self.conn.execute("UPDATE tasks SET status='done' WHERE id=?",(gate,));self.conn.commit()
        writer=kb.create_task(self.conn,title='Legacy writer',assignee='standard-implementer',workspace_kind='scratch')
        kb.add_comment(self.conn,tracker,author='head-coordinator',body='Actual source owner '+writer)
        self.conn.execute("UPDATE tasks SET status='running',worker_pid=123 WHERE id=?",(writer,));self.conn.commit()
        self.assertEqual([],observe_features(self.conn,'testboard',self.now))

    def test_failed_feature_reconciliation_uses_existing_owner_retry_without_48h_suppression(self):
        tracker=self.feature();created=[]
        def create(board,*args):
            tid=kb.create_task(self.conn,title=args[1],body=args[args.index('--body')+1],assignee='head-coordinator',created_by=monitor.CREATOR,workspace_kind='scratch')
            created.append(tid);return {'id':tid}
        action=monitor.tick(self.root,now=self.now,create=create)[0]
        owner=created[0]
        self.conn.execute("UPDATE tasks SET status='blocked' WHERE id=?",(owner,))
        self.conn.execute("INSERT INTO task_runs(id,task_id,status,profile,started_at,ended_at,outcome) VALUES(43,?,'crashed','head-coordinator',?,?,'crashed')",(owner,self.now,self.now+900));self.conn.commit()
        retry=monitor.tick(self.root,now=self.now+1000,create=create)[0]
        self.assertEqual(action['issue']['version'],retry['issue']['version'])
        self.assertEqual(owner,retry['issue']['recovery_owner'])
        self.assertIn('Do not execute the original repair here',kb.get_task(self.conn,created[1]).body)

    def test_feature_material_owner_inputs_and_receipts_wake_but_routine_chatter_does_not(self):
        from feature_flow import inspect_feature
        tracker=self.feature();initial=inspect_feature(self.conn,'testboard',tracker)['evidence_version']
        kb.add_comment(self.conn,tracker,author='head-coordinator',body='Still waiting; unchanged routing')
        self.assertEqual(initial,inspect_feature(self.conn,'testboard',tracker)['evidence_version'])
        kb.add_comment(self.conn,tracker,author='desktop',body='Use the installed sensor variant and private telemetry first.')
        answered=inspect_feature(self.conn,'testboard',tracker)['evidence_version'];self.assertNotEqual(initial,answered)
        self.conn.execute("INSERT INTO task_attachments(task_id,filename,stored_path,size,uploaded_by,created_at) VALUES(?,'new-receipt.json','/fixture/receipt',17,'head-coordinator',?)",(tracker,self.now));self.conn.commit()
        self.assertNotEqual(answered,inspect_feature(self.conn,'testboard',tracker)['evidence_version'])

    def test_fresh_material_input_reconciles_owner_gate_without_clearing_it(self):
        from feature_flow import observe_features
        tracker=self.feature()
        gate=kb.create_task(self.conn,title='Owner physical input',body='Feature tracker: testboard:'+tracker,assignee='head-coordinator',workspace_kind='scratch')
        kb.block_task(self.conn,gate,kind='needs_input',reason='Input supplier: owner. Installed hardware fact')
        self.assertEqual([],observe_features(self.conn,'testboard',self.now))
        comment=kb.add_comment(self.conn,tracker,author='owner',body='Actual hardware fact supplied.')
        self.conn.execute('UPDATE task_comments SET created_at=? WHERE task_id=? AND author=?',(self.now+10,tracker,'owner'));self.conn.commit()
        self.assertEqual(1,len(observe_features(self.conn,'testboard',self.now+20)))
        self.assertEqual('needs_input',kb.get_task(self.conn,gate).block_kind)
        self.assertEqual('blocked',kb.get_task(self.conn,gate).status)

    def test_disposition_cannot_use_bare_accept_wrong_profile_or_nonverification_question(self):
        from feature_flow import observe_features,inspect_feature
        tracker=self.feature()
        review=kb.create_task(self.conn,title='Question, not a verification',assignee='feature-reviewer',tenant='review-question',workspace_kind='scratch')
        route=kb.create_task(self.conn,title='Reconciliation',body='Feature tracker: testboard:'+tracker,assignee='head-coordinator',workspace_kind='scratch')
        kb.add_comment(self.conn,tracker,author='head-coordinator',body='Evidence '+review)
        self.conn.execute("UPDATE tasks SET status='done' WHERE id IN (?,?)",(route,review));self.conn.commit()
        self.conn.execute("INSERT INTO task_runs(id,task_id,status,profile,started_at,ended_at,outcome,metadata) VALUES(43,?,'done','head-coordinator',?,?,'completed','{}')",(route,self.now-10,self.now))
        self.conn.execute("INSERT INTO task_runs(id,task_id,status,profile,started_at,ended_at,outcome,metadata) VALUES(44,?,'done','feature-reviewer',?,?,'completed','{}')",(review,self.now-10,self.now));self.conn.commit()
        for tenant,profile,meta in [('verification','feature-reviewer',{'verdict':'accept'}),('review-question','feature-reviewer',{'verdict':'accept','revision':'sha','checks':[{'command':'check','exit_code':0}]}),('verification','standard-implementer',{'verdict':'accept','revision':'sha','checks':[{'command':'check','exit_code':0}]})]:
            self.conn.execute('UPDATE tasks SET tenant=? WHERE id=?',(tenant,review))
            self.conn.execute('UPDATE task_runs SET profile=?,metadata=? WHERE id=44',(profile,json.dumps(meta)));self.conn.commit()
            current=inspect_feature(self.conn,'testboard',tracker)['evidence_version']
            self.conn.execute('UPDATE task_runs SET metadata=? WHERE id=43',(json.dumps({'feature_delivery':{'tracker':tracker,'evidence_version':current,'state':'delivered_scope','evidence_task_id':review}}),));self.conn.commit()
            self.assertEqual(1,len(observe_features(self.conn,'testboard',self.now)))

    def test_assessed_deferral_binds_actual_auditor_scope_and_new_inputs_wake_it(self):
        from feature_flow import inspect_feature,observe_features
        tracker=self.feature()
        auditor=kb.create_task(self.conn,title='Finite mechanism assessment',body='Feature tracker: testboard:'+tracker,assignee='project-auditor',created_by=monitor.CREATOR,workspace_kind='scratch')
        route=kb.create_task(self.conn,title='Feature disposition',body='Feature tracker: testboard:'+tracker,assignee='head-coordinator',created_by=monitor.CREATOR,workspace_kind='scratch')
        self.conn.execute("UPDATE tasks SET status='done' WHERE id IN (?,?)",(auditor,route))
        self.conn.execute("INSERT INTO task_runs(id,task_id,status,profile,started_at,ended_at,outcome,metadata) VALUES(43,?,'done','project-auditor',?,?,'completed','{}')",(auditor,self.now-10,self.now))
        self.conn.execute("INSERT INTO task_runs(id,task_id,status,profile,started_at,ended_at,outcome,metadata) VALUES(44,?,'done','head-coordinator',?,?,'completed','{}')",(route,self.now-10,self.now));self.conn.commit()
        inspected=inspect_feature(self.conn,'testboard',tracker)
        disposition={'tracker':tracker,'evidence_version':inspected['evidence_version'],'state':'assessed_defer','evidence_task_id':auditor,'wake_condition':'Exact byte-preserving broker proposal supplied'}
        self.conn.execute('UPDATE task_runs SET metadata=? WHERE id=44',(json.dumps({'feature_delivery':disposition}),));self.conn.commit()
        self.assertEqual(1,len(observe_features(self.conn,'testboard',self.now)))
        assessment={'tracker':tracker,'scope_sha256':inspected['scope_sha256'],'outcome':'defer','missing_inputs':['Broker input contract'],'supplier':'agent','wake_condition':disposition['wake_condition']}
        self.conn.execute('UPDATE task_runs SET metadata=? WHERE id=43',(json.dumps({'feature_assessment':assessment,'revision':'assessment-sha','checks':[{'command':'bounded-probe','exit_code':0}]}),));self.conn.commit()
        actual=inspect_feature(self.conn,'testboard',tracker)['evidence_version']
        self.assertNotEqual(inspected['evidence_version'],actual)
        disposition['evidence_version']=actual
        self.conn.execute('UPDATE task_runs SET metadata=? WHERE id=44',(json.dumps({'feature_delivery':disposition}),));self.conn.commit()
        self.assertEqual([],observe_features(self.conn,'testboard',self.now))
        assessment['missing_inputs']=['New bounded probe result']
        self.conn.execute('UPDATE task_runs SET metadata=? WHERE id=43',(json.dumps({'feature_assessment':assessment}),));self.conn.commit()
        self.assertNotEqual(actual,inspect_feature(self.conn,'testboard',tracker)['evidence_version'])
        self.assertEqual(1,len(observe_features(self.conn,'testboard',self.now)))
        kb.add_comment(self.conn,tracker,author='head-coordinator',body='Feature input: the missing broker proposal is now supplied.')
        self.assertEqual(1,len(observe_features(self.conn,'testboard',self.now)))

    def test_public_feature_inspector_returns_current_version_while_reconciliation_active(self):
        from feature_flow import inspect_feature,observe_features
        tracker=self.feature()
        route=kb.create_task(self.conn,title='Active reconciliation',body='Feature tracker: testboard:'+tracker,assignee='head-coordinator',created_by=monitor.CREATOR,workspace_kind='scratch')
        self.conn.execute("UPDATE tasks SET status='running',worker_pid=345 WHERE id=?",(route,));self.conn.commit()
        self.assertEqual([],observe_features(self.conn,'testboard',self.now))
        count=self.conn.execute('SELECT COUNT(*) FROM task_events').fetchone()[0]
        run=subprocess.run([sys.executable,str(source/'feature_flow.py'),'--inspect','testboard:'+tracker],capture_output=True,text=True,check=True)
        self.assertEqual(inspect_feature(self.conn,'testboard',tracker)['evidence_version'],json.loads(run.stdout)['evidence_version'])
        self.assertEqual(count,self.conn.execute('SELECT COUNT(*) FROM task_events').fetchone()[0])
        self.assertEqual('running',kb.get_task(self.conn,route).status)

    def test_recovery_cron_installer_create_edit_resume_readback_and_idempotence(self):
        spec=importlib.util.spec_from_file_location('fixture_recovery_installer',source/'install-deadlock-recovery.py')
        installer=importlib.util.module_from_spec(spec);spec.loader.exec_module(installer)
        jobs_file=self.root/'cron/jobs.json';jobs_file.parent.mkdir();jobs_file.write_text('{"jobs":[]}')
        calls=[]
        def run(argv,**kwargs):
            calls.append(argv)
            jobs=json.loads(jobs_file.read_text())['jobs']
            if 'resume' in argv:
                jobs[0]['enabled']=True
            else:
                record={'id':'abcd1234','name':installer.NAME,'schedule':{'minutes':5},'script':'deadlock_recovery.py','no_agent':True,'workdir':str(source.parent.parent),'deliver':'local','enabled':True}
                jobs[:]=[record]
            jobs_file.write_text(json.dumps({'jobs':jobs}))
        self.assertEqual(1,installer.install(self.root,True));self.assertFalse(calls)
        with patch.object(installer.subprocess,'run',side_effect=run):
            self.assertEqual(0,installer.install(self.root));self.assertEqual(1,len(calls))
            self.assertEqual(0,installer.install(self.root,True));self.assertEqual(0,installer.install(self.root));self.assertEqual(1,len(calls))
            jobs=json.loads(jobs_file.read_text());jobs['jobs'][0]['enabled']=False;jobs['jobs'][0]['schedule']['minutes']=60;jobs_file.write_text(json.dumps(jobs))
            self.assertEqual(0,installer.install(self.root));self.assertEqual(3,len(calls))
        with patch.object(installer.subprocess,'run',return_value=None):
            jobs=json.loads(jobs_file.read_text());jobs['jobs'][0]['schedule']['minutes']=60;jobs_file.write_text(json.dumps(jobs))
            with self.assertRaisesRegex(ValueError,'readback differs'):installer.install(self.root)

unittest.main(argv=['coordinator-repair'],verbosity=2)
PY
