"""Exact, idempotent native seams for authenticated coordinator management."""
import ast

SCHEMA = '''
KANBAN_MANAGE_SCHEMA = {
    "name": "kanban_manage",
    "description": "Authenticated head-coordinator board management. Inspect with task_id alone; then use that exact expected_version, action and evidence-backed reason. Completes parked coordinator handoffs from finished genuine native runs without spawning workers. Also blocks, schedules, assigns suitable fresh work, promotes eligible work, specifies generic triage, contains dead workers without retry reset, and archives terminal records. Active workers, owner/provider gates, review independence and capability recovery remain protected. No terminal or delegate authority.",
    "parameters": {"type":"object", "additionalProperties":False, "properties": {
        "board":{"type":"string"}, "task_id":{"type":"string"},
        "action":{"type":"string","enum":["complete","block","schedule","assign","promote","specify","reclaim","archive"]},
        "expected_version":{"type":"string"}, "reason":{"type":"string"},
        "kind":{"type":"string","enum":["capability","dependency","needs_input","transient"]},
        "assignee":{"type":"string"}, "title":{"type":"string"}, "body":{"type":"string"},
        "delivery":{"type":"object"},
        "metadata":{"type":"object","description":"Required existing handoff fields, such as board_progress. Cannot assert verdict, independence, worker_session_id or replace coordinator provenance."},
        "evidence":{"type":"array","minItems":1,"maxItems":16,"items":{
            "type":"object","additionalProperties":False,"properties":{
                "task_id":{"type":"string"},"run_id":{"type":"integer"},"why":{"type":"string"}},
            "required":["task_id","run_id","why"]}}},"required":["task_id"]}}

KANBAN_DELIVER_SCHEMA = {
    "name":"kanban_deliver_file",
    "description":"Authenticated coordinator only: copy a declared non-secret card artifact by exact SHA256 into a parked sibling's inputs, without putting file bytes through the model. Inspect destination version with kanban_manage first. Sources are same-board card artifacts/attachments, never credential-lane or secret paths. Native attachment limits stay unchanged; larger files up to 256 MiB use the prepared task workspace plus a native manifest. Refuses changed destinations and active workers; never unblocks or accepts work.",
    "parameters":{"type":"object","additionalProperties":False,"properties":{
        "board":{"type":"string"},"task_id":{"type":"string"},"expected_version":{"type":"string"},
        "source_task_id":{"type":"string"},"source_path":{"type":"string"},"sha256":{"type":"string"},
        "classification":{"type":"string","enum":["non-secret"]},"filename":{"type":"string"}},
        "required":["task_id","expected_version","source_task_id","source_path","sha256","classification"]}}

KANBAN_ROUTE_SCHEMA = {
    "name":"kanban_route",
    "description":"Authenticated coordinator only: queue one idempotent internal request to the fixed head-coordinator recipient for a different registered board. Name its existing open coordinator task when present; otherwise request scoped admission. This writes no foreign card, borrows no authority, changes no pins, and launches no worker itself. Reuse existing owners and gates. A queued receipt is not execution, repair or acceptance.",
    "parameters":{"type":"object","additionalProperties":False,"properties":{
        "target_board":{"type":"string"},"target_task_id":{"type":"string"},"message":{"type":"string"}},
        "required":["target_board","message"]}}
'''

HANDLER = '''
@_kanban_handler("kanban_manage")
def _handle_manage(args: dict, **kwargs):
    _reject_delegated_child_mutation("kanban_manage")
    from hermes_cli.nixhomeserver_coordinator_tools import manage, require_requested_board
    actor = require_requested_board(args.get("board"))
    _check(actor is not None, "Authenticated native head-coordinator required")
    with _board(actor["board"]) as (kb, conn):
        return _ok(**manage(kb, conn, str(args["task_id"]),
            **{key:value for key,value in args.items() if key not in {"board","task_id"}}))


@no_cache_check_fn
def _check_kanban_manage_mode():
    from hermes_cli.nixhomeserver_resume_recovered import coordinator_origin
    return coordinator_origin() is not None


registry.register(name="kanban_manage", toolset="kanban", schema=KANBAN_MANAGE_SCHEMA,
                  handler=_handle_manage, emoji="✎", check_fn=_check_kanban_manage_mode)


@_kanban_handler("kanban_deliver_file")
def _handle_deliver_file(args: dict, **kwargs):
    _reject_delegated_child_mutation("kanban_deliver_file")
    from hermes_cli.nixhomeserver_coordinator_tools import require_requested_board
    from hermes_cli.nixhomeserver_coordinator_delivery import deliver_file
    actor=require_requested_board(args.get("board"))
    _check(actor is not None,"Authenticated native head-coordinator required")
    with _board(actor["board"]) as (kb,conn):
        return _ok(**deliver_file(kb,conn,**{k:v for k,v in args.items() if k!="board"}))


@_kanban_handler("kanban_route")
def _handle_route(args: dict, **kwargs):
    _reject_delegated_child_mutation("kanban_route")
    from hermes_cli.nixhomeserver_resume_recovered import coordinator_origin
    from hermes_cli.nixhomeserver_coordinator_delivery import route_request
    actor=coordinator_origin()
    _check(actor is not None,"Authenticated native head-coordinator required")
    with _board(actor["board"]) as (kb,conn):
        return _ok(**route_request(kb,conn,**args))


registry.register(name="kanban_deliver_file", toolset="kanban", schema=KANBAN_DELIVER_SCHEMA,
                  handler=_handle_deliver_file, emoji="⇢", check_fn=_check_kanban_manage_mode)
registry.register(name="kanban_route", toolset="kanban", schema=KANBAN_ROUTE_SCHEMA,
                  handler=_handle_route, emoji="⇢", check_fn=_check_kanban_manage_mode)
'''


