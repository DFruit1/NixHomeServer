"""Source-checked native record tool/CLI seams; refuse unknown source before writes."""

HANDLER = '''@_kanban_handler("kanban_record")
def _handle_record(args: dict, **kwargs):
    from hermes_cli import nixhomeserver_card_records as records
    tid = _require_task_id(args)
    if args.get("kind") is None:
        _check(args.get("value") is None and args.get("expected_version") is None,
               "A write requires kind, value and expected_version together")
        from hermes_cli.nixhomeserver_autonomy import evidence_board
        with evidence_board(_board, args.get("board"), _persisted_identity()) as (kb, conn):
            return _ok(**records.inspect(conn, tid))
    _reject_delegated_child_mutation("kanban_record")
    from hermes_cli.nixhomeserver_resume_recovered import coordinator_origin
    actor = coordinator_origin()
    _check(_persisted_identity() == "head-coordinator", "Coordinator identity required")
    if __import__("os").environ.get("HERMES_KANBAN_TASK"):
        _check(actor is not None, "Native coordinator origin required")
        _check(args.get("board") in (None, actor["board"]), "Record only on the authenticated board")
    value = args.get("value")
    _check(isinstance(value, dict), "value must be an object")
    safe = _redact_metadata(value)
    _check(safe == value, "Record contains sensitive text; use a non-secret reference")
    with _board(actor["board"] if actor else args.get("board")) as (kb, conn):
        return _ok(**records.write(kb, conn, tid, args["kind"], value,
            actor="head-coordinator", expected_version=args.get("expected_version")))


'''

REGISTRATION = '''
registry.register(name="kanban_record", toolset="kanban", schema=KANBAN_RECORD_SCHEMA,
                  handler=_handle_record, emoji="▤", check_fn=_check_kanban_mode)
'''

SCHEMA = '''
KANBAN_RECORD_SCHEMA = {
    "name": "kanban_record",
    "description": "Read current typed card records with task_id. Coordinator writes use kind, value and the inspected expected_version. Records never change status, satisfy prerequisites, accept work or authorize execution by themselves. Detailed evidence belongs in native attachments/run metadata.",
    "parameters": {"type": "object", "additionalProperties": False,
        "properties": {"board": {"type": "string"}, "task_id": {"type": "string"},
            "kind": {"type": "string", "enum": ["decision_owner", "feature", "recovery", "merge_back", "approval", "owner_summary", "owner_reply", "feature_input", "deployment_decision", "owner_execution_decision", "delegated_execution_decision"]},
            "value": {"type": "object", "description": "Closed typed schema documented in hermes-card-records.md; no prose protocol markers."},
            "expected_version": {"type": "string"}}, "required": ["task_id"]}}
'''

CLI = '''def _cmd_record(args: argparse.Namespace) -> int:
    from hermes_cli import nixhomeserver_card_records as records
    with kbc.connect_closing() as conn:
        if args.kind is None:
            result = records.inspect(conn, args.task_id)
        else:
            if args.data is None or args.expected_version is None:
                return _err("A write requires --kind, --data and --expected-version together")
            if _profile_author() != "head-coordinator":
                return _err("Only the coordinator may write card records")
            if os.environ.get("HERMES_KANBAN_TASK"):
                from hermes_cli.nixhomeserver_resume_recovered import coordinator_origin
                actor = coordinator_origin()
                if actor is None or Path(kb.kanban_db_path()).parent.name != actor["board"]:
                    return _err("Native coordinator board identity required")
            result = records.write(kb, conn, args.task_id, args.kind, json.loads(args.data),
                actor="head-coordinator", expected_version=args.expected_version)
    _print_json(result)
    return 0


'''

PARSER = '''    _cmd("record", [
        _TASK_ID,
        _arg("--kind", help="Typed control record; omit to inspect current records/version"),
        _arg("--data", help="JSON object matching the record kind"),
        _arg("--expected-version", help="Exact version returned by record inspection"),
    ], help="Read or record typed card evidence without a comment"),
'''


def replace(text, before, after, name):
    if text.count(after) == 1:
        return text
    if text.count(before) != 1:
        raise ValueError('Native card-record source drift: ' + name)
    return text.replace(before, after, 1)


def adapt(name, text):
    if name == 'tools/kanban_tools.py':
        addition = '\nfrom tools.kanban_tools_schemas import KANBAN_RECORD_SCHEMA\n\n' + HANDLER + REGISTRATION
        if addition not in text:
            text = text.rstrip() + '\n' + addition
        anchor = '            "parents": kb.parent_ids(conn, tid),'
        text = replace(text, anchor, '            "records": __import__("hermes_cli.nixhomeserver_card_records", fromlist=["inspect"]).inspect(conn, tid),\n' + anchor, name)
    elif name == 'tools/kanban_tools_schemas.py':
        if SCHEMA not in text:
            text = text.rstrip() + '\n' + SCHEMA
    elif name == 'hermes_cli/kanban.py':
        text = replace(text, 'def _cmd_comment(args: argparse.Namespace) -> int:', CLI + 'def _cmd_comment(args: argparse.Namespace) -> int:', name)
        text = replace(text, '    "comment": _cmd_comment,', '    "record": _cmd_record, "comment": _cmd_comment,', name)
        text = replace(text, '    "claim", "comment",', '    "claim", "record", "comment",', name)
    elif name == 'hermes_cli/kanban_parser.py':
        text = replace(text, '    _cmd("comment", [', PARSER + '    _cmd("comment", [', name)
    elif name == 'hermes_cli/kanban_db.py':
        anchor = '    _ctx_comments(lines, list_comments(conn, task_id), now)\n'
        text = replace(text, anchor, anchor + '    from hermes_cli.nixhomeserver_card_records import context as record_context\n    lines.append(record_context(conn, task_id))\n', name)
    else:
        raise ValueError('Unknown card-record adapter target')
    compile(text, name, 'exec')
    return text
