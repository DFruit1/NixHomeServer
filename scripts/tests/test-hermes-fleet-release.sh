#!/usr/bin/env bash
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
python3 -B - "$repo" <<'PY'
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(sys.argv[1]) / 'scripts/hermes'))
spec = importlib.util.spec_from_file_location('release', Path(sys.argv[1]) / 'scripts/hermes/fleet-release.py')
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class ReleaseTest(unittest.TestCase):
    def test_coordinator_trial_sets_effective_medium_and_preserves_other_settings(self):
        from coordinator_trial import configure
        from hermes_config import document
        original="""model: {default: glm-5.3-flash, provider: 'custom:opencode-go'}
agent:
  reasoning_effort: high
  reasoning_overrides: {glm-5.3-flash: medium, gpt-6.1-sol: low}
  max_turns: 60
fallback_providers:
  - {provider: openai-codex, model: gpt-6.1-sol}
  - {provider: local, model: retained}
api_key: PRIVATE
"""
        fixed=configure(original);config=document(fixed)
        self.assertEqual({'default':'gpt-6.1-sol','provider':'openai-codex'},config['model'])
        self.assertEqual('medium',config['agent']['reasoning_overrides']['gpt-6.1-sol'])
        self.assertEqual('high',config['agent']['reasoning_effort'])
        self.assertEqual(60,config['agent']['max_turns'])
        self.assertEqual([{'provider':'custom:opencode-go','model':'glm-5.3-flash'},
                          {'provider':'local','model':'retained'}],config['fallback_providers'])
        self.assertIn('api_key: PRIVATE',fixed)
        self.assertEqual(fixed,configure(fixed))
        with self.assertRaises(ValueError):configure('model: a\nmodel: b\n')
        self.assertEqual('medium',document(configure('other: 1\n'))['agent']['reasoning_overrides']['gpt-6.1-sol'])

    def test_usage_collection_is_enabled_on_upgrade_and_keeps_explicit_pause(self):
        self.assertEqual({'enabled':True,'interval':300},release.schedule_plan(self.root)['handlers']['agent-usage'])
        path=self.root/'state/fleet/handlers.json';path.parent.mkdir(parents=True)
        paused={'agent-usage':{'enabled':False,'interval':900},'evidence':{'enabled':True,'interval':300},
                'usage-guard':{'enabled':False,'interval':600}}
        path.write_text(json.dumps(paused))
        self.assertEqual({**paused,'board-progress':{'enabled':True,'interval':900}},release.schedule_plan(self.root)['handlers'])

    def schedules(self):
        for profile,items in [('default',[
                {'id':'abc1','name':'kanban retry breaker','enabled':True,'schedule':{'minutes':15}},
                {'id':'abc2','name':'kanban aging escalation','enabled':True,'schedule':{'minutes':360}}]),
                ('board-steward',[{'id':'abc3','name':'hermes daily steward','enabled':True,
                  'script':'daily-steward-window.py','deliver':'simplex','no_agent':False,
                  'schedule':{'expr':'0 7 * * *'}}])]:
            home=self.root if profile=='default' else self.root/'profiles'/profile
            (home/'cron').mkdir(parents=True,exist_ok=True)
            (home/'cron/jobs.json').write_text(json.dumps({'jobs':items}))

    def native_cron(self,root,profile,*args):
        home=root if profile=='default' else root/'profiles'/profile
        path=home/'cron/jobs.json';data=json.loads(path.read_text());items=data['jobs']
        action=args[0]
        if action=='create':
            items.append({'id':'abcdef','name':release.NAME,'enabled':False,'state':'paused',
                          'paused_at':'fixture-pause','script':'fleet-supervisor.py','no_agent':True,
                          'deliver':'local','schedule':{'minutes':5}})
        else:
            job=next(j for j in items if j['id']==args[1])
            if action=='pause':job.update(enabled=False,state='paused',paused_at='fixture-pause')
            elif action=='resume':job.update(enabled=True,state='scheduled',paused_at=None)
            elif action=='edit':
                if '--prompt' in args:job['prompt']=args[args.index('--prompt')+1]
                if '--script' in args:job['script']=args[args.index('--script')+1]
                if '--no-agent' in args:job['no_agent']=True
                if '--agent' in args:job['no_agent']=False
        path.write_text(json.dumps(data))

    def test_steward_inspections_are_restored_explicitly_and_journaled(self):
        self.schedules()
        path=self.root/'profiles/board-steward/cron/jobs.json'
        data=json.loads(path.read_text())
        data['jobs'].append({'id':'steward','name':'steward opportunity scan','enabled':False,
                            'paused_at':'migration-pause','prompt':'old prompt','no_agent':False,
                            'monitor_script':'steward-opportunity-scan.py','deliver':'local',
                            'schedule':{'minutes':120}})
        path.write_text(json.dumps(data))
        self.assertFalse(release.schedule_plan(self.root)['steward'][0]['activate'])
        plan=release.schedule_plan(self.root,activate_steward=True)
        self.assertFalse(any(item['id']=='steward' for item in plan['pause']))
        checkpoint=lambda:release.schedule_snapshot(self.root,plan)
        with patch.object(release,'cron',self.native_cron):
            release.apply_schedules(self.root,plan,checkpoint=checkpoint)
            item=plan['steward'][0]
            self.assertTrue(release.active(release.current_job(self.root,item)))
            self.assertIn('LOW_ACTIVITY',release.current_job(self.root,item)['prompt'])
            self.assertEqual([],release.check_schedules(self.root,plan))
            release.restore_schedules(self.root,plan,checkpoint=checkpoint)
        self.assertEqual('old prompt',release.current_job(self.root,item)['prompt'])
        self.assertFalse(release.active(release.current_job(self.root,item)))

    def test_steward_rollback_recovers_native_success_with_lost_prompt_reply(self):
        self.schedules()
        path=self.root/'profiles/board-steward/cron/jobs.json'
        data=json.loads(path.read_text())
        data['jobs'].append({'id':'steward','name':'steward opportunity scan','enabled':False,
                            'paused_at':'migration-pause','prompt':'old prompt','no_agent':False,
                            'monitor_script':'steward-opportunity-scan.py','deliver':'local',
                            'schedule':{'minutes':120}})
        path.write_text(json.dumps(data))
        plan=release.schedule_plan(self.root,activate_steward=True)
        checkpoint=lambda:release.schedule_snapshot(self.root,plan)
        with patch.object(release,'cron',self.native_cron):
            release.apply_schedules(self.root,plan,checkpoint=checkpoint)
        def lost_reply(root,profile,*args):
            self.native_cron(root,profile,*args)
            if args[:2]==('edit','steward'):raise OSError('Successful rollback prompt edit lost its reply')
        with patch.object(release,'cron',lost_reply):
            with self.assertRaises(OSError):release.restore_schedules(self.root,plan,checkpoint=checkpoint)
        with patch.object(release,'cron',self.native_cron):
            release.restore_schedules(self.root,plan,checkpoint=checkpoint)
        job=release.current_job(self.root,plan['steward'][0])
        self.assertEqual('old prompt',job['prompt'])
        self.assertFalse(release.active(job))

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='fleet-release-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.file = self.root / 'scripts/owned.py'
        self.file.parent.mkdir()
        self.file.write_text('old = 1\n')
        self.file.chmod(0o700)
        self.pending = {self.file: 'new = 2\n', self.root / 'scripts/new.py': 'new = 3\n'}

    def test_release_checks_actual_files_and_rolls_back_modes_and_absence(self):
        release.install_files(self.root, self.pending, 'a' * 40)
        self.assertEqual([], release.check_files(self.root, 'a' * 40))
        release.rollback_files(self.root, 'a' * 40)
        self.assertEqual('old = 1\n', self.file.read_text())
        self.assertEqual(0o700, self.file.stat().st_mode & 0o777)
        self.assertFalse((self.root / 'scripts/new.py').exists())

    def test_conflicting_file_owners_refuse_before_writes(self):
        pending={};owners={}
        release.merge_owned(pending,owners,{self.file:'one'},'first')
        release.merge_owned(pending,owners,{self.file:'one'},'shared')
        with self.assertRaises(ValueError):
            release.merge_owned(pending,owners,{self.file:'different'},'other')
        self.assertEqual('old = 1\n',self.file.read_text())

    def test_worker_handoff_helper_is_published_before_native_entrypoint(self):
        helper=self.root/'hermes-agent/hermes_cli/nixhomeserver_worker_handoff.py'
        entrypoint=self.root/'hermes-agent/agent/kanban_stop.py'
        helper.parent.mkdir(parents=True);entrypoint.parent.mkdir(parents=True)
        writes=[];original=release.atomic_write
        def capture(path, text, **kwargs):
            if path in (helper,entrypoint):writes.append(path)
            return original(path,text,**kwargs)
        with patch.object(release,'atomic_write',capture):
            release.install_files(self.root,{entrypoint:'entrypoint=1\n',helper:'helper=1\n'},'a'*40)
        self.assertEqual([helper,entrypoint],writes)

    def test_rollback_cannot_drop_existing_contract_reader(self):
        import sqlite3
        path=self.root/'kanban/boards/test/kanban.db';path.parent.mkdir(parents=True)
        with sqlite3.connect(path) as db:
            db.execute('CREATE TABLE task_events(kind TEXT,payload TEXT)')
            db.execute('INSERT INTO task_events VALUES(?,?)',('created',json.dumps({'workflow':{'version':1}})))
        with self.assertRaisesRegex(ValueError,'reader'):
            release.require_rollback_compatibility(self.root,{})
        manifest=release.journal(self.root,'a'*40);manifest.parent.mkdir(parents=True)
        manifest.write_text(json.dumps({'workflow_versions':[1]}))
        release.require_rollback_compatibility(self.root,{'previous_release':{'revision':'a'*40}})

    def test_upgrades_use_source_helpers_and_restore_installed_imports(self):
        directory=self.root/'source';directory.mkdir()
        (directory/'hermes_common.py').write_text('version="new source"\n')
        (directory/'hermes_config.py').write_text('version="source config"\n')
        (directory/'coordinator_trial.py').write_text('def configure(text): return text\n')
        (directory/'install-review-taskforce.py').write_text(
            'import hermes_common,hermes_config\n'
            'def changed_files(root):return {root/"result":hermes_common.version+hermes_config.version}\n')
        before=sys.modules['hermes_common'];before_path=sys.path[:]
        result=release.source_changes(self.root,directory)
        self.assertEqual('new sourcesource config',result[self.root/'result'])
        self.assertIs(before,sys.modules['hermes_common'])
        self.assertEqual(before_path,sys.path)

    def test_retained_native_helper_drift_is_visible_and_rollback_preserves_it(self):
        helper=self.root/'scripts/feature_flow.py';helper.write_text('version=1\n')
        release.install_files(self.root,self.pending,'a'*64,
                              context={'dependencies':release.runtime_dependencies(self.root)})
        self.assertEqual([],release.check_files(self.root,'a'*64))
        helper.write_text('version=2\n')
        self.assertIn('dependency:scripts/feature_flow.py',release.check_files(self.root,'a'*64))
        self.assertEqual([],release.check_files(self.root,'a'*64,dependencies=False))
        release.rollback_files(self.root,'a'*64)
        self.assertEqual('version=2\n',helper.read_text())

    def test_rollback_preserves_other_writers_and_preflights_entire_set(self):
        release.install_files(self.root, self.pending, 'a' * 40)
        self.file.write_text('unrelated = 4\n')
        with self.assertRaises(ValueError):
            release.rollback_files(self.root, 'a' * 40)
        self.assertEqual('new = 3\n', (self.root / 'scripts/new.py').read_text())
        self.assertEqual('unrelated = 4\n', self.file.read_text())

    def test_invalid_late_target_causes_no_early_writes(self):
        link = self.root / 'scripts/late.py'
        link.symlink_to(self.file)
        with self.assertRaises(ValueError):
            release.install_files(self.root, {**self.pending, link: 'bad = 1\n'}, 'a'*40)
        self.assertEqual('old = 1\n', self.file.read_text())

    def test_reviewed_preimages_cannot_be_replaced_during_installation(self):
        preimages={str(p.relative_to(self.root)):{
            'sha256':release.sha(p.read_bytes()) if p.exists() else None,
            'mode':p.stat().st_mode & 0o777 if p.exists() else None} for p in self.pending}
        self.file.write_text('owner = 42\n')
        with self.assertRaisesRegex(ValueError,'Reviewed release input changed'):
            release.install_files(self.root,self.pending,'a'*64,preimages=preimages)
        self.assertEqual('owner = 42\n',self.file.read_text())
        self.assertFalse((self.root/'scripts/new.py').exists())
        self.file.write_text('old = 1\n');self.file.chmod(0o600)
        with self.assertRaisesRegex(ValueError,'Reviewed release input changed'):
            release.install_files(self.root,self.pending,'b'*64,preimages=preimages)

    def test_interrupted_apply_has_a_rollback_journal(self):
        original = release.atomic_write
        def fail(path, text, **kwargs):
            if path.name == 'new.py':
                raise OSError('synthetic interruption')
            return original(path, text, **kwargs)
        with patch.object(release, 'atomic_write', fail):
            with self.assertRaises(OSError):
                release.install_files(self.root, self.pending, 'a'*40)
        release.rollback_files(self.root, 'a'*40)
        self.assertEqual('old = 1\n', self.file.read_text())

    def test_schedule_plan_preserves_deliberate_pauses_and_delivery(self):
        for profile, jobs in [('default', [
                {'id':'breaker','name':'kanban retry breaker','enabled':False,'schedule':{'minutes':15}},
                {'id':'durable','name':'kanban durability sync','enabled':True}]),
                ('board-steward', [{'id':'daily','name':'hermes daily steward','enabled':True,
                                    'deliver':'simplex','script':'daily-steward-window.py',
                                    'schedule':{'expr':'0 7 * * *'},'no_agent':False}])]:
            home = self.root if profile == 'default' else self.root / 'profiles' / profile
            (home/'cron').mkdir(parents=True)
            (home/'cron/jobs.json').write_text(json.dumps({'jobs':jobs}))
        plan = release.schedule_plan(self.root)
        self.assertFalse(plan['handlers']['retry-breaker']['enabled'])
        self.assertEqual(900, plan['handlers']['retry-breaker']['interval'])
        self.assertEqual('simplex', plan['daily']['before']['deliver'])
        self.assertFalse(any(x['id']=='durable' for x in plan['pause']))

    def test_schedule_apply_and_rollback_roundtrip(self):
        self.schedules();plan=release.schedule_plan(self.root)
        def checkpoint():release.schedule_snapshot(self.root,plan)
        with patch.object(release,'cron',self.native_cron):
            release.apply_schedules(self.root,plan,checkpoint=checkpoint)
            self.assertEqual([],release.check_schedules(self.root,plan))
            self.assertTrue(plan['supervisor']['after']['enabled'])
            release.restore_schedules(self.root,plan,checkpoint=checkpoint)
        self.assertFalse(release.active(release.current_job(self.root,plan['supervisor'])))
        for item in [*plan['pause'],plan['daily']]:
            self.assertEqual(item['before'],release.owned(release.current_job(self.root,item)))

    def test_schedule_rollback_continues_after_partial_native_failure(self):
        self.schedules();plan=release.schedule_plan(self.root)
        def checkpoint():release.schedule_snapshot(self.root,plan)
        with patch.object(release,'cron',self.native_cron):
            release.apply_schedules(self.root,plan,checkpoint=checkpoint)
        calls=[]
        def fail_once(root,profile,*args):
            calls.append(args)
            if args[:2]==('resume','abc2'):raise OSError('synthetic native failure')
            self.native_cron(root,profile,*args)
        with patch.object(release,'cron',fail_once):
            with self.assertRaises(OSError):release.restore_schedules(self.root,plan)
        with patch.object(release,'cron',self.native_cron):
            release.restore_schedules(self.root,plan)
        self.assertTrue(release.active(release.current_job(self.root,plan['pause'][1])))

    def test_schedule_owner_change_is_preserved_before_any_rollback(self):
        self.schedules();plan=release.schedule_plan(self.root)
        with patch.object(release,'cron',self.native_cron):
            release.apply_schedules(self.root,plan,checkpoint=lambda:release.schedule_snapshot(self.root,plan))
        item=plan['daily'];home=self.root/'profiles/board-steward/cron/jobs.json'
        data=json.loads(home.read_text());data['jobs'][0]['deliver']='owner-change';home.write_text(json.dumps(data))
        with patch.object(release,'cron',side_effect=AssertionError('must preflight first')):
            with self.assertRaises(ValueError):release.restore_schedules(self.root,plan)

    def test_native_success_with_lost_reply_is_reconciled_from_journal(self):
        for lost_action in ('create','pause','edit','resume'):
            with self.subTest(action=lost_action):
                self.schedules();plan=release.schedule_plan(self.root)
                called=[]
                def lost_reply(root,profile,*args):
                    self.native_cron(root,profile,*args)
                    if args[0]==lost_action and not called:
                        called.append(True)
                        raise OSError('successful native mutation lost its reply')
                checkpoint=lambda:release.schedule_snapshot(self.root,plan)
                with patch.object(release,'cron',lost_reply):
                    with self.assertRaises(OSError):
                        release.apply_schedules(self.root,plan,checkpoint=checkpoint)
                with patch.object(release,'cron',self.native_cron):
                    release.restore_schedules(self.root,plan,checkpoint=checkpoint)
                for item in [*plan['pause'],plan['daily']]:
                    self.assertEqual(item['before'],release.owned(release.current_job(self.root,item)))
                self.assertFalse(release.active(release.current_job(self.root,plan['supervisor'])))

    def test_interrupted_file_apply_preserves_recovery_context(self):
        original=release.atomic_write
        def fail(path,text,**kwargs):
            if path.name=='new.py':raise OSError('interrupted file installation')
            return original(path,text,**kwargs)
        context={'schedule':{'pause':[],'daily':None,'supervisor':None},'source_revision':'b'*40,
                 'dependencies':{},'previous_release':{'revision':'c'*64,'status':'active'}}
        with patch.object(release,'atomic_write',fail):
            with self.assertRaises(OSError):
                release.install_files(self.root,self.pending,'a'*64,context=context)
        manifest=json.loads(release.journal(self.root,'a'*64).read_text())
        for key,value in context.items():self.assertEqual(value,manifest[key])

    def test_source_worker_transforms_use_selected_source_adapters(self):
        source=self.root/'source';source.mkdir()
        for name in ('hermes_common','hermes_config','coordinator_trial','worker_runtime_adapter','fleet_runtime_adapter','coordinator_repair_adapter','recovered_resume_adapter','resume_recovered','worker_origin_adapter'):
            (source/(name+'.py')).write_text('ORIGIN = "source"\n')
        (source/'coordinator_repair.py').write_text('revision = \"qualified\"\n')
        (source/'coordinator_repair_adapter.py').write_text(
            'def adapt(name,text): return text+"-source-amended"\n')
        (source/'recovered_resume_adapter.py').write_text('def adapt(name,text): return text\n')
        (source/'install-worker-origin.py').write_text(
            'def pending_files(root):\n'
            '    return [(root/"hermes-agent/hermes_cli/nixhomeserver_worker_origin.py",None,"origin-source")]\n')
        (source/'install-review-taskforce.py').write_text(
            'def changed_files(root):\n    return {root/"taskforce":"kept"}\n')
        (source/'install-worker-policy.py').write_text(
            'import worker_runtime_adapter, fleet_runtime_adapter\n'
            'def pending_files(root,pending):\n'
            '    return {**pending,root/"worker":worker_runtime_adapter.ORIGIN+fleet_runtime_adapter.ORIGIN,\n'
            '        root/"hermes-agent/tools/kanban_tools.py":"handler",\n'
            '        root/"hermes-agent/tools/kanban_tools_schemas.py":"schema"}\n')
        (source/'install-recovered-resume.py').write_text('def pending_files(root, *, origin_candidate=None):\n    assert origin_candidate == "origin-source"\n    native=root/"hermes-agent"\n    pairs=[(native/"tools/kanban_tools.py","old-handler","handler-source-amended"),\n           (native/"tools/kanban_tools_schemas.py","old-schema","schema-source-amended"),\n           (native/"hermes_cli/nixhomeserver_coordinator_repair.py",None,\'revision = "qualified"\\n\')]\n    if (root/"missing-prerequisite").exists():\n        pairs.append((native/"hermes_cli/nixhomeserver_resume_recovered.py",None,"required"))\n    return root,pairs,[]\n')
        previous_path=sys.path[:]
        before_modules={name:sys.modules.get(name) for name in ('coordinator_repair_adapter','recovered_resume_adapter','resume_recovered')}
        result=release.source_changes(self.root,source,workers=True)
        self.assertEqual('kept',result[self.root/'taskforce'])
        self.assertEqual('sourcesource',result[self.root/'worker'])
        self.assertEqual('origin-source',result[self.root/'hermes-agent/hermes_cli/nixhomeserver_worker_origin.py'])
        for name,base in [('kanban_tools.py','handler'),('kanban_tools_schemas.py','schema')]:
            self.assertEqual(base+'-source-amended',result[self.root/'hermes-agent/tools'/name])
        self.assertEqual('revision = \"qualified\"\n',result[self.root/'hermes-agent/hermes_cli/nixhomeserver_coordinator_repair.py'])
        self.assertEqual(previous_path,sys.path)
        (self.root/'missing-prerequisite').touch()
        with self.assertRaisesRegex(ValueError,'matching reviewed recovery prerequisites'):
            release.source_changes(self.root,source,workers=True)
        self.assertEqual(previous_path,sys.path)
        for name,module in before_modules.items():self.assertIs(module,sys.modules.get(name))
        self.assertFalse((self.root/'hermes-agent').exists())

    def test_recovery_installer_cannot_replace_guards_during_fleet_transaction(self):
        import subprocess
        lock=self.root/'backups/recovered-resume/install.lock'
        probe='import fcntl,sys; f=open(sys.argv[1],"a"); fcntl.flock(f,fcntl.LOCK_EX|fcntl.LOCK_NB)'
        with release.mutation_locks(self.root):
            # Qualify guards, then attempt the owning installer lock before
            # dependency/preimage collection and publication can occur.
            result=subprocess.run([sys.executable,'-c',probe,str(lock)],capture_output=True)
            self.assertNotEqual(0,result.returncode)
            self.assertIn(b'BlockingIOError',result.stderr)
        self.assertEqual(0,subprocess.run([sys.executable,'-c',probe,str(lock)],capture_output=True).returncode)
        import fcntl
        with lock.open('a') as stream:
            fcntl.flock(stream,fcntl.LOCK_EX|fcntl.LOCK_NB)
            with self.assertRaises(BlockingIOError):
                with release.mutation_locks(self.root):self.fail('qualified during active recovery installation')

    def test_native_labels_or_delegated_children_cannot_acquire_release_authority(self):
        args=SimpleNamespace(action='apply',review_card=None)
        with patch.dict(os.environ,{'HERMES_KANBAN_TASK':'t_parent','HERMES_PROFILE':'head-coordinator'}):
            with self.assertRaises(ValueError):
                release.require_authority(self.root,args,'a'*64,'b'*40,self.root)
        args.review_card='t_review'
        with patch.dict(os.environ,{'HERMES_DELEGATED_CHILD_CONTEXT':'true'}):
            with self.assertRaises(ValueError):
                release.require_authority(self.root,args,'a'*64,'b'*40,self.root)


unittest.main(argv=[sys.argv[0]])
PY
