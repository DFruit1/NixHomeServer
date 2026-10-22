#!/usr/bin/env bash
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if [[ -n "${HERMES_KANBAN_TASK:-}${HERMES_KANBAN_RUN_ID:-}${HERMES_DELEGATED_CHILD_CONTEXT:-}" && "${HERMES_FIXTURE_ACTIVE:-}" != 1 ]]; then
  echo 'Use the authorised fixture-runner for native synthetic worker tests' >&2
  exit 2
fi
python3 -B - "$repo" <<'PY'
from contextlib import closing
import importlib.util
import json
import os
from pathlib import Path
import sqlite3
import sys
import subprocess
import tempfile
import time
import types
import unittest
from unittest.mock import patch

SOURCE=Path(sys.argv[1])/'scripts/hermes'
NATIVE=(Path(os.environ['HERMES_FIXTURE_NATIVE_PYTHON']).parents[2] if os.environ.get('HERMES_FIXTURE_NATIVE_PYTHON') else Path(os.environ.get('HERMES_ROOT',str(Path.home()/'.hermes')))/'hermes-agent')
sys.path[:0]=[str(SOURCE),str(NATIVE)]
from hermes_cli import kanban_db as kb, kanban_db_connect as kbc
from agent.delegation_context import delegated_child_context, non_dispatcher_owned_context
import capability_recovery
import worker_origin
sys.modules['hermes_cli.nixhomeserver_worker_origin']=worker_origin
sys.modules['cron.nixhomeserver_capability_recovery']=capability_recovery
import resume_recovered as resume
from recovered_resume_adapter import adapt
sys.modules['hermes_cli.nixhomeserver_resume_recovered']=resume


