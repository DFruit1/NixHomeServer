#!/usr/bin/env bash
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
python3 -B - "$repo" <<'PY'
from contextlib import closing
import importlib.util
import io
import json
import os
from pathlib import Path
import sqlite3
import sys
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

SOURCE=Path(sys.argv[1])/'scripts/hermes'
sys.path.insert(0,str(SOURCE))
import worker_origin as origin
from worker_origin_adapter import adapt, adapt_local
spec=importlib.util.spec_from_file_location('installer',SOURCE/'install-worker-origin.py')
installer=importlib.util.module_from_spec(spec);spec.loader.exec_module(installer)


class WorkerOriginTest(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix='hermes-worker-origin-')
        self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name)
        self.board=self.root/'kanban/boards/synthetic/kanban.db'
        self.board.parent.mkdir(parents=True)
        self.workspace=self.root/'workspace';self.workspace.mkdir()
        self.fingerprint=origin.process_fingerprint()
        self.env={'HERMES_KANBAN_TASK':'t_fixture','HERMES_KANBAN_RUN_ID':'42',
                  'HERMES_KANBAN_BOARD':'synthetic','HERMES_KANBAN_DB':str(self.board),
                  'HERMES_KANBAN_WORKSPACE':str(self.workspace),
                  'HERMES_PROFILE':'standard-implementer','HERMES_KANBAN_CLAIM_LOCK':'fixture-lock'}
        with closing(sqlite3.connect(self.board)) as db:
            db.executescript('''CREATE TABLE tasks(id TEXT,status TEXT,assignee TEXT,
                workspace_path TEXT,current_run_id INTEGER,worker_pid INTEGER,
                worker_started_at TEXT,claim_lock TEXT,claim_expires INTEGER);
                CREATE TABLE task_runs(id INTEGER,task_id TEXT,status TEXT,outcome TEXT,
                profile TEXT,worker_pid INTEGER,worker_started_at TEXT,claim_lock TEXT,
                claim_expires INTEGER);''')
            db.execute('INSERT INTO tasks VALUES (?,?,?,?,?,?,?,?,?)',
                       ('t_fixture','running','standard-implementer',str(self.workspace),42,
                        os.getpid(),self.fingerprint,'fixture-lock',4_000_000_000))
            db.execute('INSERT INTO task_runs VALUES (?,?,?,?,?,?,?,?,?)',
                       (42,'t_fixture','running',None,'standard-implementer',os.getpid(),
                        self.fingerprint,'fixture-lock',4_000_000_000))
            db.commit()
        self.agent=SimpleNamespace(platform='cli',side_agent=False)

    def bind(self,prior=None,owned=True,agent=None):
        with patch.dict(os.environ,self.env), patch.object(origin,'dispatcher_owned',return_value=owned):
            return json.loads(origin.session_origin(agent or self.agent,prior))

    def test_native_origin_binds_actual_run_process_and_preserves_routing(self):
        result=self.bind('{"chat_id":"fixture-chat","profile":"standard-implementer"}')
        self.assertEqual('fixture-chat',result['chat_id'])
        grant=result['native_worker']
        self.assertEqual(('t_fixture',42,os.getpid(),self.fingerprint),
                         (grant['task_id'],grant['run_id'],grant['pid'],grant['fingerprint']))
        self.assertEqual(str(self.board),grant['db'])
        self.assertEqual('standard-implementer',grant['profile'])
        self.assertEqual(str(self.workspace),grant['workspace'])

    def test_delegated_and_side_agents_get_explicit_denial_not_inherited_grant(self):
        granted=json.dumps(self.bind())
        for owned,agent in ((False,self.agent),(True,SimpleNamespace(platform='subagent',side_agent=True))):
            with self.subTest(owned=owned),patch.dict(os.environ,self.env):
                denied=self.bind(granted,owned=owned,agent=agent)
                self.assertIn('native_worker',denied)
                self.assertIsNone(denied['native_worker'])

    def test_compression_can_retain_same_binding_but_other_run_cannot_mint_it(self):
        native=self.bind()
        self.assertEqual(native['native_worker'],self.bind(json.dumps(native))['native_worker'])
        self.env['HERMES_KANBAN_RUN_ID']='43'
        self.assertIsNone(self.bind(json.dumps(native))['native_worker'])

    def test_missing_released_expired_wrong_process_and_claim_fail_closed(self):
        changes=[("UPDATE tasks SET current_run_id=43",()),
                 ("UPDATE task_runs SET status='released'",()),
                 ("UPDATE tasks SET claim_expires=0",()),
                 ("UPDATE task_runs SET worker_pid=1",()),
                 ("UPDATE tasks SET worker_started_at='other|0'",()),
                 ("UPDATE task_runs SET claim_lock='other'",()),
                 ("UPDATE task_runs SET profile='feature-reviewer'",())]
        for sql,params in changes:
            with self.subTest(sql=sql),closing(sqlite3.connect(self.board)) as db:
                db.execute(sql,params);db.commit()
                self.assertIsNone(self.bind()['native_worker'])
                db.execute("UPDATE tasks SET current_run_id=42,claim_expires=4000000000,worker_started_at=?",(self.fingerprint,))
                db.execute("UPDATE task_runs SET status='running',worker_pid=?,claim_lock='fixture-lock',profile='standard-implementer'",(os.getpid(),))
                db.commit()

    def test_expected_launch_metadata_failures_do_not_break_started_terminal(self):
        for failure in (sqlite3.OperationalError('fixture'), OSError('fixture'),
                        ValueError('fixture'), TypeError('fixture'), IndexError('fixture')):
            with self.subTest(failure=type(failure).__name__),patch.object(origin,'_record_launch',side_effect=failure):
                self.assertIsNone(origin.record_launch(SimpleNamespace(pid=1)))

    def test_nonworker_and_bad_prior_never_inherit_user_supplied_native_authority(self):
        self.env['HERMES_KANBAN_RUN_ID']='not-a-run'
        self.assertIsNone(self.bind('{"native_worker":{"task_id":"forged"}}')['native_worker'])
        self.assertIsNone(self.bind('not JSON')['native_worker'])


