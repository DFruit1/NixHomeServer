#!/usr/bin/env bash
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
python3 -B - "$repo" <<'PY'
import importlib.util
import io
import json
import os
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch
from contextlib import redirect_stdout

sys.path.insert(0, str(Path(sys.argv[1]) / 'scripts/hermes'))
spec = importlib.util.spec_from_file_location('release', Path(sys.argv[1]) / 'scripts/hermes/fleet-release.py')
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class ReleaseTest(unittest.TestCase):
    def test_coordinator_component_preserves_other_policy_and_refuses_native_drift(self):
        source=Path(sys.argv[1])
        native=self.root/'hermes-agent/hermes_cli/nixhomeserver_coordinator_repair.py'
        native.parent.mkdir(parents=True);native.write_text('old = True\n')
        soul=self.root/'profiles/head-coordinator/SOUL.md';soul.parent.mkdir(parents=True)
        soul.write_text('<!-- hermes-coordinator-role -->\nold role\n<!-- /hermes-coordinator-role -->\nIndependent policy\n')
        release.install_files(self.root,{native:native.read_text(),soul:soul.read_text()},'a'*64)
        manifest_path=release.journal(self.root,'a'*64)
        manifest=json.loads(manifest_path.read_text());manifest['status']='active';manifest_path.write_text(json.dumps(manifest))
        (self.root/'state/fleet/current.json').write_text(json.dumps({'revision':'a'*64,'status':'active'}))
        soul.write_text(soul.read_text().replace('Independent policy','Independent newer policy'))
        before=soul.read_bytes();history=manifest_path.read_bytes();retained=[]
        with patch.object(release,'source_changes',return_value={native:'new = True\n'}):
            pending=release.coordinator_component_files(self.root,source,owners={},retained=retained)
        self.assertIn('Independent newer policy',pending[soul])
        self.assertIn('kanban_manage',pending[soul])
        self.assertEqual(before,soul.read_bytes());self.assertEqual(history,manifest_path.read_bytes())
        self.assertEqual(['profiles/head-coordinator/SOUL.md'],retained)
        self.assertEqual('new = True\n',pending[native])
        native.write_text('unrelated native edit\n')
        with patch.object(release,'source_changes',return_value={native:'new = True\n'}),self.assertRaisesRegex(ValueError,'drift'):
            release.coordinator_component_files(self.root,source,owners={},retained=[])

    def test_coordinator_component_cannot_hide_unknown_or_secret_file_drift(self):
        source=Path(sys.argv[1])
        for name in ('hermes-agent/tools/kanban_tools.py','scripts/worker_origin.py','private.env'):
            with self.subTest(name=name):
                path=self.root/name;path.parent.mkdir(parents=True,exist_ok=True);path.write_text('old\n')
                revision=release.sha(name.encode())
                release.install_files(self.root,{path:'old\n'},revision)
                manifest_path=release.journal(self.root,revision)
                manifest=json.loads(manifest_path.read_text());manifest['status']='active';manifest_path.write_text(json.dumps(manifest))
                (self.root/'state/fleet/current.json').write_text(json.dumps({'revision':revision,'status':'active'}))
                path.write_text('changed\n')
                with self.assertRaisesRegex(ValueError,'drift'):
                    release.coordinator_component_files(self.root,source,owners={},retained=[])

    def test_coordinator_component_does_not_adopt_model_or_permission_changes(self):
        self.adoption_fixture()
        with self.assertRaisesRegex(ValueError,'solely the additional fail-closed'):
            release.coordinator_component_files(self.root,Path(sys.argv[1]),owners={},retained=[])

    def test_coordinator_component_binds_inputs_before_transforming_them(self):
        source=Path(sys.argv[1]);soul=self.root/'profiles/head-coordinator/SOUL.md'
        soul.parent.mkdir(parents=True);soul.write_text('<!-- hermes-coordinator-role -->\nold role\n<!-- /hermes-coordinator-role -->\nIndependent policy\n')
        release.install_files(self.root,{soul:soul.read_text()},'a'*64)
        manifest_path=release.journal(self.root,'a'*64)
        manifest=json.loads(manifest_path.read_text());manifest['status']='active';manifest_path.write_text(json.dumps(manifest))
        (self.root/'state/fleet/current.json').write_text(json.dumps({'revision':'a'*64,'status':'active'}))
        def concurrent(*args,**kwargs):
            soul.write_text(soul.read_text()+'Concurrent operator policy\n');return {}
        with patch.object(release,'source_changes',side_effect=concurrent),self.assertRaisesRegex(ValueError,'changed during preparation'):
            release.coordinator_component_files(self.root,source,owners={},retained=[])
        self.assertIn('Concurrent operator policy',soul.read_text())

    def test_coordinator_component_retains_only_prompt_changes_in_existing_schedules(self):
        item={'profile':'board-steward','id':'scan','before':{'prompt':'old','enabled':False},
              'after':{'prompt':'old','enabled':False}}
        manifest={'schedule':{'steward':[item]}}
        with patch.object(release,'check_schedules',return_value=['steward:scan']),patch.object(release,'observed',return_value={'prompt':'new','enabled':False}):
            kept=release.coordinator_schedule_updates(self.root,manifest)
        self.assertEqual(release.sha(b'new'),kept[0]['prompt_sha256'])
        with patch.object(release,'check_schedules',return_value=['steward:scan']),patch.object(release,'observed',return_value={'prompt':'new','enabled':True}),self.assertRaises(ValueError):
            release.coordinator_schedule_updates(self.root,manifest)

    def test_coordinator_component_publication_rechecks_original_inputs(self):
        self.adoption_fixture()
        target=self.root/'race.py';target.write_text('old = True\n')
        args=SimpleNamespace(action='plan',source=self.adoption_source,component='coordinator-tools',
                             activate_steward=False,adopt_config=None,revision=None)
        def pending(root,source,plan,**kwargs):
            kwargs['inputs']['race.py']={'sha256':release.sha(target.read_bytes()),'mode':target.stat().st_mode&0o777}
            target.write_text('concurrent = True\n')
            return {target:'reviewed = True\n'}
        with patch.object(release,'source_revision',return_value='c'*40),patch.object(release,'schedule_plan',return_value=self.adoption_plan),patch.object(release,'pending_files',side_effect=pending),patch.object(release,'runtime_dependencies',return_value={}),self.assertRaisesRegex(ValueError,'after preparation'):
            release.operate(args,self.root)
        self.assertEqual('concurrent = True\n',target.read_text())

    def test_native_dependency_publication_precedes_new_tool_entrypoints(self):
        names=['hermes-agent/tools/kanban_tools.py','hermes-agent/hermes_cli/kanban_db_connect.py',
               'hermes-agent/tools/kanban_tools_schemas.py','hermes-agent/hermes_cli/nixhomeserver_coordinator_tools.py']
        for name in names:(self.root/name).parent.mkdir(parents=True,exist_ok=True)
        writes=[];real=release.atomic_write
        def record(path,*args,**kwargs):
            if path.relative_to(self.root).as_posix() in names:writes.append(path.relative_to(self.root).as_posix())
            return real(path,*args,**kwargs)
        with patch.object(release,'atomic_write',side_effect=record):
            release.install_files(self.root,{self.root/name:'value = True\n' for name in names},'d'*40)
        self.assertLess(writes.index(names[3]),writes.index(names[1]))
        self.assertLess(writes.index(names[2]),writes.index(names[0]))

    def adoption_fixture(self):
        self.config=self.root/'profiles/feature-reviewer/config.yaml'
        self.config.parent.mkdir(parents=True)
        self.old_config=("model: {default: glm-5.3, provider: 'custom:opencode-go'}\n"
                         "fallback_providers: [{provider: openai-codex, model: gpt-6.1-sol}]\n"
                         "agent: {reasoning_effort: high}\nhooks: {pre_tool_call: [retained]}\n"
                         "permissions: {shell: false}\napi_key: synthetic-retained-value\n")
        self.adopted_config=("model: {default: gpt-6.1-sol, provider: openai-codex}\n"
                             "fallback_providers: [{provider: 'custom:opencode-go', model: glm-5.3}]\n"
                             "agent: {reasoning_effort: high}\nhooks: {pre_tool_call: [retained]}\n"
                             "permissions: {shell: false}\napi_key: synthetic-retained-value\n")
        self.config.write_text(self.old_config)
        self.config.chmod(0o600)
        release.install_files(self.root,{self.config:self.old_config},'a'*64)
        manifest_path=release.journal(self.root,'a'*64)
        manifest=json.loads(manifest_path.read_text());manifest['status']='active'
        manifest_path.write_text(json.dumps(manifest))
        self.original_manifest=manifest_path.read_bytes()
        (self.root/'state/fleet/current.json').write_text(json.dumps({'revision':'a'*64,'status':'active'}))
        self.config.write_text(self.adopted_config)
        self.receipt=self.root/'approved-model-adoption.json'
        self.adoption={'schema_version':1,'prior_release':'a'*64,
                       'path':'profiles/feature-reviewer/config.yaml',
                       'prior_sha256':release.sha(self.old_config.encode()),
                       'observed_sha256':release.sha(self.adopted_config.encode()),
                       'grant_reference':'T3 cebd27fb-7963-43fb-aa17-e036048ffec6 owner model decision'}
        self.receipt.write_text(json.dumps(self.adoption))
        source=self.root/'source/scripts/hermes';source.mkdir(parents=True)
        helpers=('deadlock_recovery.py','feature_flow.py','capability_recovery.py','feature_contract.py',
                 'fleet_contract.py','fleet-release.py','fleet-evidence.py','fleet-supervisor.py','fleet-report.py',
                 'kanban-analytics.py','agent-usage.py','agent_usage_report.py','agent_usage_guard.py',
                 'langfuse_mcp.py','coordinator_trial.py','fleet_workflow.py','idle-recovery-monitor.py',
                 'kanban-board-health.sh','board_progress.py')
        for helper in helpers:(source/helper).write_text('# fixture\n')
        (source/'install-steward-readonly.py').write_text('def profile_files(root,pending):return {}\n')
        self.adoption_source=source.parents[1]
        self.adoption_plan={'pause':[],'steward':[],'daily':None,'supervisor':None,'handlers':{}}
        return manifest

    def adoption_pending(self, *, adopt=True, changes=None):
        records=[]
        with patch.object(release,'source_changes',return_value=changes or {}):
            pending=release.pending_files(self.root,self.adoption_source,self.adoption_plan,
                adopt_config=self.receipt if adopt else None,adoptions=records)
        return pending,records

    def test_explicit_model_adoption_preserves_runtime_and_old_manifest_then_rolls_back_to_owner_choice(self):
        self.adoption_fixture()
        before=self.config.read_bytes()
        pending,records=self.adoption_pending()
        self.assertEqual(before,pending[self.config].encode())
        self.assertEqual(before,self.config.read_bytes())
        self.assertEqual(1,len(records))
        self.assertEqual(self.adoption['grant_reference'],records[0]['grant_reference'])
        self.assertEqual(release.sha(self.receipt.read_bytes()),records[0]['receipt_sha256'])
        self.assertEqual(self.original_manifest,release.journal(self.root,'a'*64).read_bytes())
        self.assertEqual(['profiles/feature-reviewer/config.yaml'],release.check_files(self.root,'a'*64))
        transformed=self.adopted_config.replace('pre_tool_call: [retained]','pre_tool_call: [reviewed-new-hook]')
        pending,records=self.adoption_pending(changes={self.config:transformed})
        release.install_files(self.root,pending,'b'*64,context={'config_adoptions':records})
        manifest=json.loads(release.journal(self.root,'b'*64).read_text())
        self.assertEqual(records,manifest['config_adoptions'])
        self.assertEqual(transformed,self.config.read_text())
        release.rollback_files(self.root,'b'*64)
        self.assertEqual(before,self.config.read_bytes())
        self.assertEqual(self.original_manifest,release.journal(self.root,'a'*64).read_bytes())

    def test_model_adoption_requires_explicit_receipt_and_exact_single_drift(self):
        self.adoption_fixture()
        with self.assertRaises(ValueError):self.adoption_pending(adopt=False)
        release.atomic_write(self.root/'scripts/unowned.py','changed=1\n',mode=0o600)
        old=json.loads(release.journal(self.root,'a'*64).read_text())
        old['files'].append({'path':'scripts/unowned.py','before_sha256':None,
                             'after_sha256':release.sha(b'original=1\n'),'mode':0o600,'preimage':None})
        release.journal(self.root,'a'*64).write_text(json.dumps(old))
        with self.assertRaises(ValueError):self.adoption_pending()

    def test_model_adoption_refuses_stale_receipt_or_unverified_immutable_preimage(self):
        manifest=self.adoption_fixture()
        for key,value in [('prior_release','b'*64),('prior_sha256','0'*64),('observed_sha256','0'*64),
                          ('path','scripts/owned.py'),('schema_version',True),('unknown','unused')]:
            with self.subTest(key=key):
                self.receipt.write_text(json.dumps({**self.adoption,key:value}))
                with self.assertRaises(ValueError):self.adoption_pending()
        self.receipt.write_text(json.dumps(self.adoption))
        preimage=release.journal(self.root,'a'*64).parent/manifest['files'][0]['preimage']
        preimage.write_text('tampered retained preimage')
        with self.assertRaises(ValueError):self.adoption_pending()
        preimage.unlink()
        with self.assertRaises(ValueError):self.adoption_pending()

    def test_model_adoption_refuses_credential_tool_reasoning_endpoint_and_duplicate_fallback_changes(self):
        self.adoption_fixture()
        changes=[('synthetic-retained-value','different-synthetic-value'),('shell: false','shell: true'),
                 ('pre_tool_call: [retained]','pre_tool_call: []'),('reasoning_effort: high','reasoning_effort: low'),
                 ('provider: openai-codex}','provider: openai-codex, base_url: https://example.invalid}'),
                 ('model: glm-5.3}]','model: glm-5.3, key_env: CHANGED}]'),
                 ('model: glm-5.3}]','model: glm-5.3}, {provider: openai-codex, model: gpt-6.1-sol}]')]
        for before,after in changes:
            with self.subTest(change=after):
                changed=self.adopted_config.replace(before,after)
                self.assertNotEqual(self.adopted_config,changed)
                self.config.write_text(changed)
                self.receipt.write_text(json.dumps({**self.adoption,'observed_sha256':release.sha(changed.encode())}))
                with self.assertRaises(ValueError):self.adoption_pending()

    def test_model_adoption_refuses_modes_symlinks_and_composition_reverting_model_order(self):
        self.adoption_fixture()
        self.config.chmod(0o640)
        with self.assertRaises(ValueError):self.adoption_pending()
        self.config.chmod(0o600)
        with self.assertRaises(ValueError):self.adoption_pending(changes={self.config:self.old_config})
        target=self.root/'retained-config';self.config.rename(target);self.config.symlink_to(target)
        with self.assertRaises(ValueError):self.adoption_pending()

    def test_model_adoption_is_bound_to_plan_and_apply_identity_and_does_not_skip_schedule_or_dependencies(self):
        self.adoption_fixture()
        arguments=SimpleNamespace(action='plan',source=self.adoption_source,revision=None,review_card=None,
                                  activate_steward=False,adopt_config=self.receipt)
        def invoke():
            output=io.StringIO()
            with redirect_stdout(output),patch.object(release,'source_revision',return_value='c'*40),\
                 patch.object(release,'schedule_plan',return_value=self.adoption_plan),\
                 patch.object(release,'source_changes',return_value={}),\
                 patch.object(release,'runtime_dependencies',return_value={}):
                result=release.operate(arguments,self.root)
            return result,output.getvalue()
        result,output=invoke();self.assertEqual(0,result)
        plan=json.loads(output);self.assertEqual(1,len(plan['config_adoptions']))
        first=plan['revision']
        self.receipt.write_text(json.dumps({**self.adoption,'grant_reference':'Different exact owner decision'}))
        self.assertNotEqual(first,json.loads(invoke()[1])['revision'])
        arguments.action='apply'
        with self.assertRaisesRegex(ValueError,'runtime dependency'):invoke()
        self.assertEqual(self.adopted_config,self.config.read_text())

    def test_adoption_apply_and_explicit_rollback_land_on_clean_immutable_owner_baseline(self):
        self.adoption_fixture()
        for name in ('deadlock_recovery.py','kanban-retry-breaker.sh','kanban-aging-escalation.py',
                     'cron-loop-monitor.py','review-taskforce-tick.sh'):
            (self.root/'scripts'/name).write_text('# retained fixture dependency\n')
        arguments=SimpleNamespace(action='apply',source=self.adoption_source,revision=None,review_card=None,
                                  activate_steward=False,adopt_config=self.receipt)
        transformed=self.adopted_config.replace('pre_tool_call: [retained]','pre_tool_call: [reviewed-new-hook]')
        with redirect_stdout(io.StringIO()),patch.object(release,'source_revision',return_value='c'*40),\
             patch.object(release,'schedule_plan',return_value=self.adoption_plan),\
             patch.object(release,'source_changes',return_value={self.config:transformed}),\
             patch.object(release,'runtime_dependencies',return_value={}),\
             patch.object(release,'apply_schedules') as schedules:
            self.assertEqual(0,release.operate(arguments,self.root))
        schedules.assert_called_once()
        union=json.loads((self.root/'state/fleet/current.json').read_text())
        manifest=json.loads(release.journal(self.root,union['revision']).read_text())
        baseline=manifest['previous_release']
        self.assertNotEqual('a'*64,baseline['revision'])
        self.assertEqual('active',json.loads(release.journal(self.root,baseline['revision']).read_text())['status'])
        self.assertEqual(transformed,self.config.read_text())
        # Adoption is one operation's provenance; ordinary clean reapply uses
        # desired source/content identity and must not mint another journal.
        arguments.adopt_config=None
        journals=sorted((self.root/'state/fleet/releases').glob('*/manifest.json'))
        with redirect_stdout(io.StringIO()),patch.object(release,'source_revision',return_value='c'*40),\
             patch.object(release,'schedule_plan',return_value=self.adoption_plan),\
             patch.object(release,'source_changes',return_value={self.config:transformed}),\
             patch.object(release,'runtime_dependencies',return_value={}),\
             patch.object(release,'install_files',side_effect=AssertionError('clean reapply must not install')):
            self.assertEqual(0,release.operate(arguments,self.root))
        self.assertEqual(journals,sorted((self.root/'state/fleet/releases').glob('*/manifest.json')))
        # Explicit revision rollback must work even if current publication was
        # interrupted and the pointer still names the old, visibly drifted one.
        (self.root/'state/fleet/current.json').write_text(json.dumps({'revision':'a'*64,'status':'active'}))
        arguments.action='rollback';arguments.revision=union['revision'];arguments.adopt_config=None
        self.assertEqual(0,release.operate(arguments,self.root))
        self.assertEqual(baseline,json.loads((self.root/'state/fleet/current.json').read_text()))
        self.assertEqual([],release.check_files(self.root,baseline['revision']))
        self.assertEqual(self.adopted_config,self.config.read_text())
        self.assertEqual(self.original_manifest,release.journal(self.root,'a'*64).read_bytes())
        with self.assertRaisesRegex(ValueError,'baseline'):
            arguments.revision=baseline['revision'];release.operate(arguments,self.root)

    def test_verified_adoption_baseline_is_reused_after_interruption_and_refuses_partial_or_changed_journal(self):
        self.adoption_fixture()
        record=release.config_adoption(self.root,self.receipt)
        baseline=release.adoption_baseline(self.root,record,install=True)
        path=release.journal(self.root,baseline['revision']);original=path.read_bytes()
        self.assertEqual(baseline,release.adoption_baseline(self.root,record,install=True))
        self.assertEqual(original,path.read_bytes())
        self.assertEqual({'revision':'a'*64,'status':'active'},json.loads((self.root/'state/fleet/current.json').read_text()))
        self.assertEqual(self.adopted_config,self.config.read_text())
        for change in ({'status':'applying'},{'files':[]},{'source':'unrelated'},
                       {'config_adoptions':[]},{'adoption_baseline':{}}):
            with self.subTest(change=change):
                path.write_text(json.dumps({**json.loads(original),**change}))
                with self.assertRaises(ValueError):release.adoption_baseline(self.root,record,install=True)
        path.write_bytes(original)
        self.config.write_text(self.adopted_config+'# another writer\n')
        with self.assertRaises(ValueError):release.adoption_baseline(self.root,record,install=True)

    def test_adoption_refuses_prior_postimage_unavailable_dependency_or_schedule_drift(self):
        manifest=self.adoption_fixture()
        path=release.journal(self.root,'a'*64)
        manifest['files'][0]['before_sha256']='0'*64
        path.write_text(json.dumps(manifest))
        with self.assertRaisesRegex(ValueError,'postimage'):self.adoption_pending()
        manifest['files'][0]['before_sha256']=manifest['files'][0]['after_sha256']
        manifest['dependencies']={'scripts/owned.py':'0'*64}
        path.write_text(json.dumps(manifest))
        with self.assertRaisesRegex(ValueError,'dependency'):self.adoption_pending()
        manifest.pop('dependencies');manifest['schedule']=self.adoption_plan
        path.write_text(json.dumps(manifest))
        with patch.object(release,'check_schedules',return_value=['owner-changed-schedule']):
            with self.assertRaisesRegex(ValueError,'schedule'):self.adoption_pending()

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

    def test_actual_helper_rollback_cannot_discard_iteration_guard_after_reservation_or_history(self):
        import sqlite3
        helper=self.root/'hermes-agent/hermes_cli/nixhomeserver_resume_recovered.py'
        helper.parent.mkdir(parents=True)
        # Actual predecessor and candidate bytes, not a helper-identity mock.
        old=(release.HERE.parents[1]/'scripts/tests/fixtures/hermes-iteration/resume-pre-iteration.py').read_text()
        new=(release.HERE/'resume_recovered.py').read_text()
        helper.write_text(old)
        release.install_files(self.root,{**self.pending,helper:new},'c'*64)
        journal=release.journal(self.root,'c'*64);before=journal.read_bytes()
        reservation=self.root/'runtime/recovered-resume/test--t_example--iteration-10-20.json'
        reservation.parent.mkdir(parents=True);reservation.write_text('{}')
        with self.assertRaisesRegex(ValueError,'iteration'):
            release.rollback_files(self.root,'c'*64)
        self.assertEqual(new,helper.read_text());self.assertEqual(before,journal.read_bytes())
        self.assertEqual('new = 2\n',self.file.read_text())
        reservation.unlink()
        dbpath=self.root/'kanban/boards/test/kanban.db';dbpath.parent.mkdir(parents=True)
        with sqlite3.connect(dbpath) as db:
            db.execute('CREATE TABLE task_events(kind TEXT,payload TEXT)')
            db.execute('CREATE TABLE tasks(status TEXT,current_run_id INTEGER,worker_pid INTEGER,claim_lock TEXT,claim_expires INTEGER)')
            db.execute('CREATE TABLE task_runs(status TEXT,outcome TEXT,ended_at INTEGER,worker_pid INTEGER)')
            db.execute('INSERT INTO task_events VALUES(?,?)',('unblocked',json.dumps({
                'iteration_continuation':{'source_run':10,'source_event':20}})))
        with self.assertRaisesRegex(ValueError,'iteration'):
            release.require_rollback_compatibility(self.root,json.loads(before))
        with self.assertRaisesRegex(ValueError,'iteration'):
            release.rollback_files(self.root,'c'*64,dry_run=True)
        self.assertEqual(new,helper.read_text());self.assertEqual(before,journal.read_bytes())
        with sqlite3.connect(dbpath) as db:
            db.execute('UPDATE task_events SET kind=?,payload=?',('gave_up',json.dumps({
                'budget_used':150,'budget_max':150,'trigger_outcome':'timed_out'})))
        # No classification, release or reservation: the raw native trip alone
        # already requires preservation of the unblock/claim guards.
        with self.assertRaisesRegex(ValueError,'iteration'):
            release.rollback_files(self.root,'c'*64)
        self.assertEqual(new,helper.read_text());self.assertEqual(before,journal.read_bytes())
        with sqlite3.connect(dbpath) as db:
            db.execute('UPDATE task_events SET kind=?,payload=?',('timed_out',json.dumps({
                'error':'Iteration budget exhausted (150/150) — task could not complete within the allowed iterations',
                'failures':1,'retry_status':'ready'})))
        with self.assertRaisesRegex(ValueError,'iteration'):
            release.rollback_files(self.root,'c'*64)
        self.assertEqual(new,helper.read_text());self.assertEqual(before,journal.read_bytes())
        # A compatible predecessor retains the guard and can be restored even
        # with the exact same permanent consumption evidence.
        release.install_files(self.root,{helper:new+'\n# reviewed successor\n'},'d'*64)
        release.rollback_files(self.root,'d'*64)
        self.assertEqual(new,helper.read_text())

    def test_actual_helper_rollback_before_iteration_use_requires_a_compatible_guard(self):
        helper=self.root/'hermes-agent/hermes_cli/nixhomeserver_resume_recovered.py'
        helper.parent.mkdir(parents=True);helper.write_text('# pre-iteration helper\n')
        release.install_files(self.root,{helper:(release.HERE/'resume_recovered.py').read_text()},'c'*64)
        before=helper.read_bytes()
        with self.assertRaisesRegex(ValueError,'compatible'):
            release.rollback_files(self.root,'c'*64)
        self.assertEqual(before,helper.read_bytes())

    def iteration_rollback_board(self):
        import sqlite3
        path=self.root/'kanban/boards/test/kanban.db';path.parent.mkdir(parents=True)
        with sqlite3.connect(path) as db:
            db.execute('CREATE TABLE task_events(kind TEXT,payload TEXT)')
            db.execute('CREATE TABLE tasks(status TEXT,current_run_id INTEGER,worker_pid INTEGER,claim_lock TEXT,claim_expires INTEGER)')
            db.execute('CREATE TABLE task_runs(status TEXT,outcome TEXT,ended_at INTEGER,worker_pid INTEGER)')
        helper=self.root/'hermes-agent/hermes_cli/nixhomeserver_resume_recovered.py'
        helper.parent.mkdir(parents=True);helper.write_text('# predecessor without guard\n')
        release.install_files(self.root,{helper:(release.HERE/'resume_recovered.py').read_text()},'c'*64)
        return path,helper

    def test_iteration_downgrade_refuses_active_native_run_before_its_first_budget_trip(self):
        import sqlite3
        path,helper=self.iteration_rollback_board()
        with sqlite3.connect(path) as db:
            db.execute("INSERT INTO tasks VALUES('running',1,123,'native-claim',999)")
            db.execute("INSERT INTO task_runs VALUES('running',NULL,NULL,123)")
        before=helper.read_bytes();journal=release.journal(self.root,'c'*64).read_bytes()
        with self.assertRaisesRegex(ValueError,'compatible'):
            release.rollback_files(self.root,'c'*64)
        self.assertEqual(before,helper.read_bytes())
        self.assertEqual(journal,release.journal(self.root,'c'*64).read_bytes())

    def test_iteration_downgrade_cannot_race_a_new_board_during_restore(self):
        import sqlite3
        path,helper=self.iteration_rollback_board()
        write=release.atomic_write;attempts=[]
        def race(target,*args,**kwargs):
            if target==helper:
                new=self.root/'kanban/boards/new-board/kanban.db';new.parent.mkdir(parents=True)
                with sqlite3.connect(new) as db:
                    db.execute('CREATE TABLE task_events(kind TEXT,payload TEXT)')
                    db.execute('INSERT INTO task_events VALUES(?,?)',('gave_up',json.dumps({'budget_max':150})))
                attempts.append(True)
            return write(target,*args,**kwargs)
        before=helper.read_bytes();journal=release.journal(self.root,'c'*64).read_bytes()
        with patch.object(release,'atomic_write',side_effect=race):
            with self.assertRaisesRegex(ValueError,'compatible'):
                release.rollback_files(self.root,'c'*64)
        self.assertEqual([],attempts)
        self.assertEqual(before,helper.read_bytes())
        self.assertEqual(journal,release.journal(self.root,'c'*64).read_bytes())

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
        for name in ('hermes_common','hermes_config','coordinator_trial','worker_runtime_adapter','fleet_runtime_adapter','coordinator_repair_adapter','coordinator_tools_adapter','recovered_resume_adapter','resume_recovered','worker_origin_adapter'):
            (source/(name+'.py')).write_text('ORIGIN = "source"\n')
        (source/'coordinator_repair.py').write_text('revision = \"qualified\"\n')
        (source/'coordinator_repair_adapter.py').write_text(
            'def adapt(name,text): return text+"-source-amended"\n')
        (source/'recovered_resume_adapter.py').write_text('def adapt(name,text): return text\n')
        (source/'coordinator_tools_adapter.py').write_text('def adapt(name,text): return text+"-source-managed"\n')
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
        (source/'install-recovered-resume.py').write_text('def pending_files(root, *, origin_candidate=None):\n    assert origin_candidate == "origin-source"\n    native=root/"hermes-agent"\n    pairs=[(native/"tools/kanban_tools.py","old-handler","handler-source-amended"),\n           (native/"tools/kanban_tools_schemas.py","old-schema","schema-source-amended"),\n           (native/"hermes_cli/nixhomeserver_coordinator_repair.py",None,\'revision = "qualified"\\n\'),\n           (native/"hermes_cli/nixhomeserver_resume_recovered.py","old-resume","qualified-resume")]\n    if (root/"missing-prerequisite").exists():\n        pairs.append((native/"hermes_cli/nixhomeserver_unowned_recovery.py",None,"required"))\n    return root,pairs,[]\n')
        previous_path=sys.path[:]
        before_modules={name:sys.modules.get(name) for name in ('coordinator_repair_adapter','recovered_resume_adapter','resume_recovered')}
        result=release.source_changes(self.root,source,workers=True)
        self.assertEqual('kept',result[self.root/'taskforce'])
        self.assertEqual('sourcesource',result[self.root/'worker'])
        self.assertEqual('origin-source',result[self.root/'hermes-agent/hermes_cli/nixhomeserver_worker_origin.py'])
        self.assertEqual('qualified-resume',result[self.root/'hermes-agent/hermes_cli/nixhomeserver_resume_recovered.py'])
        for name,base in [('kanban_tools.py','handler'),('kanban_tools_schemas.py','schema')]:
            self.assertEqual(base+'-source-amended-source-managed',result[self.root/'hermes-agent/tools'/name])
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