class RecoveryTest(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix='hermes-recovered-resume-')
        self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name).resolve()
        self.db=self.root/'kanban/boards/synthetic/kanban.db'
        self.db.parent.mkdir(parents=True)
        self.conn=kbc.connect(db_path=self.db)
        self.addCleanup(self.conn.close)
        self.actor=kb.create_task(self.conn,title='Coordinator',assignee='head-coordinator',workspace_kind='scratch')
        self.target=kb.create_task(self.conn,title='Repair waiting review',body='Bounded original scope',assignee='feature-reviewer',triage=True,workspace_kind='scratch')
        self.work=self.root/'work';self.work.mkdir()
        now=int(time.time())
        with kb.write_txn(self.conn):
            self.conn.execute("UPDATE tasks SET status='running',workspace_path=?,worker_pid=?,worker_started_at=?,claim_lock='fixture',claim_expires=?,current_run_id=42 WHERE id=?",(str(self.work),os.getpid(),worker_origin.process_fingerprint(),now+600,self.actor))
            self.conn.execute("INSERT INTO task_runs(id,task_id,status,profile,worker_pid,worker_started_at,claim_lock,claim_expires,started_at) VALUES(42,?,'running','head-coordinator',?,?, 'fixture',?,?)",(self.actor,os.getpid(),worker_origin.process_fingerprint(),now+600,now))
            self.conn.execute("UPDATE tasks SET block_kind='capability',block_recurrences=4,consecutive_failures=3,last_failure_error='preserve',max_retries=7 WHERE id=?",(self.target,))
            kb._append_event(self.conn,self.target,'block_loop_detected',{'reason':'Input supplier: agent. Source repaired; see comment #fixture','kind':'capability','source_status':'review'})
        self.env={'HERMES_ROOT':str(self.root),'HERMES_KANBAN_TASK':self.actor,'HERMES_KANBAN_RUN_ID':'42','HERMES_KANBAN_BOARD':'synthetic','HERMES_KANBAN_DB':str(self.db),'HERMES_KANBAN_WORKSPACE':str(self.work),'HERMES_PROFILE':'head-coordinator','HERMES_KANBAN_CLAIM_LOCK':'fixture'}
        self.environment=patch.dict(os.environ,self.env);self.environment.start();self.addCleanup(self.environment.stop)

    def hold(self):
        return next(x for x in capability_recovery.read_board(self.conn,self.root,'synthetic',capability_recovery.helper_identity(self.root)) if x['task_id']==self.target)

    def apply(self,version=None):
        return resume.resume_recovered(kb,self.conn,self.target,version or self.hold()['version'],'Exact source and input repair verified; comment #fixture')

    def test_native_old_unblock_cannot_resume_triage(self):
        self.assertFalse(kb.unblock_task(self.conn,self.target))
        self.assertEqual('triage',kb.get_task(self.conn,self.target).status)
        result=self.apply()
        self.assertEqual('review',result['status'])

    def test_real_native_coordinator_and_counter_scope_preservation(self):
        before=dict(self.conn.execute('SELECT * FROM tasks WHERE id=?',(self.target,)).fetchone())
        self.assertEqual(self.actor,resume.coordinator_origin()['task_id'])
        self.apply()
        after=dict(self.conn.execute('SELECT * FROM tasks WHERE id=?',(self.target,)).fetchone())
        before['status']='review'
        self.assertEqual(before,after)
        event=self.conn.execute("SELECT payload FROM task_events WHERE task_id=? AND kind='unblocked' ORDER BY id DESC LIMIT 1",(self.target,)).fetchone()
        evidence=json.loads(event[0]);self.assertEqual(self.actor,evidence['actor_task']);self.assertEqual(42,evidence['actor_run']);self.assertEqual('head-coordinator',evidence['actor_profile'])
        self.assertTrue(evidence['recovery_reason']);self.assertRegex(evidence['recovery_version'],r'^[0-9a-f]{64}$')

    def test_parent_gate_and_unrelated_board_tasks_unchanged(self):
        parent=kb.create_task(self.conn,title='Unaccepted prerequisite',assignee='feature-reviewer',triage=True,workspace_kind='scratch')
        kb.link_tasks(self.conn,parent,self.target)
        untouched=kb.create_task(self.conn,title='Other todo',assignee='standard-implementer',triage=True,workspace_kind='scratch')
        self.conn.execute("UPDATE tasks SET status='todo' WHERE id=?",(untouched,));self.conn.commit()
        self.assertEqual('todo',self.apply()['status'])
        self.assertEqual('todo',kb.get_task(self.conn,untouched).status)

    def test_stale_version_and_duplicate_episode_refused(self):
        version=self.hold()['version']
        with self.assertRaises(ValueError):self.apply('0'*64)
        self.assertEqual('triage',kb.get_task(self.conn,self.target).status)
        self.apply(version)
        # A worker re-blocking unchanged scope must not receive an infinite retry.
        self.conn.execute("UPDATE tasks SET status='triage' WHERE id=?",(self.target,));self.conn.commit()
        kb._append_event(self.conn,self.target,'block_loop_detected',{'reason':'Input supplier: agent. Source repaired; see comment #fixture','kind':'capability','source_status':'review'});self.conn.commit()
        self.assertEqual(version,self.hold()['version'])
        with self.assertRaises(ValueError):self.apply(version)

    def test_new_triage_tracker_owner_and_malformed_version_refused(self):
        for sql in ("UPDATE tasks SET title='[FEATURE TRACKER] untouched' WHERE id=?", "UPDATE tasks SET block_kind='needs_input' WHERE id=?"):
            with self.subTest(sql=sql):
                self.conn.execute(sql,(self.target,));self.conn.commit()
                with self.assertRaises(ValueError):self.apply('0'*64)
                self.conn.execute("UPDATE tasks SET title='Repair waiting review',block_kind='capability' WHERE id=?",(self.target,));self.conn.commit()
        self.conn.execute('DELETE FROM task_events WHERE task_id=?',(self.target,));self.conn.commit()
        with self.assertRaises(ValueError):resume.resume_recovered(kb,self.conn,self.target,'0'*64,'repair verified')
        for version,reason in (('invalid','evidence'),('0'*64,''),('0'*64,'   ')):
            with self.subTest(version=version,reason=reason),self.assertRaises(ValueError):resume.resume_recovered(kb,self.conn,self.target,version,reason)

    def test_active_pid_lease_and_pending_run_refused(self):
        for update,values in (("worker_pid=?",(os.getpid(),)),("claim_lock='held',claim_expires=?",(int(time.time())+1000,)),("current_run_id=43",())):
            with self.subTest(update=update):
                if '43' in update:
                    self.conn.execute("INSERT INTO task_runs(id,task_id,status,profile,started_at) VALUES(43,?,'pending','feature-reviewer',?)",(self.target,int(time.time())))
                self.conn.execute('UPDATE tasks SET '+update+' WHERE id=?',(*values,self.target));self.conn.commit()
                with self.assertRaises(ValueError):self.apply()
                self.conn.execute('UPDATE tasks SET worker_pid=NULL,claim_lock=NULL,claim_expires=NULL,current_run_id=NULL WHERE id=?',(self.target,));self.conn.execute('DELETE FROM task_runs WHERE id=43');self.conn.commit()

    def test_native_phase_api_drift_refused_before_journal(self):
        with patch.object(kb,'_landing_status_after_parents',return_value='ready'):
            with self.assertRaises(ValueError):self.apply()
        self.assertEqual('triage',kb.get_task(self.conn,self.target).status)
        self.assertFalse((self.root/'runtime/recovered-resume').exists())

    def test_actual_delegate_ordinary_profile_and_stale_native_actor_refused(self):
        with delegated_child_context():
            self.assertIsNone(resume.coordinator_origin())
            with self.assertRaises(ValueError):self.apply()
        with non_dispatcher_owned_context():
            self.assertIsNone(resume.coordinator_origin())
        for field,value in (('HERMES_PROFILE','standard-implementer'),('HERMES_KANBAN_RUN_ID','99'),('HERMES_DELEGATED_CHILD_CONTEXT','1')):
            with patch.dict(os.environ,{field:value}):
                self.assertIsNone(resume.coordinator_origin())
                with self.assertRaises(ValueError):self.apply()

    def test_wrong_board_and_symlink_journal_refused(self):
        other=self.root/'kanban/boards/other/kanban.db';other.parent.mkdir(parents=True)
        with closing(kbc.connect(db_path=other)) as conn:
            with self.assertRaises(ValueError):resume.resume_recovered(kb,conn,self.target,self.hold()['version'],'verified')
        journal=self.root/'runtime/recovered-resume';journal.parent.mkdir();journal.symlink_to(self.work,target_is_directory=True)
        with self.assertRaises(ValueError):self.apply()
        self.assertEqual('triage',kb.get_task(self.conn,self.target).status)

    def test_actual_native_evidence_retry_policy_remains_binding(self):
        now=int(time.time())
        self.conn.execute("UPDATE tasks SET body='Recovery mode: evidence-only',max_retries=1,max_runtime_seconds=60 WHERE id=?",(self.target,))
        self.conn.execute("INSERT INTO task_runs(id,task_id,status,profile,started_at,ended_at,outcome) VALUES(43,?,'failed','feature-reviewer',?,?,'spawn_failed')",(self.target,now-10,now-5));self.conn.commit()
        version=self.hold()['version']
        with self.assertRaisesRegex(ValueError,'record a new coordinator receipt'):self.apply(version)
        self.assertEqual('triage',kb.get_task(self.conn,self.target).status)
        kb.add_comment(self.conn,self.target,author='head-coordinator',body='Recovery run: 43\nRecovery change: exact missing source repaired\nRecovery action: resume unchanged bounded question')
        self.assertEqual('review',self.apply(version)['status'])
        self.assertEqual(1,kb.get_task(self.conn,self.target).max_retries)

    def test_release_policy_remains_binding_and_reservation_survives_failure(self):
        version=self.hold()['version']
        from hermes_cli import nixhomeserver_worker_policy as policy
        with patch.object(policy,'require_release',side_effect=ValueError('existing policy')):
            with self.assertRaisesRegex(ValueError,'existing policy'):self.apply(version)
        self.assertEqual('triage',kb.get_task(self.conn,self.target).status)
        self.assertEqual('review',self.apply(version)['status'])
        # Failure after reservation must never silently retry the unchanged version.
        self.conn.execute("UPDATE tasks SET status='triage',body='new repaired inputs' WHERE id=?",(self.target,));self.conn.commit()
        kb._append_event(self.conn,self.target,'block_loop_detected',{'reason':'Input supplier: agent. new repair','kind':'capability'});self.conn.commit()
        version=self.hold()['version']
        with patch.object(kb,'_append_event',side_effect=RuntimeError('interrupted')):
            with self.assertRaises(RuntimeError):self.apply(version)
        self.assertEqual('triage',kb.get_task(self.conn,self.target).status)
        with self.assertRaisesRegex(ValueError,'consumed'):self.apply(version)


