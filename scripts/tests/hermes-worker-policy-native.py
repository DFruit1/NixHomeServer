#!/usr/bin/env python3
"""Opt-in native lifecycle regression; all boards and homes stay in --scratch."""
import argparse
import os
from pathlib import Path
import sys
import time

parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--hermes-repo',type=Path,required=True)
parser.add_argument('--scratch',type=Path,required=True)
args=parser.parse_args()
args.scratch.mkdir(parents=True,exist_ok=True)
os.environ['HERMES_HOME']=str(args.scratch/'home')
os.environ['HERMES_ROOT']=os.environ['HERMES_HOME']
os.environ['HERMES_KANBAN_WORKSPACES_ROOT']=str(args.scratch/'workspaces')
sys.path.insert(0,str(args.hermes_repo))
import hermes_bootstrap  # noqa: E402,F401
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'hermes'))
from worker_runtime_adapter import adapt  # noqa: E402
overlay=args.scratch/'overlay';overlay.mkdir(exist_ok=True)
for name in ('kanban_db.py','kanban_db_dispatch.py'):
    (overlay/name).write_text(adapt(name,(args.hermes_repo/'hermes_cli'/name).read_text()))
(overlay/'nixhomeserver_worker_policy.py').write_text((Path(__file__).resolve().parents[1]/'hermes/worker-policy.py').read_text())
import hermes_cli  # noqa: E402
hermes_cli.__path__.insert(0,str(overlay))
from hermes_cli import kanban_db as kb,kanban_db_dispatch as dispatch  # noqa: E402
from hermes_cli.kanban_db_connect import connect  # noqa: E402
from unittest.mock import patch  # noqa: E402
db=connect(args.scratch/'board.db')
try:
    try:
        kb.create_task(db,title='Unbounded local',assignee='local-implementer')
        raise AssertionError('Unbounded native create succeeded')
    except ValueError:
        pass
    local=kb.create_task(db,title='Bounded local',assignee='local-implementer',max_runtime_seconds=300,
                         workspace_kind='dir',workspace_path=str(args.scratch))
    db.execute('UPDATE tasks SET max_runtime_seconds=NULL WHERE id=?',(local,))
    row=db.execute('SELECT * FROM tasks WHERE id=?',(local,)).fetchone()
    result=dispatch.DispatchResult()
    spawn=[]
    with patch.object(dispatch,'_profile_exists_fn',return_value=lambda _:True):
        consumed=dispatch._dispatch_lane_task(db,row,'local-implementer',result,lane='ready',dry_run=False,
            ttl_seconds=None,board=None,failure_limit=2,spawn_fn=lambda *a,**k:spawn.append(a),
            per_profile_caps=None,per_profile_running={})
    assert not consumed and not spawn
    assert kb.get_task(db,local).status=='blocked'
    try:
        kb.unblock_task(db,local)
        raise AssertionError('Unbounded native unblock succeeded')
    except ValueError:
        pass
    db.execute('UPDATE tasks SET max_runtime_seconds=300 WHERE id=?',(local,))
    assert kb.unblock_task(db,local)
    race=kb.create_task(db,title='Concurrent cap removal',assignee='local-implementer',max_runtime_seconds=300,
                       workspace_kind='dir',workspace_path=str(args.scratch))
    row=db.execute('SELECT * FROM tasks WHERE id=?',(race,)).fetchone()
    original_claim=kb.claim_task
    def edit_before_claim(conn,task_id,**kwargs):
        conn.execute('UPDATE tasks SET max_runtime_seconds=NULL WHERE id=?',(task_id,))
        return original_claim(conn,task_id,**kwargs)
    with patch.object(dispatch,'_profile_exists_fn',return_value=lambda _:True), \
         patch.object(kb,'claim_task',side_effect=edit_before_claim):
        consumed=dispatch._dispatch_lane_task(db,row,'local-implementer',dispatch.DispatchResult(),
            lane='ready',dry_run=False,ttl_seconds=None,board=None,failure_limit=2,
            spawn_fn=lambda *a,**k:spawn.append(a),per_profile_caps=None,per_profile_running={})
    assert not consumed and not spawn and kb.get_task(db,race).status=='blocked'
    recovery=kb.create_task(db,title='Return preserved evidence',assignee='standard-implementer',
        body='Recovery mode: evidence-only',max_runtime_seconds=600,
        workspace_kind='dir',workspace_path=str(args.scratch))
    assert kb.get_task(db,recovery).max_retries==1
    claim=kb.claim_task(db,recovery)
    assert claim
    assert dispatch._record_task_failure(db,recovery,'Synthetic timeout',outcome='timed_out',
        release_claim=True,end_run=True)
    assert kb.get_task(db,recovery).status=='blocked'
    try:
        kb.unblock_task(db,recovery)
        raise AssertionError('Unchanged native recovery unblock succeeded')
    except ValueError:
        pass
    run=db.execute('SELECT id FROM task_runs WHERE task_id=? ORDER BY id DESC LIMIT 1',(recovery,)).fetchone()[0]
    kb.add_comment(db,recovery,author='head-coordinator',body=f'Recovery run: {run}\n'
        'Recovery change: The synthetic receipt is now attached.\nRecovery action: Read that receipt only.')
    assert kb.unblock_task(db,recovery)
    assert db.execute('PRAGMA integrity_check').fetchone()[0]=='ok'
    print('PASS native create, dispatch, first-failure breaker, release receipts and database integrity')
finally:
    db.close()
