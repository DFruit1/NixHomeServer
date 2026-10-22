#!/usr/bin/env python3
"""Exercise adapted native cron/dispatch seams with inert agents and fixture state."""
import argparse
import ast
import json
import os
from pathlib import Path
import sys
import threading
import time
from types import SimpleNamespace

parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--hermes-repo',type=Path,required=True);parser.add_argument('--scratch',type=Path,required=True)
args=parser.parse_args()
root=args.scratch/'home';home=root/'profiles/head-coordinator';home.mkdir(parents=True,exist_ok=True)
os.environ.update(HERMES_HOME=str(home),HERMES_ROOT=str(root),HERMES_PROFILE='head-coordinator')
sys.path.insert(0,str(args.hermes_repo))
import hermes_bootstrap  # noqa: E402,F401
source=Path(__file__).resolve().parents[1]/'hermes';sys.path.insert(0,str(source))
import cron_policy as policy  # noqa: E402
from cron_runtime_adapter import adapt  # noqa: E402
import cron  # noqa: E402
import cron.scheduler as scheduler  # noqa: E402
import agent.tool_executor as executor  # noqa: E402
sys.modules['cron.nixhomeserver_cron_policy']=policy;cron.nixhomeserver_cron_policy=policy
(root/'scripts').mkdir(exist_ok=True)
job={'id':'abc123','name':'inert fixture','monitor_script':'probe.py','monitor_state':{'last_output_hash':'fixture'}}
(root/'scripts/hermes-cron-policy.json').write_text(json.dumps({'jobs':{'abc123':{
    'profile':'head-coordinator','turns':4,'tools':2,'seconds':30,'kind':'monitor'}}}))

def load_functions(name,names,namespace):
    tree=ast.parse(adapt(name,(args.hermes_repo/name).read_text()))
    subset=ast.Module(body=[node for node in tree.body if isinstance(node,(ast.FunctionDef,ast.AsyncFunctionDef)) and node.name in names],type_ignores=[])
    exec(compile(subset,name,'exec'),namespace)

namespace=dict(vars(scheduler))
namespace['_resolve_cron_enabled_toolsets']=lambda *a:[]
namespace['_resolve_cron_disabled_toolsets']=lambda *a:[]
load_functions('cron/scheduler.py',{'run_job','_construct_cron_agent','_run_agent_with_watchdog'},namespace)
tools=dict(vars(executor));load_functions('agent/tool_executor.py',{'_pre_tool_block'},tools)
setup=SimpleNamespace(runtime={'provider':'fixture'},model='fixture',prefill_messages=None,max_iterations=120,
    reasoning_config=None,fallback_model=None,credential_pool=None)
constructed=[]
def factory(**kwargs):
    assert kwargs['max_iterations']==4 and kwargs['run_budget_seconds']==30
    agent=SimpleNamespace(interrupt=lambda _:None);constructed.append(agent);return agent

def original(forwarded,**kwargs):
    agent=namespace['_construct_cron_agent'](factory,forwarded,{},setup,workdir=None,session_id='fixture',session_db=None)
    for identity in ('one','two'):
        ref=SimpleNamespace(name='read_file',args={},task_id='fixture',call_id=identity,trace=[])
        assert tools['_pre_tool_block'](agent,ref)[0] is None
    ref=SimpleNamespace(name='read_file',args={},task_id='fixture',call_id='three',trace=[])
    assert 'budget exhausted' in tools['_pre_tool_block'](agent,ref)[0]
    return True,'fixture output','Partial verified result',None
namespace['_nixhomeserver_run_job']=original
policy.current_job=lambda _:job
namespace['run_job'](job)
state=json.loads(policy.state_path(job).read_text())
assert state['budget_exhausted'] and state['pending'] and state['last_tools']==2
print('PASS native wrapper, constructor limits and pre-tool admission; exhausted snapshots remain pending')

stop=threading.Event()
agent=policy.bind(SimpleNamespace(interrupt=lambda _:stop.set(),run_conversation=lambda *a,**k:(stop.wait(5) or {})),job)
agent._nix_cron_budget['deadline']=time.monotonic()-1
try:
    namespace['_run_agent_with_watchdog'](agent,'fixture',job,job['id'],job['name'],'fixture',None)
except TimeoutError:
    assert stop.is_set()
else:
    raise AssertionError('Native watchdog did not enforce the wall deadline')
print('PASS native watchdog deadline with cooperative cancellation; no model, tool effect or delivery invoked')