class AdapterTest(unittest.TestCase):
    def fixture(self):
        return ('class Agent:\n    def start(self):\n'
                '        try:\n            self._session_db.create_session(\n'
                '                origin_json=_gateway_origin_json(self), parent_session_id=self._parent_session_id,\n'
                '            )\n        except Exception:\n            pass\n')

    def test_adapter_preserves_source_and_is_idempotent(self):
        changed=adapt(self.fixture())
        self.assertIn('nixhomeserver_worker_origin.session_origin(self, _gateway_origin_json(self))',changed)
        self.assertEqual(changed,adapt(changed))

    def test_local_launch_seam_executes_in_fresh_runtime_import(self):
        from types import ModuleType
        called=[]
        helper=ModuleType('hermes_cli.nixhomeserver_worker_origin')
        helper.record_launch=lambda proc:called.append(proc)
        package=ModuleType('hermes_cli');package.nixhomeserver_worker_origin=helper
        source=('def spawn(proc):\n'
                '        if not _IS_WINDOWS:\n'
                '            with contextlib.suppress(ProcessLookupError):\n'
                '                pass\n')
        adapted=adapt_local(source)
        self.assertEqual(adapted,adapt_local(adapted))
        import contextlib
        scope={'_IS_WINDOWS':False,'contextlib':contextlib}
        with patch.dict(sys.modules,{'hermes_cli':package}):
            exec(compile(adapted,'native-local.py','exec'),scope)
            process=object();scope['spawn'](process)
        self.assertEqual([process],called)
        for changed in ('pass\n',source+source):
            with self.assertRaises(ValueError):adapt_local(changed)

    def test_missing_or_duplicate_seam_refuses(self):
        for source in ('pass\n',self.fixture()+self.fixture()):
            with self.assertRaises(ValueError):adapt(source)


