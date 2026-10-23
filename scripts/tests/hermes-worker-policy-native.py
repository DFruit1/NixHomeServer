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
# A dispatched worker's own pins must never decide this isolated fixture.
for key in ('HERMES_KANBAN_TASK','HERMES_KANBAN_RUN_ID','HERMES_KANBAN_DB',
            'HERMES_KANBAN_BOARD','HERMES_DELEGATED_CHILD_CONTEXT'):
    os.environ.pop(key,None)
os.environ['HERMES_DISABLE_LAZY_INSTALLS']='1'
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
(overlay/'nixhomeserver_create_board.py').write_text((Path(__file__).resolve().parents[1]/'hermes/create-board-policy.py').read_text())
tools_overlay=args.scratch/'tools-overlay';tools_overlay.mkdir(exist_ok=True)
for name in ('kanban_tools.py','kanban_tools_schemas.py'):
    (tools_overlay/name).write_text(adapt('tools/'+name,(args.hermes_repo/'tools'/name).read_text()))
import tools  # noqa: E402
tools.__path__.insert(0,str(tools_overlay))
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
    # A coordinator's implementation pin must not prevent its independent
    # reviewer from executing. Exercise the real transformed native dispatcher.
    import json
    from hermes_cli import nixhomeserver_worker_policy as policy
    from hermes_cli import nixhomeserver_coordinator_repair as repair
    for claimed_producer in (False,True):
        review=kb.create_task(db,title='Review coordinator output',assignee='head-coordinator',
            skills=['kanban-orchestration','systematic-debugging'],
            workspace_kind='dir',workspace_path=str(args.scratch))
        producer=kb.claim_task(db,review) if claimed_producer else None
        assert kb.request_review(db,review,reviewer='feature-reviewer',summary='Synthetic coordinator output',
            expected_run_id=producer.current_run_id if producer else None)
        handoff=db.execute("SELECT * FROM task_events WHERE task_id=? AND kind='review_requested'",(review,)).fetchone()
        handoff_before=dict(handoff)
        task_before=kb.get_task(db,review)
        spawned=[]
        def capture(*values,**kwargs):
            spawned.append((values[0].assignee,list(values[0].skills)))
        with patch.object(repair,'available_skills',return_value={'systematic-debugging','sdlc-review'}), \
             patch.object(dispatch,'_profile_exists_fn',return_value=lambda _:True):
            row=db.execute('SELECT * FROM tasks WHERE id=?',(review,)).fetchone()
            result=dispatch.DispatchResult()
            consumed=dispatch._dispatch_lane_task(db,row,'feature-reviewer',result,
                lane='review',dry_run=False,ttl_seconds=None,board=None,failure_limit=2,
                spawn_fn=capture,per_profile_caps=None,per_profile_running={})
            assert consumed and spawned, ('independent review stranded',result)
            assert spawned==[('feature-reviewer',['systematic-debugging','sdlc-review'])],spawned
            assert kb.get_task(db,review).skills==task_before.skills
            assert dict(db.execute('SELECT * FROM task_events WHERE id=?',(handoff['id'],)).fetchone())==handoff_before
            # Rework restores the implementer's exact original requirements.
            active=kb.get_task(db,review)
            assert kb.request_changes(db,review,reason='Synthetic requested correction',
                expected_run_id=active.current_run_id)==(True,'head-coordinator')
            assert kb.get_task(db,review).assignee=='head-coordinator'
            assert kb.get_task(db,review).skills==task_before.skills
            assert 'kanban-orchestration' in policy.reason(db,review,'head-coordinator')
    held=kb.create_task(db,title='Keep other reviewer requirements',assignee='head-coordinator',
        skills=['kanban-orchestration','required-unavailable'],
        workspace_kind='dir',workspace_path=str(args.scratch))
    assert kb.request_review(db,held,reviewer='feature-reviewer',summary='Synthetic output with missing reviewer requirement')
    before=list(db.iterdump());spawned=[]
    with patch.object(repair,'available_skills',return_value={'sdlc-review'}), \
         patch.object(dispatch,'_profile_exists_fn',return_value=lambda _:True):
        row=db.execute('SELECT * FROM tasks WHERE id=?',(held,)).fetchone()
        assert 'required-unavailable' in policy.reason(db,held,'feature-reviewer')
        assert not dispatch._dispatch_lane_task(db,row,'feature-reviewer',dispatch.DispatchResult(),
            lane='review',dry_run=False,ttl_seconds=None,board=None,failure_limit=2,
            spawn_fn=capture,per_profile_caps=None,per_profile_running={})
        assert not spawned and before==list(db.iterdump())
    print('PASS native independent reviewer receives sdlc-review without coordinator pin; rework retains original skills')
    # --- Model-facing kanban_create names its board ---------------------------
    # The schema and the handler are the real adapted native seams, exercised
    # against board files that only exist under --scratch.
    assert 'tools.kanban_tools' not in sys.modules, 'import the tool seam before another module pins upstream'
    from tools import kanban_tools as kanban_tools
    from tools import kanban_tools_schemas as tool_schemas
    assert list(kanban_tools.registry.get_schema('kanban_create')['parameters']['required'])==[
        'title','assignee','board']
    assert 'board' not in kanban_tools.registry.get_schema('kanban_show')['parameters']['required']
    for name,schema in vars(tool_schemas).items():
        if name!='KANBAN_CREATE_SCHEMA' and isinstance(schema,dict):
            required=(schema.get('parameters') or {}).get('required') or []
            assert 'board' not in required, 'board became mandatory for '+name
    assert tool_schemas.KANBAN_CREATE_SCHEMA['parameters']['properties']['board']['description'].startswith(
        'Kanban board slug to target. kanban_create requires it explicitly')
    def create(**fields):
        return json.loads(kanban_tools._handle_create(fields))
    kb.create_board('ownboard'); kb.create_board('otherboard')
    own_path=kb.kanban_db_path('ownboard'); other_path=kb.kanban_db_path('otherboard')
    def task_count(path):
        conn=connect(path)
        try:
            return conn.execute('SELECT COUNT(*) FROM tasks').fetchone()[0]
        finally:
            conn.close()
    for fields,expected in (
            ({'title':'Omitted board','assignee':'standard-implementer'},'board is required'),
            ({'title':'Blank board','assignee':'standard-implementer','board':'   '},'board is required'),
            ({'title':'Malformed board','assignee':'standard-implementer','board':'Bad Board'},
             'valid board slug'),
            ({'title':'Unknown board','assignee':'standard-implementer','board':'no-such-board'},
             'does not exist')):
        result=create(**fields)
        assert expected in result.get('error',''), (fields,result)
        assert 'Nothing changed' in result['error'], result
    assert not kb.board_dir('no-such-board').exists(), 'a refused create must not invent a board'
    assert task_count(own_path)==0 and task_count(other_path)==0
    created=create(title='Named board',assignee='standard-implementer',board='ownboard')
    assert created.get('task_id'), created
    own=connect(own_path)
    try:
        assert kb.get_task(own,created['task_id']).title=='Named board'
        worker_card=kb.create_task(own,title='Worker card',assignee='standard-implementer',
            workspace_kind='dir',workspace_path=str(args.scratch))
    finally:
        own.close()
    assert task_count(other_path)==0
    with patch.dict(os.environ,{'HERMES_KANBAN_BOARD':'ownboard','HERMES_KANBAN_DB':str(own_path),
                                'HERMES_KANBAN_TASK':worker_card,'HERMES_KANBAN_RUN_ID':'1'}):
        for board,expected in (('otherboard',"own board 'ownboard'"),(None,'board is required')):
            fields={'title':'Foreign worker board','assignee':'standard-implementer'}
            if board is not None:
                fields['board']=board
            result=create(**fields)
            assert expected in result.get('error',''), (board,result)
        assert task_count(other_path)==0, 'a worker must not write another board'
        own_before=task_count(own_path)
        result=create(title='Worker own board',assignee='standard-implementer',board='ownboard')
        assert result.get('task_id'), result
        assert task_count(own_path)==own_before+1
    print('PASS native kanban_create requires an existing explicit board and keeps the worker own-board fence')
    assert db.execute('PRAGMA integrity_check').fetchone()[0]=='ok'
    print('PASS native create, dispatch, first-failure breaker, release receipts and database integrity')
finally:
    db.close()
