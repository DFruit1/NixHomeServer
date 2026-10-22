#!/usr/bin/env bash
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
python3 -B - "$repo" <<'PY'
import importlib.util
from contextlib import closing
import json
import os
from pathlib import Path
import sqlite3
import sys
import tempfile
import unittest
import yaml
from unittest.mock import patch

source = Path(sys.argv[1])/'scripts/hermes/runtime-evidence/__init__.py'
spec = importlib.util.spec_from_file_location('runtime_evidence', source)
evidence = importlib.util.module_from_spec(spec)
spec.loader.exec_module(evidence)


class EvidenceTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='hermes-runtime-evidence-test-')
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name)/'profiles/feature-reviewer'
        self.home.mkdir(parents=True)
        (self.home/'SOUL.md').write_text('Role boundaries')
        with closing(sqlite3.connect(self.home/'state.db')) as db:
            db.execute('CREATE TABLE sessions(id TEXT,system_prompt_hash TEXT)')
            db.execute('INSERT INTO sessions VALUES (?,?)',('session-a','a'*64))
            db.commit()
        self.config = {'model': {'default': 'primary', 'provider': 'custom:provider'},
                       'agent': {'reasoning_effort': 'high'},
                       'plugins': {'enabled': ['observability/langfuse'], 'disabled': []},
                       'dashboard': {'password': 'SECRET'}, 'api_key': 'SECRET'}

    def snapshot(self, **kwargs):
        return evidence.snapshot(self.home,self.config,session_id='session-a',
                                 model='fallback',provider='openai-codex',**kwargs)

    def test_snapshot_is_allowlisted_and_records_wire_reasoning(self):
        result = self.snapshot(request={'body': {'reasoning': {'effort': 'low'},
                                                'messages': ['SECRET'], 'api_key': 'SECRET'}})
        self.assertEqual('feature-reviewer', result['profile'])
        self.assertEqual('low', result['reasoning_effort'])
        self.assertEqual('fallback', result['model'])
        self.assertEqual('a'*64,result['persisted_prompt_sha256'])
        self.assertNotIn('SECRET',json.dumps(result))
        self.assertNotIn('messages',json.dumps(result))

    def test_disk_snapshot_changes_but_persisted_prompt_identity_stays_separate(self):
        first=self.snapshot()
        (self.home/'SOUL.md').write_text('Changed disk instructions')
        second=self.snapshot()
        self.assertNotEqual(first['soul_on_disk_sha256'], second['soul_on_disk_sha256'])
        self.assertEqual(first['persisted_prompt_sha256'],second['persisted_prompt_sha256'])
        self.config['api_key']='DIFFERENT SECRET'
        self.assertEqual(second['config_settings_sha256'],self.snapshot()['config_settings_sha256'])

    def test_missing_session_database_is_not_created(self):
        (self.home/'state.db').unlink()
        self.assertIsNone(self.snapshot()['persisted_prompt_sha256'])
        self.assertFalse((self.home/'state.db').exists())

    def test_profile_scope_and_failed_export_cannot_break_inference(self):
        received=[]
        hooks={}
        class Context:
            def register_hook(self,name,callback): hooks[name]=callback
        evidence.register(Context())
        with patch.object(evidence,'runtime_scope',return_value=(self.home,self.config)), \
             patch.object(evidence,'export',side_effect=lambda meta,**kw:received.append((meta,kw))), \
             patch.dict(os.environ,{'HERMES_KANBAN_BOARD':'fixture','HERMES_KANBAN_TASK':'t_fixture',
                                    'HERMES_KANBAN_RUN_ID':'123'}):
            hooks['pre_api_request'](session_id='session-a',model='fallback',provider='openai-codex',
                                     turn_id='turn-a',api_request_id='request-a')
        self.assertEqual('feature-reviewer',received[0][0]['profile'])
        self.assertEqual('t_fixture',received[0][0]['card_id'])
        with patch.object(evidence,'runtime_scope',side_effect=ValueError('SECRET')):
            with self.assertLogs(evidence.logger,level='WARNING') as logs:
                hooks['pre_api_request'](session_id='session-a')
        self.assertNotIn('SECRET',''.join(logs.output))
        with patch.object(evidence,'runtime_scope',return_value=(self.home,self.config)), \
             patch.object(evidence,'export',side_effect=OSError('SECRET')):
            with self.assertLogs(evidence.logger,level='INFO') as logs:
                hooks['pre_api_request'](session_id='session-a')
        self.assertIn('hermes_runtime_evidence',''.join(logs.output))
        self.assertNotIn('SECRET',''.join(logs.output))

    def test_native_trace_correlation_and_metadata_only_export(self):
        captured={}
        class Span:
            def end(self):captured['ended']=True
        class Client:
            def create_trace_id(self,seed):captured['seed']=seed;return 'trace-id'
            def start_observation(self,**kwargs):captured.update(kwargs);return Span()
        evidence.export({'profile':'fixture'},session_id='session-a',task_id='task-a',
                        turn_id='turn-a',api_request_id='request-a',client=Client())
        self.assertEqual('session-a::task-a',captured['seed'])
        self.assertEqual({'trace_id':'trace-id'},captured['trace_context'])
        self.assertEqual('span',captured['as_type'])
        self.assertNotIn('input',captured)
        self.assertNotIn('output',captured)
        self.assertNotIn('usage_details',captured)
        self.assertTrue(captured['ended'])

    def test_unknown_reasoning_is_unknown_not_configured_effort(self):
        self.assertIsNone(self.snapshot()['reasoning_effort'])
        self.assertIsNone(self.snapshot(request={'body':{'reasoning_effort':'SECRET'}})['reasoning_effort'])
        self.assertIsNone(self.snapshot(request={'body':None})['reasoning_effort'])

    def test_disabling_existing_langfuse_also_stops_the_companion(self):
        self.config['plugins']['disabled']=['observability/langfuse']
        with patch.object(evidence,'runtime_scope',return_value=(self.home,self.config)), \
             patch.object(evidence,'export') as export:
            evidence.on_request(session_id='session-a')
        export.assert_not_called()


class InstallerTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        sys.path.insert(0,str(source.parent.parent))
        spec=importlib.util.spec_from_file_location('runtime_installer',source.parent.parent/'install-runtime-evidence.py')
        cls.installer=importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.installer)

    def test_enable_preserves_every_other_setting_and_is_idempotent(self):
        for enabled in ('[homeassistant, observability/langfuse]',
                        '\n    - homeassistant\n    - observability/langfuse'):
            old='model: {default: private-model}\nplugins:\n  enabled: '+enabled+'\n  disabled: []\n'
            updated=self.installer.enable(old)
            expected=yaml.safe_load(old)
            expected['plugins']['enabled'].append('runtime-evidence')
            self.assertEqual(expected,yaml.safe_load(updated))
            self.assertEqual(updated,self.installer.enable(updated))

    def test_disabled_or_absent_langfuse_is_not_enabled_indirectly(self):
        old='plugins: {enabled: [homeassistant], disabled: []}\n'
        self.assertEqual(old,self.installer.enable(old))
        with self.assertRaises(ValueError):
            self.installer.enable('plugins: {enabled: [], enabled: [observability/langfuse]}')

    def test_installer_refreshes_both_qualified_verifier_roles(self):
        with tempfile.TemporaryDirectory(prefix='hermes-runtime-auditor-test-') as tmp:
            root=Path(tmp)
            for profile in ('feature-reviewer','project-auditor'):
                soul=root/'profiles'/profile/'SOUL.md'
                soul.parent.mkdir(parents=True)
                soul.write_text('Owner note\n<!-- hermes-review-taskforce -->\nStale role\n'
                                '<!-- /hermes-review-taskforce -->\nPreserved section\n')
            self.assertEqual(1,self.installer.install(root,check=True))
            self.assertEqual(0,self.installer.install(root))
            for profile in ('feature-reviewer','project-auditor'):
                text=(root/'profiles'/profile/'SOUL.md').read_text()
                self.assertNotIn('Stale role',text)
                self.assertIn('Owner note',text)
                self.assertIn('Preserved section',text)
                self.assertIn('hermes-review-evidence.md',text)
            self.assertEqual(0,self.installer.install(root,check=True))

    def test_check_mode_does_not_write_and_install_converges(self):
        with tempfile.TemporaryDirectory(prefix='hermes-runtime-installer-test-') as tmp:
            root=Path(tmp)
            config=root/'config.yaml'
            config.write_text('plugins: {enabled: [observability/langfuse], disabled: []}\n')
            before=config.read_bytes()
            reviewer=root/'profiles/feature-reviewer/SOUL.md'
            reviewer.parent.mkdir(parents=True)
            reviewer.write_text('Owner note\n<!-- hermes-review-taskforce -->\nOld role\n'
                                '<!-- /hermes-review-taskforce -->\nOther independent section\n')
            self.assertEqual(1,self.installer.install(root,check=True))
            self.assertEqual(before,config.read_bytes())
            self.assertFalse((root/'plugins').exists())
            self.assertEqual(0,self.installer.install(root))
            self.assertEqual(0,self.installer.install(root,check=True))
            self.assertEqual(['observability/langfuse','runtime-evidence'],
                             yaml.safe_load(config.read_text())['plugins']['enabled'])
            self.assertTrue(list((root/'backups/runtime-evidence').rglob('*')))
            self.assertIn('Owner note',reviewer.read_text())
            self.assertIn('Other independent section',reviewer.read_text())
            self.assertIn('hermes-review-evidence.md',reviewer.read_text())
            self.assertTrue((root/'scripts/hermes-review-evidence.md').is_file())


unittest.main(argv=['runtime-evidence'],verbosity=2)
PY