class InstallerTest(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix='hermes-origin-installer-')
        self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name)
        self.native=self.root/'hermes-agent/run_agent.py'
        self.native.parent.mkdir()
        self.native.write_text('# unrelated user change\n'+AdapterTest().fixture())
        self.native.chmod(0o640)
        self.before=self.native.read_bytes()
        self.local=self.root/'hermes-agent/tools/environments/local.py'
        self.local.parent.mkdir(parents=True)
        self.local.write_text('def spawn():\n        if not _IS_WINDOWS:\n            with contextlib.suppress(ProcessLookupError):\n                pass\n')
        self.helper=self.root/'hermes-agent/hermes_cli/nixhomeserver_worker_origin.py'

    def test_check_is_read_only_and_apply_is_backed_up_atomic_and_idempotent(self):
        self.assertEqual(1,installer.install(self.root,check=True))
        self.assertEqual(self.before,self.native.read_bytes())
        self.assertFalse(self.helper.exists())
        self.assertFalse((self.root/'backups').exists())
        self.assertEqual(0,installer.install(self.root))
        self.assertEqual(0o640,self.native.stat().st_mode & 0o777)
        self.assertIn('# unrelated user change',self.native.read_text())
        backups=[p.read_bytes() for p in (self.root/'backups').rglob('*') if p.is_file()]
        self.assertIn(self.before,backups)
        self.assertEqual((SOURCE/'worker_origin.py').read_bytes(),self.helper.read_bytes())
        self.assertEqual(0,installer.install(self.root,check=True))
        self.assertEqual(0,installer.install(self.root))

    def test_native_seam_drift_refuses_before_installing_helper(self):
        self.native.write_text('pass\n')
        with self.assertRaises(ValueError):installer.install(self.root)
        self.assertFalse(self.helper.exists())
        self.assertEqual('pass\n',self.native.read_text())

    def test_helper_symlink_is_not_followed(self):
        self.helper.parent.mkdir()
        target=self.root/'other';target.write_text('preserve')
        self.helper.symlink_to(target)
        with self.assertRaises(ValueError):installer.install(self.root)
        self.assertEqual('preserve',target.read_text())
        self.assertEqual(self.before,self.native.read_bytes())

    def test_concurrent_native_writer_is_preserved(self):
        original=installer.atomic_write
        def writer(path,text):
            original(path,text)
            if path==self.helper:self.native.write_text('# concurrent change\n'+self.native.read_text())
        with patch.object(installer,'atomic_write',side_effect=writer),self.assertRaises(ValueError):
            installer.install(self.root)
        self.assertEqual('# concurrent change\n'+self.before.decode(),self.native.read_text())


