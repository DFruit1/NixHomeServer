#!/usr/bin/env bash
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if [[ "${HERMES_FIXTURE_ACTIVE:-}" != 1 ]]; then
  exec python3 "$repo/scripts/hermes/fixture-runner.py" --repo "$repo" --suite "$0"
fi
python3 -B - "$repo" <<'PY'
import json, os, sqlite3, sys, tempfile, time, unittest
from pathlib import Path
SOURCE=Path(sys.argv[1])/'scripts/hermes'
NATIVE=Path(os.environ['HERMES_FIXTURE_NATIVE_PYTHON']).parents[2]
sys.path[:0]=[str(SOURCE),str(NATIVE)]
from hermes_cli import kanban_db as kb, kanban_db_connect as kbc
import release_conditions as rc
OPERATOR_ACTOR = rc.require_actor

class Conditions(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix='release-conditions-'); self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name)
        self.dbs={}
        from unittest.mock import patch
        schema=patch.object(kb,'SCHEMA_SQL',kb.SCHEMA_SQL+rc.ARTIFACT_SCHEMA)
        schema.start();self.addCleanup(schema.stop)
        for board in ('one','two'):
            path=self.root/'kanban/boards'/board/'kanban.db';path.parent.mkdir(parents=True)
            path.with_name('board.json').write_text('{}')
            db=kbc.connect(db_path=path);self.addCleanup(db.close);self.dbs[board]=db
        from unittest.mock import patch
        actor_patch=patch.object(rc,'require_actor',return_value={'kind':'fixture-operator'})
        actor_patch.start();self.addCleanup(actor_patch.stop)
        self.db=self.dbs['one']; self.target=self.task(self.db,'Waiting recovery')
        self.source=self.task(self.dbs['two'],'Original output')
        self.contract=dict(schema_version=1,action='resume',supplier='agent',reason='Original execution is now present',
            predicates=[dict(type='task_result',board='two',task_id=self.source,after_run_id=0,metadata={'resolved':True})])
    def task(self,db,title):
        tid=kb.create_task(db,title=title,assignee='head-coordinator',tenant='technical-recovery',workspace_kind='scratch')
        with kb.write_txn(db):
            db.execute("UPDATE tasks SET status='scheduled',worker_started_at='retained-historical-fingerprint' WHERE id=?",(tid,))
            kb._append_event(db,tid,'scheduled',{'reason':'Input supplier: agent. Waiting for original output.'})
        return tid
    def finish(self,db,tid,metadata=None,profile='head-coordinator',claim=True):
        now=int(time.time())
        with kb.write_txn(db):
            run=db.execute("INSERT INTO task_runs(task_id,status,profile,started_at,ended_at,outcome,metadata) VALUES(?,'done',?,?,?,'completed',?)",(tid,profile,now-10,now,json.dumps(metadata or {'resolved':True}))).lastrowid
            if claim:kb._append_event(db,tid,'claimed',{'profile':profile},run_id=run)
            kb._append_event(db,tid,'completed',{},run_id=run)
            db.execute("UPDATE tasks SET status='done',result='Resolved',completed_at=? WHERE id=?",(now,tid))
        rc.seal_output(db,tid,run)
        return run
    def register(self):
        return rc.register(kb,self.db,self.root,self.target,self.contract,rc.hold_version(self.db,self.target))
    def apply(self,registration):
        return rc.apply(kb,self.db,self.root,self.target,registration['registration_id'])
    def test_wait_then_cross_board_complete_preserves_all_counters(self):
        registration=self.register()
        with self.assertRaises(ValueError):self.apply(registration)
        self.finish(self.dbs['two'],self.source)
        before=dict(self.db.execute('SELECT * FROM tasks WHERE id=?',(self.target,)).fetchone())
        self.assertEqual('ready',self.apply(registration)['status'])
        after=dict(self.db.execute('SELECT * FROM tasks WHERE id=?',(self.target,)).fetchone())
        before['status']='ready';self.assertEqual(before,after)
        self.assertTrue(self.apply(registration)['already_applied'])
        self.assertEqual(0,self.db.execute("SELECT count(*) FROM task_comments WHERE task_id=?",(self.target,)).fetchone()[0])
    def test_real_native_cli_registers_and_applies_for_an_unpinned_operator(self):
        import subprocess
        contract=self.root/'contract.json';contract.write_text(json.dumps(self.contract))
        # Exercise native parsing, routing, actor checks and transaction in a
        # fresh process. Only the candidate helper is selected, never authority.
        program='''import sys,argparse,importlib.util
from pathlib import Path
sys.path[:0]=sys.argv[1:3]
import release_conditions
sys.modules['hermes_cli.nixhomeserver_release_conditions']=release_conditions
import hermes_cli
from release_conditions_adapter import adapt
for name in ('kanban_db_connect','kanban_parser','kanban'):
    path=Path(sys.argv[2])/'hermes_cli'/(name+'.py')
    qualified='hermes_cli.'+name
    spec=importlib.util.spec_from_file_location(qualified,path)
    module=importlib.util.module_from_spec(spec)
    sys.modules[qualified]=module;setattr(hermes_cli,name,module)
    exec(compile(adapt('hermes_cli/'+name+'.py',path.read_text()),str(path),'exec'),module.__dict__)
sys.argv=['hermes','--profile','default',*sys.argv[3:]]
from hermes_cli.main import main
main()
'''
        environment=dict(os.environ,HERMES_HOME=str(self.root),HERMES_KANBAN_HOME=str(self.root),HERMES_ROOT=str(self.root))
        def cli(*args):
            process=subprocess.run([os.environ['HERMES_FIXTURE_NATIVE_PYTHON'],'-B','-c',program,
                str(SOURCE),str(NATIVE),'kanban','--board','one','conditions',*args],env=environment,
                capture_output=True,text=True,timeout=15)
            self.assertEqual(0,process.returncode,process.stderr)
            return json.loads(process.stdout)
        manifest=self.root/'migration.json'
        manifest.write_text(json.dumps(dict(schema_version=1,board='one',records=[dict(
            task_id=self.target,expected_version=rc.hold_version(self.db,self.target),contract=self.contract,
            title='Reconcile the original result',body='Goal: Reconcile the original result.\nNotes: Read release-context.json.')])) )
        self.assertEqual('registered',cli('migrate','--file',str(manifest))['results'][0]['state'])
        registration=cli('register',self.target,'--version',rc.hold_version(self.db,self.target),'--file',str(contract))
        self.assertEqual(registration,cli('show',self.target)['release_conditions'])
        self.finish(self.dbs['two'],self.source)
        self.assertEqual('ready',cli('apply',self.target,'--registration-id',str(registration['registration_id']))['status'])
        self.assertEqual({'kind':'interactive-operator'},registration['actor'])
    def test_operator_admission_keeps_native_terminal_and_worker_fences(self):
        from unittest.mock import patch
        from hermes_cli import nixhomeserver_worker_origin as origin
        with patch.object(origin,'proven_terminal_origin',return_value=True):
            with self.assertRaisesRegex(ValueError,'Native model terminal'):OPERATOR_ACTOR(self.db)
        for marker in ('HERMES_KANBAN_TASK','HERMES_DELEGATED_CHILD_CONTEXT'):
            with self.subTest(marker=marker),patch.dict(os.environ,{marker:'fixture-held-origin'}):
                with self.assertRaisesRegex(ValueError,'authenticated native coordinator'):OPERATOR_ACTOR(self.db)
    def test_missing_archived_or_unclaimed_results_do_not_release(self):
        registration=self.register();self.finish(self.dbs['two'],self.source,claim=False)
        with self.assertRaises(ValueError):self.apply(registration)
        self.dbs['two'].execute("UPDATE tasks SET status='archived' WHERE id=?",(self.source,))
        with self.assertRaises(ValueError):self.apply(registration)
    def test_changed_body_invalidates_registration(self):
        registration=self.register();self.finish(self.dbs['two'],self.source)
        self.db.execute("UPDATE tasks SET body='Changed acceptance' WHERE id=?",(self.target,))
        with self.assertRaises(ValueError):self.apply(registration)
    def test_owner_and_spent_holds_never_resume(self):
        for field,value in [('block_kind','needs_input'),('block_kind','rate_limited'),('consecutive_failures',1),('block_recurrences',1),('worker_pid',123)]:
            with self.subTest(field=field,value=value):
                before=dict(self.db.execute('SELECT * FROM tasks WHERE id=?',(self.target,)).fetchone())
                self.db.execute('UPDATE tasks SET '+field+'=? WHERE id=?',(value,self.target))
                with self.assertRaises(ValueError):self.register()
                self.db.execute('UPDATE tasks SET '+field+'=? WHERE id=?',(before[field],self.target))
    def test_manual_contract_cannot_apply(self):
        self.contract.update(action='manual',supplier='owner',predicates=[])
        registration=self.register()
        with self.assertRaises(ValueError):self.apply(registration)
    def test_close_requires_explicit_diagnostic_leaf_and_review(self):
        self.contract['action']='close'
        with self.assertRaises(ValueError):self.register()
    def test_evidence_board_writer_is_locked_during_evaluation(self):
        self.finish(self.dbs['two'],self.source)
        registration=self.register()
        original=rc.evaluate
        def check(db,root,task,contract,schemas):
            import subprocess
            with self.assertRaisesRegex(sqlite3.OperationalError,'readonly'):
                db.execute('UPDATE '+schemas['two']+".tasks SET status='blocked' WHERE id=?",(self.source,))
            writer=subprocess.run([sys.executable,'-c',
                "import sqlite3,sys;db=sqlite3.connect(sys.argv[1],timeout=.01);db.execute(\"UPDATE tasks SET status='blocked' WHERE id=?\",(sys.argv[2],));db.commit()",
                str(self.root/'kanban/boards/two/kanban.db'),self.source],capture_output=True,text=True)
            self.assertNotEqual(0,writer.returncode,writer.stdout)
            self.assertIn('locked',writer.stderr)
            return original(db,root,task,contract,schemas)
        from unittest.mock import patch
        with patch.object(rc,'evaluate',side_effect=check):self.apply(registration)

    def test_comments_do_not_change_the_registered_hold(self):
        registration=self.register()
        kb.add_comment(self.db,self.target,'fixture','An observation, not release authority')
        self.assertEqual(registration['hold_version'],rc.hold_version(self.db,self.target))
    def test_migration_preserves_context_and_is_idempotent(self):
        from unittest.mock import patch
        self.contract.update(action='manual',predicates=[])
        old=dict(self.db.execute('SELECT * FROM tasks WHERE id=?',(self.target,)).fetchone())
        record=dict(task_id=self.target,expected_version=rc.hold_version(self.db,self.target),contract=self.contract,
            title='Retain the original recovery gate',body='Goal: Retain the exact recovery contract.\nNotes: Read release-context.json.')
        manifest=dict(schema_version=1,board='one',records=[record])
        with patch.object(kb,'kanban_home',return_value=self.root):
            result=rc.migrate(kb,self.db,self.root,manifest)
            self.assertEqual('registered',result['results'][0]['state'])
            attachment=self.db.execute('SELECT stored_path FROM task_attachments WHERE task_id=?',(self.target,)).fetchone()
            self.assertEqual(old,json.loads(Path(attachment[0]).read_text())['task'])
            self.assertEqual('already_registered',rc.migrate(kb,self.db,self.root,manifest)['results'][0]['state'])
        after=dict(self.db.execute('SELECT * FROM tasks WHERE id=?',(self.target,)).fetchone())
        old.update(title=record['title'],body=record['body']);self.assertEqual(old,after)
        self.assertEqual(0,self.db.execute('SELECT count(*) FROM task_comments WHERE task_id=?',(self.target,)).fetchone()[0])
    def test_real_native_completion_seals_metadata_in_the_same_transaction(self):
        import ast,release_conditions_adapter as adapter
        text=adapter.adapt('hermes_cli/kanban_db.py',(NATIVE/'hermes_cli/kanban_db.py').read_text())
        node=next(n for n in ast.parse(text).body if isinstance(n,ast.FunctionDef) and n.name=='_append_event')
        context=dict(kb.__dict__);exec(compile(ast.Module(body=[node],type_ignores=[]),'fixture','exec'),context)
        from unittest.mock import patch
        db=self.dbs['two'];db.execute("UPDATE tasks SET status='ready' WHERE id=?",(self.source,))
        with patch.dict(sys.modules,{'hermes_cli.nixhomeserver_release_conditions':rc}),patch.object(kb,'_append_event',context['_append_event']):
            self.assertIsNotNone(kb.claim_task(db,self.source))
            self.assertTrue(kb.complete_task(db,self.source,summary='Actual native completion fixture',metadata={'resolved':True},fire_lifecycle_hook=False))
        run=rc.latest_run(db,'main',self.source)
        self.assertEqual('done',run['status'])
        self.assertEqual({'resolved':True},rc.completed_run(db,'main',rc.task_row(db,self.source),run))

    def test_scoped_installer_preserves_current_files_pauses_and_binds_inputs(self):
        import importlib.util,subprocess
        spec=importlib.util.spec_from_file_location('condition_release_fixture',SOURCE/'fleet-release.py')
        release=importlib.util.module_from_spec(spec);spec.loader.exec_module(release)
        source=SOURCE.parents[1]
        # The authorised fixture mounts this checkout read-only without its
        # external Git common dir. Model only Git's known predecessor receipt;
        # native transforms, byte CAS and retained files remain real.
        from unittest.mock import patch
        def git_output(argv,**kwargs):
            value=('# maintained predecessor '+argv[-1].split(':',1)[1]+'\n' if argv[3]=='show' else 'c'*40+'\n')
            return value if kwargs.get('text') else value.encode()
        git=patch.object(release.subprocess,'check_output',side_effect=git_output)
        ancestor=patch.object(release.subprocess,'run',return_value=subprocess.CompletedProcess([],0))
        git.start();ancestor.start();self.addCleanup(git.stop);self.addCleanup(ancestor.stop)
        pending={}
        for target,original in {'scripts/fleet-release.py':'scripts/hermes/fleet-release.py','scripts/fleet-supervisor.py':'scripts/hermes/fleet-supervisor.py',
                'scripts/recovery_wait.py':'scripts/hermes/recovery_wait.py',
                'hermes-agent/hermes_cli/nixhomeserver_recovery_wait.py':'scripts/hermes/recovery_wait.py',
                'scripts/board_progress.py':'scripts/hermes/board_progress.py',
                'hermes-agent/hermes_cli/nixhomeserver_board_progress.py':'scripts/hermes/board_progress.py'}.items():
            pending[self.root/target]=subprocess.check_output(['git','-C',str(source),'show','HEAD:'+original],text=True)
        for name in ('hermes_cli/kanban_db.py','hermes_cli/kanban_db_connect.py','hermes_cli/kanban.py','hermes_cli/kanban_parser.py','tools/kanban_tools.py'):
            pending[self.root/'hermes-agent'/name]=(NATIVE/name).read_text()
        pending[self.root/'profiles/retained/SOUL.md']='Independent installed instructions remain byte-identical\n'
        policy={'technical-recovery':{'enabled':False,'interval':300},'release-conditions':{'enabled':False,'interval':300}}
        pending[self.root/'state/fleet/handlers.json']=json.dumps(policy)
        for path in pending:path.parent.mkdir(parents=True,exist_ok=True)
        release.install_files(self.root,pending,'a'*64)
        journal=release.journal(self.root,'a'*64)
        manifest=json.loads(journal.read_text());manifest.update(status='active',source_revision=subprocess.check_output(['git','-C',str(source),'rev-parse','HEAD'],text=True).strip(),retained_external_changes=['profiles/retained/SOUL.md'])
        journal.write_text(json.dumps(manifest));(self.root/'state/fleet/current.json').write_text(json.dumps(dict(revision='a'*64,status='active')))
        owners={};retained=[];inputs={}
        result=release.release_condition_files(self.root,source,owners=owners,retained=retained,inputs=inputs)
        self.assertEqual(pending[self.root/'profiles/retained/SOUL.md'],result[self.root/'profiles/retained/SOUL.md'])
        self.assertEqual(['profiles/retained/SOUL.md'],retained)
        policy_after=json.loads(result[self.root/'state/fleet/handlers.json'])
        self.assertFalse(policy_after['technical-recovery']['enabled']);self.assertEqual({'enabled':False,'interval':300},policy_after['release-conditions'])
        self.assertEqual(set(str(p.relative_to(self.root)) for p in result),set(inputs))
        rogue=self.root/'scripts/release_conditions.py';rogue.write_text('unowned helper')
        with self.assertRaisesRegex(ValueError,'outside fleet ownership'):release.release_condition_files(self.root,source,owners={},retained=[])
        rogue.unlink()
        import release_conditions_adapter
        original=release_conditions_adapter.adapt
        def concurrent(name,text):
            retained_path=self.root/'profiles/retained/SOUL.md';retained_path.write_text('Concurrent operator edit')
            return original(name,text)
        from unittest.mock import patch
        with patch.object(release,'condition_adapter',return_value=concurrent),self.assertRaisesRegex(ValueError,'changed during preparation'):
            release.release_condition_files(self.root,source,owners={},retained=[])

    def test_event_gc_retains_canonical_contracts_and_native_result_provenance(self):
        import ast,release_conditions_adapter as adapter
        registration=self.register();run=self.finish(self.dbs['two'],self.source)
        text=adapter.adapt('hermes_cli/kanban_db.py',(NATIVE/'hermes_cli/kanban_db.py').read_text())
        node=next(n for n in ast.parse(text).body if isinstance(n,ast.FunctionDef) and n.name=='gc_events')
        context=dict(kb.__dict__);exec(compile(ast.Module(body=[node],type_ignores=[]),'fixture','exec'),context)
        for db in self.dbs.values():
            db.execute("UPDATE tasks SET status='done'");db.execute('UPDATE task_events SET created_at=1')
            context['gc_events'](db,older_than_seconds=1)
        self.assertEqual(registration,rc.load(self.db,self.target))
        result=rc.completed_run(self.dbs['two'],'main',rc.task_row(self.dbs['two'],self.source),rc.latest_run(self.dbs['two'],'main',self.source))
        self.assertEqual({'resolved':True},result)
    def test_fake_coordinator_cannot_commission_scanner_authority(self):
        with self.assertRaisesRegex(ValueError,'Authenticated'):
            rc.register(kb,self.db,self.root,self.target,self.contract,rc.hold_version(self.db,self.target),actor={'profile':'head-coordinator'})
        self.assertIsNone(rc.load(self.db,self.target))

    def test_structured_workflow_cannot_be_erased_into_diagnostic_closure(self):
        self.contract['action']='close';self.contract['closure']=dict(kind='diagnostic',summary='Forbidden product disposition')
        self.contract['predicates']=[self.review()]
        created=self.db.execute("SELECT payload FROM task_events WHERE task_id=? AND kind='created' ORDER BY id LIMIT 1",(self.target,)).fetchone()
        payload=json.loads(created['payload']);payload['workflow']={'version':1,'plan_author':'head-coordinator','review':'native-review-v1'}
        self.db.execute("UPDATE task_events SET payload=? WHERE task_id=? AND kind='created'",(json.dumps(payload),self.target))
        with self.assertRaisesRegex(ValueError,'Structured workflow'):self.register()
    def test_unprepared_worktree_cannot_resume_from_unbound_source(self):
        self.db.execute("UPDATE tasks SET workspace_kind='worktree',workspace_path=NULL WHERE id=?",(self.target,))
        with self.assertRaisesRegex(ValueError,'prepared source'):self.register()
    def test_archived_board_does_not_suppress_other_boards_scan(self):
        self.contract.update(action='manual',predicates=[]);self.register()
        (self.root/'kanban/boards/two/board.json').write_text('{"archived":true}')
        inventory=rc.inspect(self.root)
        self.assertEqual([self.target],[row['task_id'] for row in inventory['manual']])
        with self.assertRaisesRegex(ValueError,'archived'):rc.board_path(self.root,'two')
    def test_selected_source_adapter_ignores_poisoned_import_cache(self):
        import importlib.util,types
        spec=importlib.util.spec_from_file_location('condition_release_source_fixture',SOURCE/'fleet-release.py')
        release=importlib.util.module_from_spec(spec);spec.loader.exec_module(release)
        from unittest.mock import patch
        poison=types.SimpleNamespace(adapt=lambda *a:(_ for _ in ()).throw(AssertionError('cached adapter used')))
        with patch.dict(sys.modules,{'release_conditions_adapter':poison}):
            adapt=release.condition_adapter(SOURCE.parents[1])
            self.assertEqual(str(SOURCE/'release_conditions_adapter.py'),adapt.__code__.co_filename)

    def test_legacy_feature_and_native_workflow_step_cannot_close_as_diagnostics(self):
        self.contract['action']='close';self.contract['closure']=dict(kind='diagnostic',summary='Forbidden feature closure')
        self.contract['predicates']=[self.review()]
        tracker=self.task(self.db,'[FEATURE TRACKER] Fixture feature')
        kb.add_comment(self.db,self.target,'fixture','Feature tracker: one:'+tracker)
        with self.assertRaisesRegex(ValueError,'Legacy feature'):self.register()
        self.db.execute('DELETE FROM task_comments WHERE task_id=?',(self.target,))
        for column in ('workflow_template_id','current_step_key'):
            self.db.execute('UPDATE tasks SET '+column+"='native-workflow' WHERE id=?",(self.target,))
            with self.assertRaisesRegex(ValueError,'Structured workflow'):self.register()
            self.db.execute('UPDATE tasks SET '+column+'=NULL WHERE id=?',(self.target,))
    def test_migration_retains_native_receipt_body_instead_of_superseding_it(self):
        from unittest.mock import patch
        self.contract.update(action='manual',predicates=[])
        self.db.execute("UPDATE task_events SET payload=? WHERE task_id=? AND kind='scheduled'",(json.dumps({'reason':'Recovery wait: {"task_id":"t_original","after_run_id":1,"until":"started"}'}),self.target))
        task=rc.task_row(self.db,self.target)
        record=dict(task_id=self.target,expected_version=rc.hold_version(self.db,self.target),contract=self.contract,title=task['title'],body='Goal: Changed presentation')
        manifest=dict(schema_version=1,board='one',records=[record])
        with patch.object(kb,'kanban_home',return_value=self.root):
            self.assertEqual('unchanged',rc.migrate(kb,self.db,self.root,manifest)['results'][0]['state'])
            record['body']=task['body'] or 'Goal: Original native wait'
            self.db.execute('UPDATE tasks SET body=? WHERE id=?',(record['body'],self.target))
            record['expected_version']=rc.hold_version(self.db,self.target)
            self.assertEqual('registered',rc.migrate(kb,self.db,self.root,manifest)['results'][0]['state'])
        self.assertEqual(0,self.db.execute("SELECT count(*) FROM task_events WHERE task_id=? AND kind='edited'",(self.target,)).fetchone()[0])
    def test_completed_source_start_provenance_survives_gc_before_waiter_applies(self):
        import ast,release_conditions_adapter as adapter
        self.contract['predicates']=[dict(type='task_event',board='two',task_id=self.source,after_run_id=0,until='started')]
        registration=self.register();run=self.finish(self.dbs['two'],self.source)
        kb._append_event(self.dbs['two'],self.source,'worker_registered',dict(pid=2345,started_at='fixture-start'),run_id=run)
        text=adapter.adapt('hermes_cli/kanban_db.py',(NATIVE/'hermes_cli/kanban_db.py').read_text())
        node=next(n for n in ast.parse(text).body if isinstance(n,ast.FunctionDef) and n.name=='gc_events')
        context=dict(kb.__dict__);exec(compile(ast.Module(body=[node],type_ignores=[]),'fixture','exec'),context)
        self.dbs['two'].execute('UPDATE task_events SET created_at=1')
        context['gc_events'](self.dbs['two'],older_than_seconds=1)
        self.assertEqual('ready',self.apply(registration)['status'])

    def test_native_wait_bridge_preserves_protocol_and_original_handler_pause(self):
        import recovery_wait,board_progress
        from unittest.mock import patch
        original=self.task(self.db,'Original same-board worker')
        now=int(time.time())
        run=self.db.execute("INSERT INTO task_runs(task_id,status,profile,started_at,ended_at,outcome) VALUES(?,'scheduled','head-coordinator',?,?,'scheduled')",(self.target,now-20,now-10)).lastrowid
        reason=recovery_wait.PREFIX+json.dumps(dict(task_id=original,after_run_id=0,until='started'))
        kb._append_event(self.db,self.target,'scheduled',{'reason':reason},run_id=run)
        self.contract['predicates']=[dict(type='native_wait',board='one',task_id=self.target,handler='technical-recovery')]
        with patch.dict(sys.modules,{'hermes_cli.nixhomeserver_recovery_wait':recovery_wait,'hermes_cli.nixhomeserver_board_progress':board_progress}):
            registration=self.register()
            with self.assertRaises(ValueError):self.apply(registration)
            source_run=self.finish(self.db,original)
            kb._append_event(self.db,original,'spawned',dict(pid=3456,started_at='fixture-start'),run_id=source_run)
            policy=self.root/'state/fleet/handlers.json';policy.parent.mkdir(parents=True)
            policy.write_text('{"technical-recovery":{"enabled":false}}')
            with patch('subprocess.run') as execute:
                report=rc.scan(self.root)
                execute.assert_not_called()
                self.assertIn('paused',report['results'][0]['reason'])
            self.assertEqual('ready',self.apply(registration)['status'])

    def test_planning_outputs_and_numeric_independence_cannot_become_verification(self):
        predicate=self.review();self.contract['predicates']=[predicate]
        self.dbs['two'].execute("UPDATE tasks SET tenant='continuous-improvement' WHERE id=?",(predicate['task_id'],))
        registration=self.register()
        with self.assertRaisesRegex(ValueError,'verification'):self.apply(registration)
        auditor=self.task(self.dbs['two'],'Auditor verification')
        self.dbs['two'].execute("UPDATE tasks SET assignee='project-auditor',tenant='verification' WHERE id=?",(auditor,))
        run=self.finish(self.dbs['two'],auditor,dict(verdict='accept',revision='a'*40,checks=[dict(command='actual check',exit_code=0)],scope={'output':'exact'},independence={'plan_author':0,'implementer':0}),profile='project-auditor')
        self.contract['predicates']=[dict(type='review_accepted',board='two',task_id=auditor,run_id=run,revision='a'*40,scope={'scope':{'output':'exact'}})]
        registration=self.register()
        with self.assertRaisesRegex(ValueError,'independent authorship'):self.apply(registration)

    def review(self,scope=None,metadata=None):
        tid=self.task(self.dbs['two'],'Independent reviewer')
        self.dbs['two'].execute("UPDATE tasks SET assignee='feature-reviewer',tenant='verification' WHERE id=?",(tid,))
        data=metadata or dict(verdict='accept',revision='a'*40,checks=[dict(command='actual check',exit_code=0)],scope=scope or {'output':'exact'})
        run=self.finish(self.dbs['two'],tid,data,profile='feature-reviewer')
        return dict(type='review_accepted',board='two',task_id=tid,run_id=run,revision='a'*40,scope={'scope':scope or {'output':'exact'}})
    def test_rewritten_completed_metadata_does_not_change_the_seal(self):
        p=self.review(metadata=dict(verdict='request-changes',revision='a'*40,checks=[dict(command='check',exit_code=0)],scope={'output':'exact'}))
        self.contract['predicates']=[p];registration=self.register()
        self.dbs['two'].execute("UPDATE task_runs SET metadata=? WHERE id=?",(json.dumps(dict(verdict='accept',revision='a'*40,checks=[dict(command='check',exit_code=0)],scope={'output':'exact'})),p['run_id']))
        with self.assertRaisesRegex(ValueError,'seal'):self.apply(registration)
    def test_acceptance_requires_exact_scope_revision_independence_and_executed_checks(self):
        for changes in ({'verdict':'unknown'},{'revision':'b'*40},{'checks':[{'command':'check','exit_code':True}]},{'scope':{'output':'different'}}):
            with self.subTest(changes=changes):
                data=dict(verdict='accept',revision='a'*40,checks=[dict(command='check',exit_code=0)],scope={'output':'exact'});data.update(changes)
                self.contract['predicates']=[self.review(metadata=data)];registration=self.register()
                with self.assertRaises(ValueError):self.apply(registration)
        self.contract['predicates']=[self.review()];registration=self.register();self.assertEqual('ready',self.apply(registration)['status'])
    def test_archived_and_newer_results_cannot_reuse_old_acceptance(self):
        p=self.review();self.contract['predicates']=[p];registration=self.register()
        self.finish(self.dbs['two'],p['task_id'],dict(verdict='request-changes'),profile='feature-reviewer')
        with self.assertRaises(ValueError):self.apply(registration)
    def test_real_parent_gates_are_rechecked(self):
        parent=self.task(self.db,'Unfinished prerequisite');kb.link_tasks(self.db,parent,self.target)
        registration=self.register();self.finish(self.dbs['two'],self.source)
        with self.assertRaisesRegex(ValueError,'parent'):self.apply(registration)
    def test_native_event_start_is_reconciliation_only_and_needs_actual_start(self):
        self.contract['predicates']=[dict(type='task_event',board='two',task_id=self.source,after_run_id=0,until='started')]
        registration=self.register();run=self.finish(self.dbs['two'],self.source)
        with self.assertRaises(ValueError):self.apply(registration)
        kb._append_event(self.dbs['two'],self.source,'spawned',dict(pid=1234,started_at='fixture'),run_id=run)
        self.assertEqual('ready',self.apply(registration)['status'])
    def test_diagnostic_closure_is_truthful_and_preserves_runs_and_failures(self):
        self.contract['action']='close';self.contract['closure']=dict(kind='diagnostic',summary='Original diagnostic superseded by the accepted result')
        self.db.execute('UPDATE tasks SET consecutive_failures=2,block_recurrences=3 WHERE id=?',(self.target,))
        version=rc.hold_version(self.db,self.target)
        import hashlib
        scope=dict(task_id=self.target,hold_version=version,kind='diagnostic',summary_sha256=hashlib.sha256(self.contract['closure']['summary'].encode()).hexdigest())
        p=self.review();p['scope']={'diagnostic_closure':scope}
        self.dbs['two'].execute('UPDATE task_runs SET metadata=? WHERE id=?',(json.dumps(dict(verdict='accept',revision='a'*40,checks=[dict(command='check',exit_code=0)],diagnostic_closure=scope)),p['run_id']))
        # This test constructs genuine completion bytes before sealing, not an
        # edit through a live API; replace only this isolated fixture's seal.
        self.dbs['two'].execute("DELETE FROM task_events WHERE kind='release_output_sealed' AND run_id=?",(p['run_id'],));rc.seal_output(self.dbs['two'],p['task_id'],p['run_id'])
        self.contract['predicates']=[p];registration=self.register()
        before=[tuple(r) for r in self.db.execute('SELECT * FROM task_runs WHERE task_id=?',(self.target,))]
        self.assertEqual('done',self.apply(registration)['status'])
        self.assertEqual((2,3),tuple(self.db.execute('SELECT consecutive_failures,block_recurrences FROM tasks WHERE id=?',(self.target,)).fetchone()))
        self.assertEqual(before,[tuple(r) for r in self.db.execute('SELECT * FROM task_runs WHERE task_id=?',(self.target,))])
        self.assertEqual(0,self.db.execute("SELECT count(*) FROM task_events WHERE task_id=? AND kind='completed'",(self.target,)).fetchone()[0])
        self.assertEqual(1,self.db.execute("SELECT count(*) FROM task_events WHERE task_id=? AND kind='diagnostic_closed'",(self.target,)).fetchone()[0])
    def test_published_attachment_is_immutable_native_evidence(self):
        import hashlib
        directory=self.root/'kanban/boards/two/attachments'/self.source;directory.mkdir(parents=True)
        path=directory/'proof.txt';path.write_bytes(b'accepted immutable bytes')
        checksum=hashlib.sha256(path.read_bytes()).hexdigest()
        attachment=self.dbs['two'].execute('INSERT INTO task_attachments(task_id,filename,stored_path,size,created_at) VALUES(?,?,?,?,?)',(self.source,path.name,str(path),path.stat().st_size,int(time.time()))).lastrowid
        self.contract['predicates']=[dict(type='attachment',board='two',task_id=self.source,filename=path.name,sha256=checksum)]
        registration=self.register()
        with self.assertRaises(ValueError):self.apply(registration)
        rc.publish(kb,self.dbs['two'],self.root,self.source,attachment,checksum,'non-secret')
        path.write_bytes(b'mutable old file changed')
        # Canonical publication bytes remain exact even if the mutable source changes.
        self.assertEqual('ready',self.apply(registration)['status'])
    def test_adapter_is_idempotent_compiles_and_publishes_real_completion_seal(self):
        import release_conditions_adapter as adapter
        for name in ('hermes_cli/kanban_db.py','hermes_cli/kanban_db_connect.py','hermes_cli/kanban.py','hermes_cli/kanban_parser.py','tools/kanban_tools.py'):
            text=(NATIVE/name).read_text();adapted=adapter.adapt(name,text)
            self.assertEqual(adapted,adapter.adapt(name,adapted));compile(adapted,name,'exec')
        import ast,types
        module=types.ModuleType('conditions_parser_fixture');module.__file__=str(NATIVE/'hermes_cli/kanban_parser.py')
        exec(adapter.adapt('hermes_cli/kanban_parser.py',(NATIVE/'hermes_cli/kanban_parser.py').read_text()),module.__dict__)
        import argparse
        parser=argparse.ArgumentParser();module.build_parser(parser.add_subparsers())
        self.assertEqual('show',parser.parse_args(['kanban','conditions','show',self.target]).conditions_action)
        text=adapter.adapt('hermes_cli/kanban_db.py',(NATIVE/'hermes_cli/kanban_db.py').read_text())
        tree=ast.parse(text);node=next(n for n in tree.body if isinstance(n,ast.FunctionDef) and n.name=='_append_event')
        context=dict(kb.__dict__);exec(compile(ast.Module(body=[node],type_ignores=[]),'fixture','exec'),context)
        from unittest.mock import patch
        with patch.dict(sys.modules,{'hermes_cli.nixhomeserver_release_conditions':rc}):
            run=self.finish(self.dbs['two'],self.source)
            self.dbs['two'].execute("DELETE FROM task_events WHERE kind='release_output_sealed' AND run_id=?",(run,))
            context['_append_event'](self.dbs['two'],self.source,'completed',{},run_id=run)
            self.assertIsNotNone(self.dbs['two'].execute("SELECT 1 FROM task_events WHERE kind='release_output_sealed' AND run_id=?",(run,)).fetchone())

unittest.main(argv=[sys.argv[0]])
PY
