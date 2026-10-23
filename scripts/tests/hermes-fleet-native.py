#!/usr/bin/env python3
"""Installed native tools and shell hooks, inside the maintained fixture only."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--hermes-repo', type=Path, required=True)
parser.add_argument('--scratch', type=Path, required=True)
args = parser.parse_args()
if os.environ.get('HERMES_FIXTURE_ACTIVE') != '1':
    parser.error('Use test-hermes-fleet-native.sh through the confined fixture; no unsandboxed fallback')
origin = json.loads(Path(os.environ['HERMES_FIXTURE_ORIGIN']).read_text())
assert Path(origin['suite']).name == 'test-hermes-fleet-native.sh'
assert origin['provenance'] == 'confined-synthetic-test'
assert not any(os.environ.get(k) for k in ('HERMES_KANBAN_TASK', 'HERMES_KANBAN_RUN_ID',
                                          'HERMES_DELEGATED_CHILD_CONTEXT'))
source = Path(__file__).resolve().parents[1] / 'hermes'
root = args.scratch / 'home'
root.mkdir()
for name in ('HERMES_HOME', 'HERMES_ROOT', 'HERMES_KANBAN_HOME'):
    os.environ[name] = str(root)
os.environ['HERMES_DISABLE_LAZY_INSTALLS'] = '1'
os.environ['HERMES_KANBAN_WORKSPACES_ROOT'] = str(args.scratch / 'workspaces')
sys.path.insert(0, str(source))
sys.path.insert(0, str(args.hermes_repo))
import hermes_bootstrap  # noqa: E402,F401


def module(name, filename):
    spec = importlib.util.spec_from_file_location(name, source / filename)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


# Install maintained transforms into a private native overlay. Other native
# modules are imported from the read-only declared runtime, never copied secrets.
for relative in ('hermes_cli/kanban_db.py', 'hermes_cli/kanban_db_dispatch.py',
                 'tools/kanban_tools.py', 'tools/kanban_tools_schemas.py',
                 'hermes_cli/nixhomeserver_resume_recovered.py',
                 'hermes_cli/nixhomeserver_coordinator_repair.py'):
    target = root / 'hermes-agent' / relative
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(args.hermes_repo / relative, target)
for profile in ('head-coordinator', 'standard-implementer', 'feature-reviewer', 'project-auditor'):
    directory = root / 'profiles' / profile
    directory.mkdir(parents=True)
    (directory / 'config.yaml').write_text('model:\n  default: fixture\n')
    (directory / 'profile.yaml').write_text('name: ' + profile + '\n')
# Installers use the declared system PyYAML interpreter; actual execution uses
# the native Hermes interpreter. Both run inside the same confined filesystem.
installation = r"""
import importlib.util, pathlib, sys
source, root = map(pathlib.Path, sys.argv[1:])
sys.path.insert(0, str(source))
def load(name, filename):
    spec=importlib.util.spec_from_file_location(name,source/filename)
    value=importlib.util.module_from_spec(spec);spec.loader.exec_module(value);return value
worker=load('fixture_worker_installer','install-worker-policy.py')
assert worker.install(root)==0
assert worker.install(root,check=True)==0
hooks=load('fixture_taskforce_installer','install-review-taskforce.py')
for path,text in hooks.review_hook_files(root).items():
    path.parent.mkdir(parents=True,exist_ok=True);path.write_text(text)