class InstallerTest(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix='hermes-recovered-install-');self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name)
        for name in ('tools/kanban_tools.py','tools/kanban_tools_schemas.py','hermes_cli/kanban_db.py'):
            target=self.root/'hermes-agent'/name;target.parent.mkdir(parents=True,exist_ok=True);target.write_text((NATIVE/name).read_text())
        (self.root/'hermes-agent/hermes_cli/nixhomeserver_worker_origin.py').write_text((SOURCE/'worker_origin.py').read_text())
        canonical=self.root/'hermes-agent/cron/nixhomeserver_capability_recovery.py';canonical.parent.mkdir();canonical.write_text((SOURCE/'capability_recovery.py').read_text())
        spec=importlib.util.spec_from_file_location('recovered_installer',SOURCE/'install-recovered-resume.py')
        self.installer=importlib.util.module_from_spec(spec);spec.loader.exec_module(self.installer)

    def test_check_install_idempotence_and_private_backup(self):
        self.assertEqual(1,self.installer.install(self.root,True))
        self.assertFalse((self.root/'backups').exists())
        self.assertEqual(0,self.installer.install(self.root))
        self.assertEqual(0,self.installer.install(self.root,True))
        self.assertEqual(0,self.installer.install(self.root))
        backups=list((self.root/'backups/recovered-resume').glob('*/*'))
        self.assertTrue(backups);self.assertTrue(all(p.stat().st_mode & 0o077 == 0 for p in backups))
        self.assertEqual((SOURCE/'resume_recovered.py').read_text(),(self.root/'hermes-agent/hermes_cli/nixhomeserver_resume_recovered.py').read_text())

    def test_worker_installer_effects_refused_before_native_changes(self):
        env=dict(os.environ,HERMES_ROOT=str(self.root),HERMES_KANBAN_TASK='t_fixture',HERMES_KANBAN_RUN_ID='99')
        result=subprocess.run([sys.executable,'-B',str(SOURCE/'install-recovered-resume.py')],env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=10)
        self.assertEqual(2,result.returncode);self.assertIn(b'interactive operator',result.stderr)
        self.assertFalse((self.root/'backups').exists())

    def test_all_preflight_anchors_and_origin_must_match_before_writes(self):
        for name in ('tools/kanban_tools.py','tools/kanban_tools_schemas.py','hermes_cli/kanban_db.py','hermes_cli/nixhomeserver_worker_origin.py','cron/nixhomeserver_capability_recovery.py'):
            with self.subTest(name=name):
                target=self.root/'hermes-agent'/name;before=target.read_text();target.write_text('# incompatible source')
                with self.assertRaises(ValueError):self.installer.install(self.root)
                self.assertFalse((self.root/'hermes-agent/hermes_cli/nixhomeserver_resume_recovered.py').exists())
                self.assertFalse((self.root/'backups').exists());target.write_text(before)