_NATIVE_PARENT = r"""

import json,os,sqlite3,subprocess,sys,time
from pathlib import Path
root,module,scenario,child=sys.argv[1:]
root=Path(root);dbpath=root/'hermes/kanban/boards/synthetic/kanban.db'
dbpath.parent.mkdir(parents=True);(root/'workspace').mkdir()
profile='standard-implementer';task='t_synthetic_producer';run=42
pid=os.getpid();stat=Path(f'/proc/{pid}/stat').read_text().rsplit(')',1)[1].split()
boot=Path('/proc/sys/kernel/random/boot_id').read_text().strip()
pid1=Path('/proc/1/stat').read_text().rsplit(')',1)[1].split()[19]
fingerprint=f'{boot}:{pid1}|{stat[19]}'
con=sqlite3.connect(dbpath)
con.executescript('''CREATE TABLE tasks(id TEXT,status TEXT,assignee TEXT,workspace_path TEXT,
 current_run_id INTEGER,worker_pid INTEGER,worker_started_at TEXT,claim_lock TEXT,claim_expires INTEGER);
 CREATE TABLE task_runs(id INTEGER,task_id TEXT,status TEXT,outcome TEXT,profile TEXT,
 worker_pid INTEGER,worker_started_at TEXT,claim_lock TEXT,started_at INTEGER,claim_expires INTEGER);''')
con.execute('INSERT INTO tasks VALUES (?,?,?,?,?,?,?,?,?)',
 (task,'running',profile,str(root/'workspace'),run,pid,fingerprint,'fixture-lock',int(time.time())+600))
con.execute('INSERT INTO task_runs VALUES (?,?,?,?,?,?,?,?,?,?)',
 (run,task,'running',None,profile,pid,fingerprint,'fixture-lock',int(time.time())-10,int(time.time())+600))
if scenario=='expired_lease':con.execute('UPDATE tasks SET claim_expires=0')
if scenario=='released':con.execute("UPDATE task_runs SET status='released'")
if scenario=='reused_pid':con.execute("UPDATE tasks SET worker_started_at='wrong-epoch|0'")
if scenario=='wrong_run':con.execute('UPDATE tasks SET current_run_id=43')
if scenario=='unrelated':con.execute('UPDATE tasks SET worker_pid=1');con.execute('UPDATE task_runs SET worker_pid=1')
con.commit();con.close()
state=root/'hermes/profiles'/profile/'state.db';state.parent.mkdir(parents=True)
con=sqlite3.connect(state)
con.execute('CREATE TABLE sessions(id TEXT,source TEXT,profile_name TEXT,started_at REAL,ended_at REAL,origin_json TEXT)')
binding={'schema_version':1,'task_id':task,'run_id':run,'board':'synthetic','db':str(dbpath),
         'profile':profile,'pid':pid,'fingerprint':fingerprint,'workspace':str(root/'workspace')}
con.execute('INSERT INTO sessions VALUES (?,?,?,?,?,?)',
 ('synthetic-session','subagent' if scenario=='delegated' else 'kanban',profile,time.time()-5,None,
  json.dumps({'native_worker':None if scenario=='delegated_mislabelled_kanban' else binding})))
con.execute('INSERT INTO sessions VALUES (?,?,?,?,?,?)',
 ('borrowed-session','kanban',profile,time.time()-4,None,json.dumps({'native_worker':{**binding,'task_id':task if scenario=='borrowed_parent_session' else 't_unrelated'}})))
if scenario=='ended_session':con.execute('UPDATE sessions SET ended_at=?',(time.time(),))
con.commit();con.close()
# This is a non-agent synthetic child with fresh fixture bindings. No parent
# agent environment is modified, no real board or credential is inspected.
env=dict(os.environ)
for key in ('HERMES_KANBAN_TASK','HERMES_KANBAN_RUN_ID','HERMES_KANBAN_CLAIM_LOCK'):
 env.pop(key,None)
env.update(HERMES_KANBAN_DB=str(dbpath),HERMES_KANBAN_BOARD='synthetic',
 HERMES_KANBAN_WORKSPACE=str(root/'workspace'),HERMES_PROFILE=profile,
 HERMES_SESSION_ID='synthetic-session',HERMES_DELEGATED_CHILD_CONTEXT=str(root/'hermes'))
if scenario=='conflicting_location':env['HERMES_KANBAN_BOARD']='other'
if scenario=='forged_pins':env.update(HERMES_KANBAN_TASK=task,HERMES_KANBAN_RUN_ID=str(run))
if scenario=='missing_session':env.pop('HERMES_SESSION_ID')
if scenario in {'borrowed_matching_profile','borrowed_parent_session','forged_parent_label'}:env['HERMES_SESSION_ID']='borrowed-session'
import importlib.util
spec=importlib.util.spec_from_file_location('origin',module)
origin=importlib.util.module_from_spec(spec);spec.loader.exec_module(origin)
# Simulate the maintained runtime launch seam with real subprocess identity;
# context-local ownership is chosen by this synthetic native parent, not child env.
origin.dispatcher_owned=lambda:scenario not in {'borrowed_parent_session','delegated','delegated_mislabelled_kanban','denial_inheritance'}
import types
context=types.ModuleType('gateway.session_context')
context.get_session_env=lambda name,default='':'synthetic-session'
sys.modules['gateway.session_context']=context
os.environ['HERMES_KANBAN_CLAIM_LOCK']='fixture-lock'
child='import sys;sys.stdin.readline();\n'+child
proc=subprocess.Popen([sys.executable,'-B','-c',child,module,str(root),task,scenario],env=env,
 stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
released=False
if scenario=='publication_race':
 real=origin.os.link
 def publish(*a,**k):
  real(*a,**k)
  proc.stdin.write('go\n');proc.stdin.flush();proc.stdin.close();proc.stdin=None
  time.sleep(.1)
 origin.os.link=publish
 origin.record_launch(proc);origin.os.link=real;released=True
elif scenario=='metadata_sqlite_failure':
 real=origin.sqlite3.connect
 origin.sqlite3.connect=lambda *a,**k:(_ for _ in ()).throw(sqlite3.OperationalError('fixture'))
 origin.record_launch(proc);origin.sqlite3.connect=real
elif scenario=='metadata_write_failure':
 real=origin.tempfile.mkstemp
 origin.tempfile.mkstemp=lambda *a,**k:(_ for _ in ()).throw(OSError('fixture'))
 origin.record_launch(proc);origin.tempfile.mkstemp=real
elif scenario!='missing_launch':origin.record_launch(proc)
if scenario.startswith('receipt_'):
 receipts=list((root/'hermes/runtime/worker-origin').rglob('*.json'))
 target=receipts[0]
 if scenario=='receipt_symlink':
  saved=target.read_text();target.unlink();other=target.parent/'other';other.write_text(saved);target.symlink_to(other)
 elif scenario=='receipt_mode':target.chmod(0o644)
 else:
  data=json.loads(target.read_text())
  if scenario=='receipt_wrong_pid':data['pid']=1
  if scenario=='receipt_wrong_start':data['start_ticks']='0'
  if scenario=='receipt_wrong_session':data['session_id']='borrowed-session'
  if scenario=='receipt_string_allowed':data['allowed']='true'
  target.write_text(json.dumps(data))
out,err=proc.communicate(None if released else 'go\n',timeout=10)
if proc.returncode:raise RuntimeError(err)
print(out.strip())
"""
_NATIVE_CHILD = r"""
import importlib.util,json,os,sys
from pathlib import Path
path,root,task,scenario=sys.argv[1:]
if scenario=='denial_inheritance':
 import subprocess
 code = "import importlib.util,json,sys;from pathlib import Path;spec=importlib.util.spec_from_file_location('o',sys.argv[1]);m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)\n"
 code += "try:m.authenticated_current_origin(Path(sys.argv[2])/'hermes');print(json.dumps({'accepted':True}))\n"
 code += "except ValueError:print(json.dumps({'accepted':False}))"
 result=subprocess.run([sys.executable,'-B','-c',code,path,root],capture_output=True,text=True,check=True)
 print(result.stdout.strip());raise SystemExit
spec=importlib.util.spec_from_file_location('subject',path)
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
try:
 result=m.authenticated_current_origin(Path(root)/'hermes',
     expected_profile='head-coordinator' if scenario=='wrong_expected_scope' else 'standard-implementer',
     expected_task=task,expected_board='synthetic',expected_workspace=Path(root)/'workspace')
 print(json.dumps({'accepted':True,'task':result['task_id'],'run':str(result['run_id'])}))
except ValueError as exc:
 print(json.dumps({'accepted':False,'reason':str(exc)}))
"""


