#!/usr/bin/env bash
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
python3 -B - "$repo" <<'PY'
import copy
import ast
from contextlib import closing
import importlib.util
import json
import os
from pathlib import Path
import sqlite3
import sys
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import patch

source = Path(sys.argv[1])/'scripts/hermes/agent-usage.py'
sys.path.insert(0,str(source.parent))
spec = importlib.util.spec_from_file_location('agent_usage', source)
usage = importlib.util.module_from_spec(spec)
spec.loader.exec_module(usage)


class UsageTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.scratch = tempfile.TemporaryDirectory(prefix='agent-usage-tests-')
    @classmethod
    def tearDownClass(cls):
        cls.scratch.cleanup()
    def setUp(self):
        self.home = Path(self.scratch.name)/self._testMethodName
        self.home.mkdir()

    def test_codex_usage_is_incremental_content_free_and_deduplicated(self):
        path = self.home/'rollout.jsonl'
        rows = [
            {'type':'session_meta','payload':{'id':'session-1','cwd':'/projects/one','base_instructions':'PRIVATE'}},
            {'type':'turn_context','payload':{'model':'gpt-6.1-sol','input':'PRIVATE'}},
            {'timestamp':'2026-10-24T00:00:00Z','type':'event_msg','payload':{'type':'token_count','info':{
                'total_token_usage':{'input_tokens':100,'cached_input_tokens':60,'output_tokens':20,'reasoning_output_tokens':10,'total_tokens':120}}}},
        ]
        path.write_text(''.join(json.dumps(r)+'\n' for r in rows+[rows[-1]]))
        spans, state = usage.codex_records(path, {}, since=0)
        self.assertEqual(1,len(spans))
        attrs = usage.attributes(spans[0])
        self.assertEqual({'input':40,'cache_read_input_tokens':60,'output':20,'total':120},
                         json.loads(attrs['langfuse.observation.usage_details']))
        self.assertEqual(10,attrs['langfuse.observation.metadata.reasoning_tokens'])
        self.assertNotIn('PRIVATE',json.dumps(spans)+json.dumps(state))
        self.assertEqual([],usage.codex_records(path,state,since=0)[0])
        with path.open('a') as stream:stream.write('{"type":')
        self.assertEqual(state['offset'],usage.codex_records(path,state,since=0)[1]['offset'])
        with path.open('a') as stream:stream.write('"event_msg"}\n')
        self.assertGreater(usage.codex_records(path,state,since=0)[1]['offset'],state['offset'])

    def test_oversized_codex_content_drains_across_bounded_passes(self):
        path=self.home/'large.jsonl'
        meta={'type':'session_meta','payload':{'id':'large-session'}}
        count={'timestamp':'2026-10-24T00:00:00Z','type':'event_msg','payload':{'type':'token_count',
               'info':{'total_token_usage':{'input_tokens':10,'output_tokens':2}}}}
        path.write_bytes((json.dumps(meta)+'\n').encode()+b'{"type":"response_item","text":"'+b'x'*(9*1024*1024)+b'"}\n'+(json.dumps(count)+'\n').encode())
        first,state=usage.codex_records(path,{},since=0,byte_limit=8*1024*1024)
        self.assertEqual([],first)
        self.assertGreater(state['offset'],7*1024*1024)
        self.assertTrue(state['pending'])
        second,state=usage.codex_records(path,state,since=0,byte_limit=8*1024*1024)
        self.assertEqual(1,len(second))
        self.assertFalse(state['pending'])

    def test_codex_reset_and_cache_are_not_negative_or_added_twice(self):
        self.assertEqual({'input':40,'cache_read_input_tokens':60,'output':20,'total':120},
                         usage.token_details(100,20,60,inclusive=True))
        with self.assertRaises(ValueError):usage.token_details(10,20,60,inclusive=True)
        with self.assertRaises(ValueError):usage.token_details(-1,20)

    def test_codex_forked_history_is_a_baseline_not_new_usage(self):
        path=self.home/'fork.jsonl'
        rows=[{'type':'session_meta','payload':{'id':'fork','timestamp':'2026-10-24T00:00:00Z'}},
              {'timestamp':'2026-10-23T23:59:00Z','type':'event_msg','payload':{'type':'token_count','info':{
                  'total_token_usage':{'input_tokens':100,'output_tokens':20}}}},
              {'timestamp':'2026-10-24T00:00:01Z','type':'event_msg','payload':{'type':'token_count','info':{
                  'total_token_usage':{'input_tokens':110,'output_tokens':22}}}}]
        path.write_text(''.join(json.dumps(r)+'\n' for r in rows))
        spans,_=usage.codex_records(path,{},since=0)
        self.assertEqual(1,len(spans))
        self.assertEqual(12,json.loads(usage.attributes(spans[0])['langfuse.observation.usage_details'])['total'])

    def test_opencode_reads_final_steps_and_separates_reasoning(self):
        path=self.home/'opencode.db'
        with closing(sqlite3.connect(path)) as db, db:
            db.executescript('CREATE TABLE session(id TEXT,directory TEXT,time_updated INTEGER);'
                'CREATE TABLE message(id TEXT,session_id TEXT,data TEXT);'
                'CREATE TABLE part(id TEXT,message_id TEXT,session_id TEXT,time_created INTEGER,data TEXT);')
            db.execute('INSERT INTO session VALUES (?,?,?)',('s','/projects/two',2000))
            db.execute('INSERT INTO message VALUES (?,?,?)',('m','s',json.dumps({'role':'assistant','modelID':'deepseek','providerID':'opencode-go','text':'PRIVATE'})))
            db.execute('INSERT INTO part VALUES (?,?,?,?,?)',('p','m','s',1000,json.dumps({'type':'step-finish','tokens':{
                'input':10,'output':20,'reasoning':5,'cache':{'read':30,'write':2},'total':67},'cost':0})))
        before=path.read_bytes()
        spans, state, bounded=usage.opencode_records(path,{},since=0)
        self.assertFalse(bounded)
        self.assertEqual(1,len(spans));self.assertEqual(before,path.read_bytes())
        attrs=usage.attributes(spans[0])
        self.assertEqual({'input':10,'output':25,'cache_read_input_tokens':30,'cache_creation_input_tokens':2,'total':67},
                         json.loads(attrs['langfuse.observation.usage_details']))
        self.assertEqual('unknown',attrs['langfuse.observation.metadata.cost_status'])
        self.assertNotIn('PRIVATE',json.dumps(spans))
        self.assertEqual([],usage.opencode_records(path,state,since=0)[0])

    def test_engine_metrics_never_become_duplicate_generation_usage(self):
        text='llamacpp:prompt_tokens_total 100\nllamacpp:prompt_tokens_cached_total 20\nllamacpp:tokens_predicted_total 5\n'
        span,counters=usage.engine_record(text,'local-qwen',1000)
        attrs=usage.attributes(span)
        self.assertEqual('span',attrs['langfuse.observation.type'])
        self.assertNotIn('langfuse.observation.usage_details',attrs)
        self.assertEqual(5,counters['output_tokens'])
        with self.assertRaises(ValueError):usage.engine_record('llamacpp:prompt_tokens_total NaN','q',1)

    def test_http_failure_and_partial_success_do_not_advance_checkpoint(self):
        state=self.home/'state';state.mkdir()
        config={'root':self.home,'codex_home':self.home/'missing','opencode_db':self.home/'missing.db',
                'state_dir':state,'llama_endpoints':{},'base_url':'https://example.invalid','public_key':'pk-lf-test','secret_key':'sk-lf-SECRET'}
        old={'codex':{},'opencode':{},'last_success':1}
        (state/'checkpoint.json').write_text(json.dumps(old))
        with patch.object(usage,'collect',return_value=([{'spanId':'a'}],{'new':True},{'codex':{'status':'observed'}})), \
             patch.object(usage,'send',side_effect=OSError('SECRET')):
            self.assertFalse(usage.run(config)['export_ok'])
        self.assertEqual(old,json.loads((state/'checkpoint.json').read_text()))
        self.assertNotIn('SECRET',(state/'summary.json').read_text())
        with patch.object(usage,'request',return_value=b'{"partialSuccess":{"rejectedSpans":"1"}}'):
            with self.assertRaises(ValueError):usage.send(config,[{'spanId':'a'}])

    def test_opencode_incomplete_part_scan_is_never_observed_as_complete(self):
        path=self.home/'opencode.db'
        with closing(sqlite3.connect(path)) as db, db:
            db.executescript('CREATE TABLE session(id TEXT,directory TEXT,time_updated INTEGER);'
                'CREATE TABLE message(id TEXT,session_id TEXT,data TEXT);'
                'CREATE TABLE part(id TEXT,message_id TEXT,session_id TEXT,time_created INTEGER,data TEXT);')
            db.execute('INSERT INTO session VALUES (?,?,?)',('s','/projects/two',2000))
            db.executemany('INSERT INTO part VALUES (?,?,?,?,?)',
                          [(str(i).zfill(5),'m','s',1000,'{"type":"text"}') for i in range(1001)])
        spans,state,bounded=usage.opencode_records(path,{},since=0)
        self.assertEqual([],spans);self.assertTrue(bounded)
        self.assertFalse(usage.opencode_records(path,state,since=0)[2])

    def test_opencode_v2_uses_completed_messages_and_late_finalization(self):
        path=self.home/'v2.db'
        with closing(sqlite3.connect(path)) as db, db:
            db.executescript('CREATE TABLE session_v2(id TEXT,directory TEXT,time_updated INTEGER,model TEXT,time_created INTEGER DEFAULT 0);'
                'CREATE TABLE session_message(id TEXT,session_id TEXT,type TEXT,seq INTEGER,time_created INTEGER,time_updated INTEGER,data TEXT);')
            db.execute('INSERT INTO session_v2(id,directory,time_updated,model) VALUES (?,?,?,?)',('s','/projects/three',3000,'{"id":"deepseek","providerID":"opencode-go"}'))
            def message(completed):return json.dumps({'model':{'id':'deepseek','providerID':'opencode-go'},
                'content':[{'text':'PRIVATE'}],'tokens':{'input':10,'output':20,'reasoning':5,'cache':{'read':30,'write':2}},
                'time':{'created':1000,**({'completed':completed} if completed else {})}})
            db.execute('INSERT INTO session_message VALUES (?,?,?,?,?,?,?)',('early','s','assistant',1,1000,1000,message(None)))
            db.execute('INSERT INTO session_message VALUES (?,?,?,?,?,?,?)',('later','s','assistant',2,2000,2000,message(2000)))
        first,state,bounded=usage.opencode_records(path,{},since=0)
        self.assertEqual(1,len(first));self.assertFalse(bounded)
        self.assertEqual(67,json.loads(usage.attributes(first[0])['langfuse.observation.usage_details'])['total'])
        self.assertNotIn('PRIVATE',json.dumps(first))
        with closing(sqlite3.connect(path)) as db, db:
            db.execute('UPDATE session_message SET data=?,time_updated=3000 WHERE id=?',(message(3000),'early'))
            compaction={'status':'completed','tokens':{'input':1,'output':2,'reasoning':0,'cache':{'read':0,'write':0}}}
            db.execute('INSERT INTO session_message VALUES (?,?,?,?,?,?,?)',('compact','s','compaction',3,3000,3001,json.dumps(compaction)))
        second,state,bounded=usage.opencode_records(path,state,since=0)
        self.assertEqual(2,len(second))
        self.assertNotEqual(first[0]['spanId'],second[0]['spanId'])
        self.assertEqual('unknown',usage.attributes(second[1])['langfuse.observation.model.name'])
        self.assertEqual([],usage.opencode_records(path,state,since=0)[0])
        with closing(sqlite3.connect(path)) as db, db:
            db.execute('INSERT INTO session_v2 VALUES (?,?,?,?,?)',('fork','/projects/three',4000,None,4000))
            db.execute('INSERT INTO session_message VALUES (?,?,?,?,?,?,?)',('copied','fork','assistant',1,1000,1000,message(1000)))
        self.assertEqual([],usage.opencode_records(path,state,since=0)[0])

    def test_native_adapter_keeps_total_and_adds_context_idempotently(self):
        native=Path.home()/'.hermes/hermes-agent/plugins/observability/langfuse/__init__.py'
        if not native.is_file():self.skipTest('Native Hermes plugin not installed')
        text=native.read_text();fixed=usage.patch_native(text)
        self.assertEqual(fixed,usage.patch_native(fixed))
        self.assertIn('usage_details["total"] = canonical.total_tokens',fixed)
        self.assertIn('_nixhomeserver_usage_context(provider, model, base_url)',fixed)
        compile(fixed,'patched-plugin','exec')
        with self.assertRaises(ValueError):usage.patch_native('Unsupported plugin')
        # Exercise the actual adapted upstream normalizer, not a second copy.
        tree=ast.parse(fixed)
        nodes=[node for node in tree.body if
               isinstance(node,ast.Assign) and any(isinstance(t,ast.Name) and t.id=='_USAGE_FIELDS' for t in node.targets)
               or isinstance(node,ast.FunctionDef) and node.name=='_canonical_usage_and_cost']
        namespace={'Any':object,'Dict':dict}
        pricing=SimpleNamespace(estimate_usage_cost=lambda *a,**k:None,
                                resolve_billing_route=lambda *a,**k:SimpleNamespace(billing_mode='subscription_included'))
        with patch.dict(sys.modules,{'agent':SimpleNamespace(),'agent.usage_pricing':pricing}):
            exec(compile(ast.Module(body=nodes,type_ignores=[]),'normalizer','exec'),namespace)
            normalized,cost=namespace['_canonical_usage_and_cost'](SimpleNamespace(input_tokens=40,output_tokens=20,
                cache_read_tokens=60,cache_write_tokens=0,reasoning_tokens=10,total_tokens=120),
                provider='openai-codex',model='gpt-6.1-sol',base_url='https://chatgpt.com')
        self.assertEqual(120,normalized['total'])
        self.assertNotIn('reasoning_tokens',normalized)
        self.assertEqual({},cost)

    def test_stale_summary_is_explicit_and_contains_no_credentials(self):
        path=self.home/'summary.json'
        path.write_text(json.dumps({'generated_at':1,'export_ok':True,'sources':{}}))
        summary=usage.read_summary(path,now=2000)
        self.assertEqual('stale',summary['status'])
        self.assertEqual('unavailable',usage.read_summary(self.home/'absent',now=2000)['status'])


unittest.main(argv=['agent-usage-tests'])
PY