(root/'scripts/feature_flow.py').write_text((source/'feature_flow.py').read_text())
"""
subprocess.run(['/usr/bin/python3', '-B', '-c', installation, str(source), str(root)], check=True)
import hermes_cli  # noqa: E402
hermes_cli.__path__.insert(0, str(root / 'hermes-agent/hermes_cli'))
import tools  # noqa: E402
tools.__path__.insert(0, str(root / 'hermes-agent/tools'))
from hermes_cli import kanban_db as kb, kanban_db_dispatch as dispatch  # noqa: E402
from hermes_cli import nixhomeserver_worker_policy as policy  # noqa: E402
from hermes_cli.kanban_db_connect import connect  # noqa: E402
from tools import kanban_tools as transport  # noqa: E402
from agent import shell_hooks  # noqa: E402
import hermes_yaml as yaml  # noqa: E402
assert kb.kanban_home().resolve().is_relative_to(args.scratch.resolve())
kb.create_board('fixture')
db = connect(kb.kanban_db_path('fixture'))
assert Path(transport.__file__).is_relative_to(root)
assert Path(kb.__file__).is_relative_to(root)


def call(name, **fields):
    fields = dict(board='fixture', **fields)
    config = yaml.safe_load((root / 'profiles/feature-reviewer/config.yaml').read_text())
    for hook in config['hooks']['pre_tool_call']:
        callback = shell_hooks._make_callback(shell_hooks.ShellHookSpec(
            event='pre_tool_call', command=hook['command'], matcher=hook['matcher'],
            timeout=15, fail_closed=True))
        result = callback(tool_name=name, session_id='confined-fleet', args=fields)
        if result and result.get('action') == 'block':
            return {'error': result['message']}
    return json.loads(getattr(transport, '_handle_' + name.removeprefix('kanban_'))(fields))


def okay(value):
    assert 'error' not in value, value
    return value


work=args.scratch/'source';work.mkdir()
def git(*arguments):
    return subprocess.check_output(['git','-C',str(work),*arguments],stderr=subprocess.DEVNULL,text=True).strip()
git('init');git('config','user.name','Fixture');git('config','user.email','fixture@example.invalid')
git('commit','--allow-empty','-m','baseline');baseline=git('rev-parse','HEAD')
try:
    # Exercise real preclaim and post-preparation dispatch seams with an inert
    # spawn callback. No model or production process is started.
    spawned=[]
    def inert_spawn(*args,**kwargs):
        spawned.append((args,kwargs));return 99999999
    for revision,should_spawn in [('a'*40,False),(baseline,True)]:
        probe=okay(call('kanban_create',title='Dispatch prerequisite fixture',assignee='standard-implementer',
            workflow={'version':1,'requirements':{'source_revision':revision}},
            workspace_kind='dir',workspace_path=str(work)))['task_id']
        row=db.execute('SELECT * FROM tasks WHERE id=?',(probe,)).fetchone()
        result=dispatch.DispatchResult()
        dispatched=dispatch._dispatch_lane_task(db,row,'standard-implementer',result,lane='ready',dry_run=False,
            ttl_seconds=None,board='fixture',failure_limit=2,spawn_fn=inert_spawn,
            per_profile_caps=None,per_profile_running={})
        assert bool(dispatched)==should_spawn,(dispatched,result)
        assert (kb.get_task(db,probe).status=='blocked') != should_spawn
    assert len(spawned)==1
    tracker = okay(call('kanban_create', title='[FEATURE TRACKER] fixture slice',
                        assignee='head-coordinator', body='Requested synthetic accepted-source slice.'))['task_id']
    feature = {'tracker': 'fixture:' + tracker, 'role': 'producer',
               'scope': 'synthetic accepted source only', 'stage': 'accepted'}
    workflow = {'version': 1, 'review': 'native-review-v1', 'plan_author': 'owner', 'feature': feature,'requirements':{'source_revision':baseline}}
    tid = okay(call('kanban_create', title='Implement fixture slice', assignee='standard-implementer',
                   workflow=workflow, workspace_kind='dir', workspace_path=str(work)))['task_id']
    from hermes_cli import nixhomeserver_fleet_contract as contract
    assert contract.load(db, tid) == workflow
    # Conflicting body/comments cannot erase immutable workflow membership.
    db.execute('UPDATE tasks SET body=? WHERE id=?', ('Workflow: wrong\nFeature tracker: foreign:t_wrong', tid))
    kb.add_comment(db, tid, author='fixture', body='Feature tracker: foreign:t_wrong')
    claim = kb.claim_task(db, tid)
    assert claim
    checks = [{'command': 'confined fixture assertions', 'exit_code': 0}]
    git('commit','--allow-empty','-m','implementation');first=git('rev-parse','HEAD')
    handoff = {'revision': first, 'checks': checks}
    okay(call('kanban_request_review', task_id=tid, summary='Implemented and checked the requested fixture.',
              metadata=handoff, reviewer='feature-reviewer'))
    assert policy.reason(db,tid,'feature-reviewer') is None
    assert kb.claim_review_task(db, tid)
    accepted = {**handoff, 'verdict': 'accept',
                'independence': {'plan_author': False, 'implementer': False}}
    okay(call('kanban_request_changes', task_id=tid, reason='Synthetic correction required.'))
    assert kb.claim_task(db, tid)
    assert 'error' in call('kanban_complete', task_id=tid, summary='Cannot self-accept.', metadata=accepted)
    git('commit','--allow-empty','-m','rework');second=git('rev-parse','HEAD')
    handoff['revision'] = second
    okay(call('kanban_request_review', task_id=tid, summary='Corrected and checked the fixture.', metadata=handoff))
    assert kb.claim_review_task(db, tid)
    assert 'error' in call('kanban_complete', task_id=tid, summary='Stale revision.', metadata=accepted)
    accepted['revision'] = handoff['revision']
    okay(call('kanban_complete', task_id=tid, summary='Independently accepted fixture scope.', metadata=accepted))
    # GC must keep new contract authority even after terminal lifecycle history ages.
    db.execute('UPDATE task_events SET created_at=? WHERE task_id=?', (1, tid))
    kb.gc_events(db, older_than_seconds=1)
    assert contract.load(db, tid) == workflow
    assert okay(call('kanban_show', task_id=tid))['workflow'] == workflow
    delivery_feature = {**feature, 'role': 'delivery'}
    delivery_task = okay(call('kanban_create', title='Reconcile delivered fixture scope', assignee='head-coordinator',
                             workflow={'version': 1, 'feature': delivery_feature},
                             workspace_kind='dir', workspace_path=str(args.scratch)))['task_id']
    assert kb.claim_task(db, delivery_task)
    assert 'error' in call('kanban_complete', task_id=delivery_task, summary='Missing machine evidence.')
    sys.path.insert(0, str(root / 'scripts'))
    import feature_flow
    inspected = feature_flow.inspect_feature(db, 'fixture', tracker)
    delivery = {'state': 'delivered_scope', 'evidence_task_id': tid,
                'expected_version': inspected['evidence_version']}
    kb.add_comment(db, tracker, author='owner', body='An actual changed scope input.')
    assert 'error' in call('kanban_complete', task_id=delivery_task, summary='Stale scope.', delivery=delivery)
    try:
        kb.complete_task(db,delivery_task,summary='Stale scope through direct native call.',delivery=delivery)
        raise AssertionError('Native transaction accepted stale delivery')
    except ValueError:
        assert kb.get_task(db,delivery_task).status=='running'
    delivery['expected_version'] = feature_flow.inspect_feature(db, 'fixture', tracker)['evidence_version']
    okay(call('kanban_complete', task_id=delivery_task, summary='Accepted source scope delivered.', delivery=delivery))
    meta = json.loads(db.execute('SELECT metadata FROM task_runs WHERE task_id=? ORDER BY id DESC LIMIT 1',
                                (delivery_task,)).fetchone()[0])
    assert meta['feature_delivery']['revision'] == second
    assert meta['feature_delivery']['stage'] == 'accepted'
    assert not feature_flow.observe_features(db, 'fixture', int(time.time()) + 49 * 3600)
    recovery=okay(call('kanban_create',title='Interrupted recovery fixture',assignee='standard-implementer',
        body='Recovery mode: evidence-only',max_runtime_seconds=300,
        workflow={'version':1},workspace_kind='dir',workspace_path=str(work)))['task_id']
    claim=kb.claim_task(db,recovery)
    assert dispatch._record_task_failure(db,recovery,'Synthetic interruption',outcome='timed_out',
        release_claim=True,end_run=True)
    try:
        kb.unblock_task(db,recovery)
        raise AssertionError('Unchanged interrupted recovery was rearmed')
    except ValueError:
        pass
    assert kb.get_task(db,recovery).consecutive_failures==1
    print('PASS: installed tools/hooks dispatch, handoff, rejection/rework, independent acceptance, GC authority, transactional scope CAS, delivery and interrupted recovery')
finally:
    db.close()