class AdapterTest(unittest.TestCase):
    def test_pinned_native_seams_idempotent_and_drift_refused(self):
        for name in ('tools/kanban_tools.py','tools/kanban_tools_schemas.py'):
            original=(NATIVE/name).read_text();updated=adapt(name,original)
            self.assertNotEqual(original,updated);self.assertEqual(updated,adapt(name,updated))
            with self.assertRaises(ValueError):adapt(name,'# incompatible source')
            compile(updated,name,'exec')

    def test_real_native_registry_and_handler_preserve_other_worker_guards(self):
        # Execute maintained native source in memory; production files stay untouched.
        import tools.kanban_tools_schemas as schemas
        exec(compile(adapt('tools/kanban_tools_schemas.py',(NATIVE/'tools/kanban_tools_schemas.py').read_text()),'fixture-schemas','exec'),schemas.__dict__)
        module=types.ModuleType('tools.fixture_recovered_tools')
        exec(compile(adapt('tools/kanban_tools.py',(NATIVE/'tools/kanban_tools.py').read_text()),'fixture-tools','exec'),module.__dict__)
        fixture=RecoveryTest();fixture.setUp()
        try:
            self.assertTrue(module._check_kanban_unblock_mode())
            self.assertFalse(module._check_kanban_orchestrator_mode())
            self.assertIn('error',json.loads(module._handle_unblock({'task_id':fixture.target,'board':'other'})))
            result=json.loads(module._handle_unblock({'task_id':fixture.target,'recovery_version':fixture.hold()['version'],'recovery_reason':'Source + inputs repaired; fixture receipt'}))
            self.assertEqual('review',result['status'])
            fixture.conn.execute("UPDATE tasks SET status='blocked' WHERE id=?",(fixture.target,));fixture.conn.commit()
            result=json.loads(module._handle_unblock({'task_id':fixture.target}))
            self.assertEqual('review',result['status'])
            fixture.conn.execute("UPDATE tasks SET assignee='standard-implementer' WHERE id=?",(fixture.actor,));fixture.conn.execute("UPDATE task_runs SET profile='standard-implementer' WHERE id=42");fixture.conn.commit()
            with patch.dict(os.environ,{'HERMES_PROFILE':'standard-implementer'}):
                self.assertEqual('standard-implementer',worker_origin._native_binding()['profile'])
                self.assertFalse(module._check_kanban_unblock_mode())
                self.assertIn('error',json.loads(module._handle_unblock({'task_id':fixture.target})))
            with delegated_child_context():
                self.assertFalse(module._check_kanban_unblock_mode())
                self.assertIn('error',json.loads(module._handle_unblock({'task_id':fixture.target})))
        finally:fixture.doCleanups()

unittest.main(argv=['recovered-resume'],verbosity=2)
PY
