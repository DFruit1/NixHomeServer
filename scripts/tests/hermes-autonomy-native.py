#!/usr/bin/env python3
"""Verify native cross-board reads and fallback verdicts using only fixture state."""
import argparse
import ast
import importlib.util
import json
import os
from pathlib import Path
import sys
from unittest.mock import patch

parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--hermes-repo',type=Path,required=True)
parser.add_argument('--scratch',type=Path,required=True)
args=parser.parse_args()
sys.path.insert(0,str(args.hermes_repo))
# Activate the already-installed dependencies before binding synthetic state;
# this test never provisions a second managed runtime or copies credentials.
os.environ['HERMES_DISABLE_LAZY_INSTALLS']='1'
import hermes_bootstrap
root=args.scratch/'home';home=root/'profiles/head-coordinator';home.mkdir(parents=True)
os.environ.update(HERMES_HOME=str(home),HERMES_ROOT=str(root),HERMES_KANBAN_HOME=str(root),
                  HERMES_PROFILE='head-coordinator')
from hermes_cli import kanban_db as kb
from hermes_cli.kanban_db_connect import connect
import tools.kanban_tools as native
source=Path(__file__).resolve().parents[1]/'hermes';sys.path.insert(0,str(source))
import autonomy_runtime
from autonomy_runtime_adapter import adapt, EDITS
sys.modules['hermes_cli.nixhomeserver_autonomy']=autonomy_runtime

ids={}
for board in ('alpha','beta'):
    with connect(board=board) as db:
        ids[board]=kb.create_task(db,title='Fixture '+board,assignee='head-coordinator',
                                  workspace_kind='dir',workspace_path=str(args.scratch))
pin=str(root/'kanban/boards/alpha/kanban.db')
os.environ.update(HERMES_KANBAN_DB=pin,HERMES_KANBAN_TASK=ids['alpha'],HERMES_KANBAN_BOARD='alpha')
# Reproduce the old behavior before loading the adapted function.
show_source=(args.hermes_repo/'tools/kanban_tools.py').read_text()
for old,new in EDITS['tools/kanban_tools.py']:
    show_source=show_source.replace(new,old)
def load_function(text,name,namespace):
    tree=ast.parse(text)
    function=next(n for n in tree.body if isinstance(n,ast.FunctionDef) and n.name==name)
    exec(compile(ast.Module(body=[function],type_ignores=[]),'<native-adapted>','exec'),namespace)
    return namespace[name]
old_show=load_function(show_source,'_handle_show',dict(vars(native)))
before=json.loads(old_show({'board':'beta','task_id':ids['beta']}))
assert 'error' in before, before
new_show=load_function(adapt('tools/kanban_tools.py',show_source),'_handle_show',dict(vars(native)))
after=json.loads(new_show({'board':'beta','task_id':ids['beta']}))
assert after['task']['id']==ids['beta'],after
assert os.environ['HERMES_KANBAN_DB']==pin and os.environ['HERMES_KANBAN_TASK']==ids['alpha']
mutation=json.loads(native._handle_comment({'board':'beta','task_id':ids['beta'],'text':'must refuse'}))
assert 'error' in mutation,mutation
print('PASS native: reproduced pinned not-found, explicit coordinator read succeeds, mutation remains fenced')

from agent.error_classifier import classify_api_error
class ProviderError(Exception):
    def __init__(self,status,message):
        super().__init__(message);self.status_code=status
for status,message in [(401,'API key expired'),(403,'An active subscription is required'),
                       (402,'Payment required'),(404,'model not found'),(429,'rate limited')]:
    verdict=classify_api_error(ProviderError(status,message),provider='custom',model='fixture')
    assert verdict.should_fallback,(status,verdict)
print('PASS native: auth, subscription, billing, missing-model and quota verdicts permit configured fallback')

from hermes_cli import fallback_config, profiles
from agent import agent_init
chain=[{'provider':'openai-codex','model':'fixture'}]
config={'fallback_providers':chain}
functions=[]
for name,module,function in [('hermes_cli/fallback_config.py',fallback_config,'get_fallback_chain'),
                             ('agent/agent_init.py',agent_init,'_fallback_entries')]:
    text=adapt(name,(args.hermes_repo/name).read_text())
    functions.append(load_function(text,function,dict(vars(module))))
for profile in ('head-coordinator','standard-implementer','local-implementer'):
    with patch.dict(os.environ,{'HERMES_PROFILE_NAME':profile}), patch.object(profiles,'current_profile_name',return_value=profile):
        expected=[] if profile=='local-implementer' else chain
        assert functions[0](config)==expected
        assert functions[1](chain)==expected
assert config=={'fallback_providers':chain}
print('PASS native: shared config and init-time/turn-time fallback normalization retain configured Codex chain, suppress credential lane')
