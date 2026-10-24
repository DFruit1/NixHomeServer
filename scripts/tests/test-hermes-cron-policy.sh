#!/usr/bin/env bash
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
python3 -B - "$repo" <<'PY'
import importlib.util,json,os,sqlite3,sys,tempfile,unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch
sys.path.insert(0,str(Path(sys.argv[1])/'scripts/hermes'))
import cron_policy as policy

class CronPolicyTest(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(prefix='hermes-cron-policy-');self.addCleanup(self.tmp.cleanup)
        self.root=Path(self.tmp.name);(self.root/'scripts').mkdir()
        self.env=patch.dict(os.environ,{'HERMES_ROOT':str(self.root)});self.env.start();self.addCleanup(self.env.stop)
        self.job={'id':'abc123','name':'bounded','monitor_script':'probe.py','monitor_state':{'last_output_hash':'snapshot'}}
        self.manifest={'jobs':{'abc123':{'profile':'head-coordinator','turns':4,'tools':2,'seconds':30,'kind':'monitor'}}}
        (self.root/'scripts/hermes-cron-policy.json').write_text(json.dumps(self.manifest))

    def test_only_registered_jobs_are_bounded_and_tool_ids_are_counted_once(self):
        self.assertEqual({'max_iterations':4,'run_budget_seconds':30},policy.agent_kwargs(self.job,120))
        self.assertEqual({'max_iterations':120},policy.agent_kwargs({'id':'other'},120))
        agent=SimpleNamespace(interrupt=lambda _:None)
        policy.bind(agent,self.job)
        self.assertIsNone(policy.tool_block(agent,'one'));self.assertIsNone(policy.tool_block(agent,'one'))
        self.assertIsNone(policy.tool_block(agent,'two'));self.assertIsNotNone(policy.tool_block(agent,'three'))
        self.assertIsNone(policy.tool_block(SimpleNamespace(),'one'))

    def test_failed_snapshot_is_retried_after_cooldown_then_acknowledged(self):
        current=lambda _:self.job
        calls=[]
        def failing(job,**kwargs):calls.append(job);return False,'failed','','provider unavailable'
        with patch.object(policy,'current_job',current),patch.object(policy,'identity',return_value='same'),patch.object(policy.time,'time',return_value=1000):
            policy.run(failing,self.job)
            self.assertEqual(1,len(calls))
            def skipped(job,**kwargs):
                self.assertEqual('snapshot',job['monitor_state']['last_output_hash'])
                return True,'skip','[SILENT]',None
            policy.run(skipped,self.job)
        def success(job,**kwargs):
            self.assertIsNone(job['monitor_state']['last_output_hash'])
            policy.bind(SimpleNamespace(interrupt=lambda _:None),job)
            return True,'completed','Useful result',None
        with patch.object(policy,'current_job',current),patch.object(policy,'identity',return_value='same'),patch.object(policy.time,'time',return_value=5000):
            policy.run(success,self.job)
        self.assertIsNone(json.loads(policy.state_path(self.job).read_text()).get('pending'))

    def test_report_chars_are_recorded_bounded_but_silent_passes_are_not(self):
        # The daily (2500) and stall (2400) prompts cap report length by model
        # self-discipline; this counter is what makes that enforceable claim
        # measurable. Text never goes into the journal, only its length.
        current=lambda _:self.job
        (self.root/'scripts/hermes-cron-policy.json').write_text(json.dumps(
            {'jobs':{'abc123':{'profile':'head-coordinator','turns':4,'tools':2,'seconds':30,'kind':'daily'}}}))
        def success(job,**kwargs):
            policy.bind(SimpleNamespace(interrupt=lambda _:None),job)
            return True,'completed','Report of useful bounded length.',None
        def silent(job,**kwargs):
            policy.bind(SimpleNamespace(interrupt=lambda _:None),job)
            return True,'completed','[SILENT]',None
        with patch.object(policy,'current_job',current),patch.object(policy,'identity',return_value='same'),patch.object(policy.time,'time',return_value=7000):
            policy.run(success,self.job)
            policy.run(silent,self.job)
        state=json.loads(policy.state_path(self.job).read_text())
        self.assertEqual(len('Report of useful bounded length.'),state['last_chars'])
        self.assertFalse(state.get('budget_exhausted'))

    def test_configuration_change_allows_a_bounded_recovery_without_clearing_native_state(self):
        with patch.object(policy,'current_job',lambda _:self.job),patch.object(policy,'identity',return_value='old'):
            policy.run(lambda *a,**k:(False,'failed','','error'),self.job)
        def recovered(job,**kwargs):
            self.assertIsNone(job['monitor_state']['last_output_hash'])
            policy.bind(SimpleNamespace(interrupt=lambda _:None),job)
            return True,'ok','[SILENT]',None
        with patch.object(policy,'current_job',lambda _:self.job),patch.object(policy,'identity',return_value='new'):
            policy.run(recovered,self.job)
        self.assertEqual('snapshot',self.job['monitor_state']['last_output_hash'])

    def test_deadline_is_enforced_even_if_the_agent_keeps_reporting_activity(self):
        agent=SimpleNamespace(interrupt=lambda _:None)
        with patch.object(policy.time,'monotonic',return_value=100):policy.bind(agent,self.job)
        with patch.object(policy.time,'monotonic',return_value=131):
            with self.assertRaises(TimeoutError):policy.enforce_deadline(agent)

    def test_native_adapter_is_exact_idempotent_and_preserves_unrelated_source(self):
        from cron_runtime_adapter import adapt,EDITS
        for name,edits in EDITS.items():
            # Native integration is also exercised in the opt-in native test.
            with self.assertRaises(ValueError):adapt(name,'unrelated upstream code')

    def test_stall_gate_uses_machine_due_times_and_ignores_routine_comments(self):
        import cron_stall
        board=self.root/'kanban/boards/test';board.mkdir(parents=True)
        (board/'board.json').write_text('{}')
        db=sqlite3.connect(board/'kanban.db')
        db.executescript('''CREATE TABLE tasks(id TEXT,status TEXT,assignee TEXT,block_kind TEXT,consecutive_failures INTEGER,block_recurrences INTEGER);
        CREATE TABLE task_runs(id INTEGER,task_id TEXT,status TEXT,outcome TEXT,ended_at REAL,metadata TEXT);
        CREATE TABLE task_comments(id INTEGER,task_id TEXT,author TEXT,body TEXT,created_at REAL);
        CREATE TABLE task_links(parent_id TEXT,child_id TEXT);
        INSERT INTO tasks VALUES('t_one','blocked','standard-implementer','capability',2,2);''');db.commit()
        state={};focus=cron_stall.collect(self.root,state,1000)
        self.assertEqual(1,len(focus));cron_stall.processed(state,focus,1000)
        self.assertEqual([],cron_stall.collect(self.root,state,1001))
        db.execute("INSERT INTO task_comments VALUES(1,'t_one','head-coordinator','routine acknowledgment',1002)");db.commit()
        self.assertEqual([],cron_stall.collect(self.root,state,1003))
        self.assertEqual(1,len(cron_stall.collect(self.root,state,1000+8*3600)))
        db.execute("INSERT INTO task_comments VALUES(2,'t_one','desktop','A new owner decision.',1004)");db.commit()
        changed=cron_stall.collect(self.root,state,1005)
        self.assertEqual('material_change',changed[0]['reason']);self.assertIsNone(changed[0]['next_due_utc'])
        db.execute('ALTER TABLE tasks ADD COLUMN created_by TEXT')
        db.execute("UPDATE tasks SET status='todo',block_kind=NULL,consecutive_failures=0,block_recurrences=0,created_by='user'")
        db.execute('DELETE FROM task_comments');db.commit()
        self.assertTrue(cron_stall.collect(self.root,{},1006)[0]['owner_requested'])
        db.close()

    def test_scheduled_technical_hold_is_followed_and_dependency_verdict_wakes_it(self):
        import cron_stall
        board=self.root/'kanban/boards/test';board.mkdir(parents=True)
        (board/'board.json').write_text('{}')
        db=sqlite3.connect(board/'kanban.db')
        db.executescript("""CREATE TABLE tasks(id TEXT,status TEXT,assignee TEXT,block_kind TEXT,consecutive_failures INTEGER,block_recurrences INTEGER);
        CREATE TABLE task_runs(id INTEGER,task_id TEXT,status TEXT,outcome TEXT,ended_at REAL,metadata TEXT);
        CREATE TABLE task_comments(id INTEGER,task_id TEXT,author TEXT,body TEXT,created_at REAL);
        CREATE TABLE task_links(parent_id TEXT,child_id TEXT);
        INSERT INTO tasks VALUES('t_hold','scheduled','head-coordinator',NULL,0,0);
        INSERT INTO tasks VALUES('t_review','done','feature-reviewer',NULL,0,0);
        INSERT INTO task_runs VALUES(1,'t_hold','scheduled','scheduled',900,'{}');
        INSERT INTO task_runs VALUES(2,'t_review','done','completed',950,'{"verdict":"request-changes","revision":"aaa"}');
        INSERT INTO task_links VALUES('t_review','t_hold');""");db.commit()
        state={};focus=cron_stall.collect(self.root,state,1000)
        self.assertEqual(['test:t_hold'],[item['key'] for item in focus])
        self.assertEqual('request-changes',focus[0]['related_tasks'][0]['verdict'])
        cron_stall.processed(state,focus,1000)
        self.assertEqual([],cron_stall.collect(self.root,state,1001))
        db.execute("UPDATE task_runs SET metadata=? WHERE id=2",
                   (json.dumps({'verdict':'accept','revision':'bbb'}),));db.commit()
        changed=cron_stall.collect(self.root,state,1002)
        self.assertEqual('material_change',changed[0]['reason'])
        self.assertEqual('accept',changed[0]['related_tasks'][0]['verdict'])
        self.assertEqual('scheduled',db.execute("SELECT status FROM tasks WHERE id='t_hold'").fetchone()[0])
        db.close()

    def test_stall_gate_is_readonly_and_does_not_hide_a_broken_board(self):
        import cron_stall
        board=self.root/'kanban/boards/test';board.mkdir(parents=True);(board/'board.json').write_text('{}')
        with self.assertRaises(sqlite3.Error):cron_stall.collect(self.root,{},1000)
        self.assertFalse((board/'kanban.db').exists())

    def test_unchanged_stall_evidence_skips_inference_and_failed_pass_does_not_advance(self):
        import cron_stall
        self.manifest['jobs']['abc123']['kind']='stall'
        (self.root/'scripts/hermes-cron-policy.json').write_text(json.dumps(self.manifest))
        with patch.object(cron_stall,'collect',return_value=[]):
            outcome=policy.run(lambda *a,**k:self.fail('model should not run'),self.job)
        self.assertTrue(outcome[0]);self.assertEqual('[SILENT]',outcome[2])
        focus=[{'key':'test:t_one','version':'fixed'}]
        with patch.object(cron_stall,'collect',return_value=focus),patch.object(policy,'current_job',lambda _:self.job):
            policy.run(lambda *a,**k:(False,'failed','','error'),self.job)
        state=json.loads(policy.state_path(self.job).read_text())
        self.assertNotIn('test:t_one',state.get('issues',{}))
        self.assertEqual(1,state['stall_pending']['attempts'])

    def test_old_consumed_auth_failure_is_migrated_once(self):
        self.job['last_failure']={'at':'2026-10-18T01:00:02+00:00'}
        self.job['monitor_state']['last_changed_at']='2026-10-18T01:00:00+00:00'
        def original(job,**kwargs):
            self.assertIsNone(job['monitor_state']['last_output_hash'])
            return False,'failed','','error'
        with patch.object(policy,'current_job',lambda _:self.job):policy.run(original,self.job)
        self.assertEqual(2,json.loads(policy.state_path(self.job).read_text())['pending']['attempts'])

    def test_weekly_sweep_waits_for_existing_work_and_bounds_new_handoffs(self):
        import cron_sweep
        calls=[]
        scheduler=SimpleNamespace(TENANT='continuous-improvement',SWEEP_TITLE='Improve',
            sweep_pending=lambda _:False,hermes=lambda *a:calls.append(a),board_state_line=lambda *a:'State: existing findings')
        cron_sweep.configure(scheduler)
        self.assertTrue(scheduler.sweep_pending([{'tenant':scheduler.TENANT,'status':'blocked','assignee':'standard-implementer'}]))
        self.assertFalse(scheduler.sweep_pending([{'tenant':scheduler.TENANT,'status':'done','assignee':'standard-implementer'}]))
        scheduler.hermes('board','create','Improve')
        self.assertEqual(('--max-runtime','300','--max-retries','1'),calls[0][-4:])
        self.assertLess(len(scheduler.sweep_body(None,None)),1000)

    def test_failed_marker_or_iteration_handoff_is_not_an_acknowledged_snapshot(self):
        for response,exhausted in (('[CRON_FAILURE]\nUnable to inspect',False),('Partial inspection',True)):
            def original(job,**kwargs):
                agent=policy.bind(SimpleNamespace(interrupt=lambda _:None),job)
                if exhausted:policy.note_result(agent,{'completed':False,'turn_exit_reason':'max_iterations'})
                return True,'output',response,None
            with patch.object(policy,'current_job',lambda _:self.job):policy.run(original,self.job)
            self.assertIsNotNone(json.loads(policy.state_path(self.job).read_text())['pending'])

    def test_unexpected_runner_error_still_retains_the_consumed_snapshot(self):
        def broken(*a,**k):raise RuntimeError('private provider detail')
        with patch.object(policy,'current_job',lambda _:self.job):result=policy.run(broken,self.job)
        self.assertFalse(result[0]);self.assertNotIn('private provider detail',str(result))
        self.assertIsNotNone(json.loads(policy.state_path(self.job).read_text())['pending'])

    def test_pending_scheduled_work_is_visible_without_its_private_fingerprints(self):
        spec=importlib.util.spec_from_file_location('performance',Path(sys.argv[1])/'scripts/hermes/kanban-performance.py')
        performance=importlib.util.module_from_spec(spec);spec.loader.exec_module(performance)
        self.assertEqual('unobserved',performance.cron_health(self.root,'head-coordinator')['status'])
        policy.save(policy.state_path(self.job),{'pending':{'hash':'PRIVATE'},'budget_exhausted':True})
        report=performance.cron_health(self.root,'head-coordinator')
        self.assertEqual('attention',report['status']);self.assertEqual(1,report['pending'])
        self.assertNotIn('PRIVATE',json.dumps(report))

    def test_parallel_tool_batches_cannot_exceed_the_shared_limit(self):
        from concurrent.futures import ThreadPoolExecutor
        agent=policy.bind(SimpleNamespace(interrupt=lambda _:None),self.job)
        with ThreadPoolExecutor(max_workers=8) as pool:
            outcomes=list(pool.map(lambda n:policy.tool_block(agent,str(n)),range(20)))
        self.assertEqual(2,sum(outcome is None for outcome in outcomes))

    def test_monitor_retries_stop_after_three_unchanged_attempts(self):
        for now in (1000,5000,20000):
            with patch.object(policy,'current_job',lambda _:self.job),patch.object(policy,'identity',return_value='same'),patch.object(policy.time,'time',return_value=now):
                policy.run(lambda *a,**k:(False,'failed','','error'),self.job)
        def skipped(job,**kwargs):
            self.assertEqual('snapshot',job['monitor_state']['last_output_hash'])
            return True,'skip','[SILENT]',None
        self.job['monitor_state']['last_output_hash']=None  # Native automatic retry must not evade the cap.
        with patch.object(policy,'current_job',lambda _:self.job),patch.object(policy,'identity',return_value='same'),patch.object(policy.time,'time',return_value=100000):
            policy.run(skipped,self.job)
        self.assertEqual(3,json.loads(policy.state_path(self.job).read_text())['pending']['attempts'])

    def test_installer_check_is_readonly_and_native_edits_preserve_job_fields(self):
        import contextlib,io
        spec=importlib.util.spec_from_file_location('installer',Path(sys.argv[1])/'scripts/hermes/install-cron-policy.py')
        installer=importlib.util.module_from_spec(spec);spec.loader.exec_module(installer)
        jobs={role:[] for role in ('head-coordinator','board-steward')}
        for i,(role,name,*_) in enumerate(installer.JOBS):
            jobs[role].append({'id':f'{i+1:012x}','name':name,'prompt':'old','model':'keep-model',
                               'enabled':True,'deliver':'keep-recipient','schedule':{'kind':'interval','minutes':240}})
        for role,entries in jobs.items():
            home=self.root/'profiles'/role;(home/'cron').mkdir(parents=True)
            (home/'cron/jobs.json').write_text(json.dumps({'jobs':entries}));(home/'SOUL.md').write_text('Operator notes stay.\n')
        for name in installer.EDITS:
            p=self.root/'hermes-agent'/name;p.parent.mkdir(parents=True,exist_ok=True);p.write_text('# native\n')
        def edit(command,**kwargs):
            path=self.root/'profiles'/command[2]/'cron/jobs.json';data=json.loads(path.read_text())
            job=next(j for j in data['jobs'] if j['id']==command[5]);job['prompt']=command[7]
            job['context_from']=['self'] if '--continuity' in command else []
            path.write_text(json.dumps(data))
        with patch.object(installer,'adapt',side_effect=lambda name,text:text.replace('# native','# adapted')),contextlib.redirect_stdout(io.StringIO()):
            before={p:p.read_bytes() for p in self.root.rglob('*') if p.is_file()}
            self.assertEqual(1,installer.install(self.root,True))
            self.assertEqual(before,{p:p.read_bytes() for p in before})
            with patch.object(installer.subprocess,'run',side_effect=edit):self.assertEqual(0,installer.install(self.root))
            self.assertEqual(0,installer.install(self.root,True))
        dependency=(Path(sys.argv[1])/'scripts/hermes/capability_recovery.py').read_bytes()
        for relative in ('scripts/capability_recovery.py',
                         'profiles/board-steward/scripts/capability_recovery.py',
                         'hermes-agent/cron/nixhomeserver_capability_recovery.py'):
            self.assertEqual(dependency,(self.root/relative).read_bytes())
        progress=(Path(sys.argv[1])/'scripts/hermes/board_progress.py').read_bytes()
        for relative in ('scripts/board_progress.py','profiles/board-steward/scripts/board_progress.py'):
            self.assertEqual(progress,(self.root/relative).read_bytes())
        for role in jobs:
            data=json.loads((self.root/'profiles'/role/'cron/jobs.json').read_text())['jobs']
            for job in data:
                self.assertEqual('keep-model',job['model']);self.assertEqual('keep-recipient',job['deliver'])
                self.assertEqual({'kind':'interval','minutes':240},job['schedule'])


unittest.main(argv=[sys.argv[0]])
PY