class AuthenticatedOriginTest(unittest.TestCase):
    def probe(self,scenario):
        with tempfile.TemporaryDirectory(prefix='hermes-origin-process-') as temp:
            env=dict(os.environ)
            env.update(HERMES_KANBAN_TASK='t_synthetic_producer',HERMES_KANBAN_RUN_ID='42',
                       HERMES_KANBAN_BOARD='synthetic',
                       HERMES_KANBAN_DB=str(Path(temp)/'hermes/kanban/boards/synthetic/kanban.db'),
                       HERMES_KANBAN_WORKSPACE=str(Path(temp)/'workspace'),
                       HERMES_PROFILE='standard-implementer')
            result=subprocess.run([sys.executable,'-B','-c',_NATIVE_PARENT,temp,
                str(SOURCE/'worker_origin.py'),scenario,_NATIVE_CHILD],env=env,
                capture_output=True,text=True,timeout=15,check=True)
            return json.loads(result.stdout)

    def test_scrubbed_tool_child_is_bound_to_genuine_native_process_run_and_session(self):
        self.assertTrue(self.probe('good')['accepted'])
        self.assertTrue(self.probe('publication_race')['accepted'])

    def test_borrowed_session_forged_identity_and_lost_claim_never_grant_authority(self):
        for scenario in ('expired_lease','released','reused_pid','wrong_run','unrelated',
                         'delegated','ended_session','conflicting_location','forged_pins',
                         'missing_session','borrowed_matching_profile','borrowed_parent_session','missing_launch','denial_inheritance','forged_parent_label',
                         'receipt_symlink','receipt_mode','receipt_wrong_pid','receipt_wrong_start',
                         'receipt_wrong_session','receipt_string_allowed','metadata_sqlite_failure','metadata_write_failure','delegated_mislabelled_kanban',
                         'wrong_expected_scope'):
            with self.subTest(scenario=scenario):self.assertFalse(self.probe(scenario)['accepted'])

unittest.main(argv=[sys.argv[0]],verbosity=2)
PY
