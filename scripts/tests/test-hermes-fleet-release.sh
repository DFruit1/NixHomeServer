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
                if '--script' in args:job['script']=args[args.index('--script')+1]
                if '--no-agent' in args:job['no_agent']=True
                if '--agent' in args:job['no_agent']=False
        path.write_text(json.dumps(data))

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
        for name in ('hermes_common','hermes_config','worker_runtime_adapter','fleet_runtime_adapter'):
            (source/(name+'.py')).write_text('ORIGIN = "source"\n')
        (source/'install-review-taskforce.py').write_text(
            'def changed_files(root):\n    return {root/"taskforce":"kept"}\n')
        (source/'install-worker-policy.py').write_text(
            'import worker_runtime_adapter, fleet_runtime_adapter\n'
            'def pending_files(root,pending):\n'
            '    return {**pending,root/"worker":worker_runtime_adapter.ORIGIN+fleet_runtime_adapter.ORIGIN}\n')
        previous_path=sys.path[:]
        result=release.source_changes(self.root,source,workers=True)
        self.assertEqual('kept',result[self.root/'taskforce'])
        self.assertEqual('sourcesource',result[self.root/'worker'])
        self.assertEqual(previous_path,sys.path)

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
