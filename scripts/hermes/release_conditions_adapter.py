"""Exact additive seams for the installed Hermes condition API."""
import ast

PARSER = '''
# Maintained deterministic release-condition API (v1).
_SPECS.append(_cmd("conditions", children=("conditions_action", [
    _cmd("show", (_TASK_ID,)),
    _cmd("artifact", (_TASK_ID,_arg("--attachment-id",type=int,required=True))),
    _cmd("migrate", (_arg("--file",required=True),)),
    _cmd("register", (_TASK_ID, _arg("--file", required=True), _arg("--version", required=True))),
    _cmd("publish", (_TASK_ID, _arg("--attachment-id",type=int,required=True),
        _arg("--sha256",required=True),_arg("--classification",choices=("non-secret",),required=True))),
    _cmd("apply", (_TASK_ID, _arg("--registration-id",type=int,required=True))),
])))
'''
CLI = '''
# Maintained deterministic release-condition API (v1).
def _cmd_conditions(args):
    from hermes_cli.nixhomeserver_release_conditions import cli
    return cli(args, kb, kbc)
_HANDLERS["conditions"] = _cmd_conditions
'''
TOOL = '''
# Maintained deterministic release-condition API (v1).
@_kanban_handler("kanban_conditions")
def _handle_conditions(args: dict, **kwargs):
    _reject_delegated_child_mutation("kanban_conditions")
    from hermes_cli.nixhomeserver_coordinator_tools import require_requested_board
    from hermes_cli.nixhomeserver_release_conditions import load, hold_version, register, publish
    from hermes_cli.nixhomeserver_resume_recovered import require_actor_board
    actor = require_requested_board(args.get("board"))
    _check(actor is not None, "Authenticated native head-coordinator required")
    with _board(actor["board"]) as (kb, conn):
        root, board = require_actor_board(conn, actor)
        tid = str(args["task_id"])
        action = args.get("action", "show")
        if action == "show":
            return _ok(hold_version=hold_version(conn, tid), release_conditions=load(conn, tid))
        if action == "publish":
            return _ok(**publish(kb,conn,root,tid,args["attachment_id"],args["sha256"],
                args["classification"],actor=actor))
        _check(action == "register", "Use show, register or publish; supervisor owns apply")
        return _ok(**register(kb,conn,root,tid,args["contract"],args["expected_version"],actor=actor))

registry.register(name="kanban_conditions", toolset="kanban", emoji="⏳",
    handler=_handle_conditions, check_fn=_check_kanban_manage_mode, schema={
    "name":"kanban_conditions",
    "description":"Authenticated native coordinator: inspect/register typed deterministic conditions on a parked own-board card, or publish a bounded non-secret attachment as immutable evidence. CAS is the exact hold_version from show. Automatic releases preserve counters and all owner/provider/iteration/deploy gates. The five-minute supervisor applies satisfied conditions; manual contracts never release. See hermes-release-conditions.md for the versioned contract.",
    "parameters":{"type":"object","additionalProperties":False,"properties":{
        "board":{"type":"string"},"task_id":{"type":"string"},
        "action":{"type":"string","enum":["show","register","publish"]},
        "contract":{"type":"object"},"expected_version":{"type":"string"},
        "attachment_id":{"type":"integer"},"sha256":{"type":"string"},
        "classification":{"type":"string","enum":["non-secret"]}},"required":["task_id"]}})
'''


def replace_once(text, before, after):
    if text.count(after)==1:
        return text
    if text.count(before)!=1:
        raise ValueError('Native release-condition source drift: '+before[:70])
    return text.replace(before,after,1)


def adapt(name, text):
    if name=='hermes_cli/kanban_db.py':
        before='\n\ndef _end_run(\n'
        after='''
    if kind == "completed":
        from hermes_cli.nixhomeserver_release_conditions import seal_output
        seal_output(conn, task_id, run_id)


def _end_run(
'''
        text=replace_once(text,before,after)
        schema='\n# Native immutable release artifacts (v1).\nfrom hermes_cli.nixhomeserver_release_conditions import ARTIFACT_SCHEMA\nSCHEMA_SQL += ARTIFACT_SCHEMA\n'
        if schema not in text:text+=schema
        text=replace_once(text,"AND kind != 'decomposed' ",
            "AND kind NOT IN ('decomposed','release_conditions_registered','release_conditions_applied',"
            "'release_output_sealed','release_artifact_published','diagnostic_closed','created','claimed','spawned','worker_registered','completed','review_requested') ")
    elif name=='hermes_cli/kanban_db_connect.py':
        # ATTACH mode=ro must work on native CPython SQLite builds whose
        # compile-time URI default is off, as well as the system test Python.
        text=replace_once(text,'        connect_fn=sqlite3.connect,\n        isolation_level=None,',
            '        connect_fn=sqlite3.connect,\n        uri=True,\n        isolation_level=None,')
    elif name=='hermes_cli/kanban_parser.py':
        if PARSER not in text:
            text=replace_once(text,'\ndef build_parser(',PARSER+'\ndef build_parser(')
    elif name=='hermes_cli/kanban.py':
        if CLI not in text:text+='\n'+CLI
        text=replace_once(text,'    "gc",\n','    "gc", "conditions",\n')
        text=replace_once(text,'        latest_summary = kb.latest_summary(conn, args.task_id)\n',
            '        latest_summary = kb.latest_summary(conn, args.task_id)\n'
            '        from hermes_cli.nixhomeserver_release_conditions import load as release_conditions\n'
            '        conditions = release_conditions(conn, args.task_id)\n')
        text=replace_once(text,'"task": _task_to_dict(task), "latest_summary": latest_summary,',
            '"task": _task_to_dict(task), "release_conditions": conditions, "latest_summary": latest_summary,')
    elif name=='tools/kanban_tools.py':
        text=replace_once(text,'            \"workflow\": __import__(\"hermes_cli.nixhomeserver_fleet_contract\", fromlist=[\"load\"]).load(conn, tid),',
            '            \"workflow\": __import__(\"hermes_cli.nixhomeserver_fleet_contract\", fromlist=[\"load\"]).load(conn, tid),\n'
            '            \"release_conditions\": __import__(\"hermes_cli.nixhomeserver_release_conditions\", fromlist=[\"load\"]).load(conn, tid),')
        if TOOL not in text:text+='\n'+TOOL
    else:raise ValueError('Unknown native release-condition target')
    ast.parse(text)
    return text
