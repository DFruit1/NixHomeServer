#!/usr/bin/env bash
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
python3 -B - "$repo" <<'PY'
import sys, unittest, tempfile, json, importlib.util, subprocess, io
from types import SimpleNamespace
from unittest.mock import patch
from pathlib import Path
sys.path.insert(0,str(Path(sys.argv[1])/'scripts/hermes'))
import langfuse_mcp as mcp
server_path=Path(sys.argv[1])/'scripts/admin/provision-langfuse-mcp-server.py'
spec=importlib.util.spec_from_file_location('mcp_provision_server',server_path)
server=importlib.util.module_from_spec(spec);spec.loader.exec_module(server)
spec=importlib.util.spec_from_file_location('mcp_provision_desktop',server_path.with_name('provision-langfuse-mcp.py'))
desktop=importlib.util.module_from_spec(spec);spec.loader.exec_module(desktop)

class MCPTest(unittest.TestCase):
    def test_manifest_validator_accepts_only_project_keys_on_https_origin(self):
        source=server_path.parents[1]/'helpers/secrets-common.sh'
        good={'baseUrl':'https://private.example','publicKey':'pk-lf-'+'a'*32,'secretKey':'sk-lf-'+'b'*32}
        with tempfile.TemporaryDirectory(prefix='langfuse-mcp-validator-test-') as tmp:
            path=Path(tmp)/'fixture.json'
            cases=[(good,0),({**good,'baseUrl':'http://private.example'},1),
                   ({**good,'secretKey':'wrong'},1),({**good,'unexpected':'field'},1)]
            for value,expected in cases:
                path.write_text(json.dumps(value))
                result=subprocess.run(['bash','-c','source "$1"; validate_langfuse_project_credentials "$2"','--',str(source),str(path)])
                self.assertEqual(expected,result.returncode)

    def request(self,method,params=None):return {'jsonrpc':'2.0','id':7,'method':method,'params':params or {}}
    def test_write_and_unknown_methods_are_rejected_before_credentials_or_network(self):
        def forbidden(_):raise AssertionError('Upstream called')
        for request in (self.request('tools/call',{'name':'createScore'}),self.request('resources/read'),
                        self.request('tools/call',{'name':'queryMetrics','arguments':{}})):
            self.assertIn('error',mcp.handle(request,forbidden))
    def test_only_read_tools_are_advertised(self):
        tools=[{'name':n} for n in ('queryMetrics','createScore','getHealth','deleteModel','getMetricsSchema')]
        result=mcp.handle(self.request('tools/list'),lambda m:{'jsonrpc':'2.0','id':7,'result':{'tools':tools}})
        self.assertEqual(mcp.ALLOWED,{t['name'] for t in result['result']['tools']})
    def test_metrics_forward_with_bounded_window_rows_and_generation_filter(self):
        seen=[]
        args={'view':'observations','fromTimestamp':'2026-10-23T00:00:00Z','toTimestamp':'2026-10-24T00:00:00Z',
              'dimensions':[],'metrics':[{'measure':'inputTokens','aggregation':'sum'}],'filters':[]}
        request=self.request('tools/call',{'name':'queryMetrics','arguments':args})
        def upstream(m):seen.append(m);return {'jsonrpc':'2.0','id':7,'result':{'content':[]}}
        self.assertIn('result',mcp.handle(request,upstream))
        final=seen[0]['params']['arguments']
        self.assertEqual(1000,final['config']['row_limit'])
        self.assertIn({'column':'type','operator':'=','type':'string','value':'GENERATION'},final['filters'])
        args['toTimestamp']='2026-12-24T00:00:00Z'
        self.assertIn('error',mcp.handle(request,upstream))
        self.assertEqual(1,len(seen))
    def test_errors_do_not_echo_credentials_or_payloads(self):
        def fail(_):raise OSError('SECRET VALUE')
        response=mcp.handle(self.request('tools/list'),fail)
        self.assertIn('error',response);self.assertNotIn('SECRET',str(response))
    def test_initialize_advertises_only_implemented_capabilities(self):
        r=mcp.handle(self.request('initialize'),lambda m:{'id':7,'result':{'capabilities':{'prompts':{}},'serverInfo':{},'protocolVersion':'2025-03-26'}})
        self.assertEqual({'tools':{'listChanged':False}},r['result']['capabilities'])
        self.assertIsNone(mcp.handle({'jsonrpc':'2.0','method':'notifications/initialized'},lambda m:None))

    def test_credential_decryption_is_in_memory_and_cached_without_shell(self):
        with tempfile.TemporaryDirectory(prefix='langfuse-mcp-test-') as tmp:
            path=Path(tmp)/'key.age';path.write_text('-----BEGIN AGE ENCRYPTED FILE-----\nfixture')
            values={'baseUrl':'https://private.example','publicKey':'pk-lf-'+'a'*32,'secretKey':'sk-lf-'+'b'*32}
            client=mcp.Client(path)
            with patch.object(mcp.subprocess,'run',return_value=SimpleNamespace(stdout=json.dumps(values).encode())) as run:
                self.assertEqual(values,client.credentials());self.assertEqual(values,client.credentials())
            self.assertEqual(1,run.call_count)
            self.assertNotIn('shell',run.call_args.kwargs)
            self.assertEqual(path.read_bytes(),run.call_args.kwargs['input'])
            self.assertNotIn('secretKey',str(run.call_args.args))

    def test_server_standard_workflow_is_realized_before_plaintext_staging(self):
        with tempfile.TemporaryDirectory(prefix='langfuse-mcp-encryption-test-') as tmp:
            repo=Path(tmp);(repo/'secrets').mkdir()
            (repo/'secrets/known.age').write_text('old ciphertext')
            target=repo/'secrets/unencrypted'/server.NAME
            cipher=repo/'secrets'/f'{server.NAME}.age'
            manifest=json.dumps({'generatedSecrets':{'known':{'bytes':32}},'externalSecrets':{server.NAME:{}}})
            def output(command,**kwargs):
                self.assertFalse(target.exists())
                return '/nix/store/fixture/bin/generate-secrets\n' if '--raw' in command else manifest
            def execute(command,**kwargs):
                self.assertNotIn('--fresh',command)
                if command[0]=='nix':self.assertFalse(target.exists())
                else:
                    self.assertTrue(target.exists())
                    self.assertEqual(manifest,kwargs['env']['NIXHOMESERVER_MANIFEST_JSON'])
                    self.assertIn('--replace-external',command)
                    cipher.write_text('-----BEGIN AGE ENCRYPTED FILE-----\nfixture')
            with patch.object(server.subprocess,'check_output',side_effect=output),patch.object(server.subprocess,'run',side_effect=execute):
                result=server.encrypt(repo,{'fixture':'value'})
            self.assertTrue(result.startswith('-----BEGIN AGE'))
            self.assertFalse(target.exists())
            self.assertEqual('old ciphertext',(repo/'secrets/known.age').read_text())

    def test_server_encryption_failure_cleans_only_its_staging(self):
        with tempfile.TemporaryDirectory(prefix='langfuse-mcp-encryption-test-') as tmp:
            repo=Path(tmp);(repo/'secrets').mkdir()
            (repo/'secrets/known.age').write_text('old ciphertext')
            manifest=json.dumps({'generatedSecrets':{'known':{}},'externalSecrets':{server.NAME:{}}})
            def output(command,**kwargs):return '/fixture/program' if '--raw' in command else manifest
            def fail(command,**kwargs):
                if command[0]!='nix':raise OSError('fixture failure')
            with patch.object(server.subprocess,'check_output',side_effect=output),patch.object(server.subprocess,'run',side_effect=fail):
                with self.assertRaises(OSError):server.encrypt(repo,{'fixture':'value'})
            self.assertFalse((repo/'secrets/unencrypted'/server.NAME).exists())
            self.assertEqual('old ciphertext',(repo/'secrets/known.age').read_text())

    def test_encrypted_server_receipt_replays_without_owner_login_or_second_key(self):
        class FakeOwner:
            origin='https://private.example'
            calls=[]
            def rpc(self,name,payload,**kwargs):
                self.calls.append((name,payload))
                return [] if name.endswith('byProjectId') else {'id':'created-id','publicKey':'fixture-public','secretKey':'fixture-secret'}
        owner=FakeOwner()
        with tempfile.TemporaryDirectory(prefix='langfuse-mcp-replay-test-') as tmp:
            root=Path(tmp);directory=root/'durable'
            with patch.object(server,'encrypt',return_value='ARMORED CIPHERTEXT'), \
                 patch.object(server.urllib.request,'urlopen',return_value=io.BytesIO(b'{"data":[{"id":"hermes"}]}')):
                first=server.provision(root,directory,owner_factory=lambda:owner)
            def forbidden():raise AssertionError('Replay must not authenticate or mint')
            replay=server.provision(root,directory,recover=True,owner_factory=forbidden)
            self.assertEqual(first,replay)
            self.assertEqual(1,sum(name.endswith('create') for name,_ in owner.calls))
            self.assertNotIn('fixture-secret',(directory/'receipt.json').read_text())

    def test_mint_before_receipt_crash_finds_only_its_exact_persisted_intent(self):
        calls=[]
        class FakeOwner:
            origin='https://private.example'
            def rpc(self,name,payload,**kwargs):
                calls.append((name,payload))
                if name.endswith('byProjectId'):return [{'id':'ours','note':'unique-intent'},{'id':'other','note':'other'}]
                return {'id':'replacement','publicKey':'fixture-public','secretKey':'fixture-secret'}
        with tempfile.TemporaryDirectory(prefix='langfuse-mcp-recovery-test-') as tmp:
            root=Path(tmp);directory=root/'durable';directory.mkdir()
            server.durable_json(directory/'receipt.json',{'note':'unique-intent','attempts':1})
            with patch.object(server,'encrypt',return_value='ARMORED CIPHERTEXT'), \
                 patch.object(server.urllib.request,'urlopen',return_value=io.BytesIO(b'{"data":[{"id":"hermes"}]}')):
                receipt=server.provision(root,directory,owner_factory=FakeOwner)
            self.assertEqual(2,receipt['attempts'])
            self.assertEqual([('projectApiKeys.delete',{'projectId':'hermes','id':'ours'})],
                             [(n,p) for n,p in calls if n.endswith('delete')])

    def test_exhausted_budget_still_cleans_owned_unused_key_but_never_mints_third(self):
        calls=[]
        class FakeOwner:
            def rpc(self,name,payload,**kwargs):
                calls.append((name,payload))
                if name.endswith('byProjectId'):return [{'id':'ours','note':'unique-intent'}]
        with tempfile.TemporaryDirectory(prefix='langfuse-mcp-budget-test-') as tmp:
            root=Path(tmp);directory=root/'durable';directory.mkdir()
            server.durable_json(directory/'receipt.json',{'note':'unique-intent','attempts':2})
            with self.assertRaises(ValueError):server.provision(root,directory,owner_factory=FakeOwner)
        self.assertTrue(any(n.endswith('delete') for n,p in calls))
        self.assertFalse(any(n.endswith('create') for n,p in calls))

    def test_conflicting_desktop_target_is_rejected_before_remote_mint(self):
        with tempfile.TemporaryDirectory(prefix='langfuse-mcp-desktop-test-') as tmp:
            root=Path(tmp);(root/'secrets').mkdir();home=root/'home'
            runtime=home/'.hermes/credentials/langfuse-mcp.age';runtime.parent.mkdir(parents=True)
            runtime.write_text('existing');(root/'secrets/langfuseMcpClientEnv.age').write_text('different')
            with patch.object(sys,'argv',['provision','--repo',str(root),'--apply']), \
                 patch.object(desktop.Path,'home',return_value=home),patch.object(desktop.subprocess,'run') as run:
                with self.assertRaises(ValueError):desktop.main()
                run.assert_not_called()

    def test_interrupted_desktop_publish_leaves_no_partial_final_and_replay_completes(self):
        with tempfile.TemporaryDirectory(prefix='langfuse-mcp-handoff-test-') as tmp:
            repo=Path(tmp);target=repo/'secrets/key.age';runtime=repo/'home/credentials/key-runtime.age'
            desktop.preflight(repo,(target,runtime))
            targets=((target,0o644),(runtime,0o600));ciphertext='ARMORED CIPHERTEXT'
            with patch.object(desktop.os,'fsync',side_effect=OSError('simulated interruption')):
                with self.assertRaises(OSError):desktop.publish_ciphertext(repo,targets,ciphertext)
            self.assertFalse(target.exists());self.assertFalse(runtime.exists())
            desktop.publish_ciphertext(repo,targets,ciphertext)
            self.assertEqual(ciphertext,target.read_text());self.assertEqual(ciphertext,runtime.read_text())
            self.assertEqual([],list((repo/'.tmp').iterdir()))

unittest.main(argv=['langfuse-mcp'])
PY