def replace(text, before, after):
    if text.count(after) == 1:
        return text
    if text.count(before) != 1:
        raise ValueError('Native coordinator tool source drift; reconcile before installation')
    return text.replace(before, after, 1)


def function(text, name, edits):
    nodes=[node for node in ast.parse(text).body if isinstance(node,ast.FunctionDef) and node.name==name]
    if len(nodes)!=1:
        raise ValueError('Native coordinator function is missing or ambiguous: '+name)
    node=nodes[0]
    old=ast.get_source_segment(text,node)
    new=old
    for before,after in edits:
        new=replace(new,before,after)
    return text.replace(old,new,1)


def adapt(name, text):
    if name == 'hermes_cli/kanban_db_connect.py':
        text=function(text,'write_txn',[(
            '    try:\n        yield conn\n',
            '    try:\n        from hermes_cli.nixhomeserver_coordinator_tools import before_write, after_write\n'
            '        before_write(conn)\n        yield conn\n        after_write(conn)\n')])
    elif name == 'hermes_cli/kanban_db.py':
        text=function(text,'add_attachment',[(
            '    with write_txn(conn):',
            '    with write_txn(conn, allow_nested=True):')])
        for method in ('complete_task','block_task','schedule_task'):
            before={'complete_task':"AND status IN ('running', 'ready', 'blocked', 'review')",
                    'block_task':"AND status IN ('running', 'ready')",
                    'schedule_task':"AND status IN ('todo', 'ready', 'running', 'blocked')"}[method]
            marker='        if expected_run_id is not None:\n'
            extension=('        from hermes_cli.nixhomeserver_coordinator_tools import parked_transition\n'
                       '        if parked_transition(task_id):\n'
                       f'            sql = sql.replace({before!r}, '
                       '"AND status IN (\'todo\', \'ready\', \'blocked\', \'scheduled\', \'triage\')")\n'+marker)
            text=function(text,method,[(marker,extension)])
        text=function(text,'_synthesize_ended_run',[(
            '    now = int(time.time())\n',
            '    from hermes_cli.nixhomeserver_coordinator_tools import closing_record\n'
            '    profile, metadata = closing_record(task_id, profile, metadata)\n'
            '    now = int(time.time())\n')])
    elif name == 'tools/kanban_tools_schemas.py':
        if SCHEMA not in text:
            text=text.rstrip()+'\n'+SCHEMA
    elif name == 'tools/kanban_tools.py':
        text=replace(text,'logger = logging.getLogger(__name__)',
                     'from tools.kanban_tools_schemas import KANBAN_MANAGE_SCHEMA, KANBAN_DELIVER_SCHEMA, KANBAN_ROUTE_SCHEMA\n\nlogger = logging.getLogger(__name__)')
        text=function(text,'_check_kanban_orchestrator_mode',[(
            '    return _visible(to_env_worker=False)',
            '    from hermes_cli.nixhomeserver_resume_recovered import coordinator_origin\n'
            '    return _visible(to_env_worker=False) or coordinator_origin() is not None')])
        text=function(text,'_require_orchestrator_tool',[(
            '    if os.environ.get("HERMES_KANBAN_TASK"):',
            '    from hermes_cli.nixhomeserver_resume_recovered import coordinator_origin\n'
            '    if os.environ.get("HERMES_KANBAN_TASK") and coordinator_origin() is None:')])
        text=function(text,'_handle_list',[(
            '    _require_orchestrator_tool("kanban_list")\n',
            '    _require_orchestrator_tool("kanban_list")\n'
            '    from hermes_cli.nixhomeserver_coordinator_tools import require_requested_board\n'
            '    require_requested_board(args.get("board"))\n')])
        text=function(text,'_worker_guard',[(
            '    _enforce_worker_task_ownership(tid)\n',
            '    from hermes_cli.nixhomeserver_coordinator_tools import attachment_target\n'
            '    if tool_name not in {"kanban_attach", "kanban_attach_url"} or not attachment_target(tid, args.get("board")):\n'
            '        _enforce_worker_task_ownership(tid)\n')])
        if HANDLER not in text:
            text=text.rstrip()+'\n'+HANDLER
    else:
        raise ValueError('Unknown coordinator adapter target: '+name)
    compile(text,name,'exec')
    return text
