"""Pin the native recovery tool seam; reject incompatible upstream sources."""

_HANDLER = '''    _require_orchestrator_tool("kanban_unblock")
    tid = args.get("task_id")
    _check(tid, "task_id is required")
    tid = str(tid)
    _enforce_worker_task_ownership(tid)
    with _board(args.get("board")) as (kb, conn):
        _check(kb.unblock_task(conn, tid), f"could not unblock {tid} (not blocked or unknown)")
        return _ok(task_id=tid, **_fields(kb.get_task(conn, tid), ("status",)))'''
_RECOVERY_HANDLER = '''    from hermes_cli.nixhomeserver_resume_recovered import (
        coordinator_origin, require_actor_board, resume_recovered,
    )
    actor = coordinator_origin()
    if actor is None:
        _require_orchestrator_tool("kanban_unblock")
    tid = args.get("task_id")
    _check(tid, "task_id is required")
    tid = str(tid)
    if actor is None:
        _enforce_worker_task_ownership(tid)
    else:
        _check(args.get("board") in (None, actor["board"]),
               "coordinator routing is confined to its authenticated board")
    with _board(args.get("board")) as (kb, conn):
        if actor is not None:
            require_actor_board(conn, actor)
        if "recovery_version" in args:
            return _ok(**resume_recovered(kb, conn, tid, args["recovery_version"],
                                         args.get("recovery_reason")))
        _check("recovery_reason" not in args, "recovery_reason requires recovery_version")
        _check(kb.unblock_task(conn, tid), f"could not unblock {tid} (not blocked or unknown)")
        return _ok(task_id=tid, **_fields(kb.get_task(conn, tid), ("status",)))'''
_VISIBILITY = '''@no_cache_check_fn
def _check_kanban_unblock_mode() -> bool:
    """Routing belongs only to a proven native coordinator or existing orchestrator."""
    if _check_kanban_orchestrator_mode():
        return True
    from hermes_cli.nixhomeserver_resume_recovered import coordinator_origin
    return coordinator_origin() is not None


'''
EDITS = {
    'tools/kanban_tools.py': (
        (_HANDLER, _RECOVERY_HANDLER),
        ('# --- Shared helpers: validation failures raise _Reject; _kanban_handler renders it ---',
         _VISIBILITY + '# --- Shared helpers: validation failures raise _Reject; _kanban_handler renders it ---'),
        ('    _gate = _check_kanban_orchestrator_mode if _name in _ORCHESTRATOR_TOOLS else _check_kanban_mode',
         '    _gate = (_check_kanban_unblock_mode if _name == "kanban_unblock" else\n'
         '             _check_kanban_orchestrator_mode if _name in _ORCHESTRATOR_TOOLS else _check_kanban_mode)'),
    ),
    'tools/kanban_tools_schemas.py': (
        ('        "task_id": _prop("string", "Blocked task id to move to ready or parent-gated todo."),',
         '        "task_id": _prop("string", "Blocked task id to move to ready or parent-gated todo."),\n'
         '        "recovery_version": _prop("string", "Exact 64-hex capability-recovery hold version; only authenticated head-coordinator may resume repaired triage."),\n'
         '        "recovery_reason": _prop("string", "Nonempty verified repair evidence or native comment reference for this exact hold."),'),
        ('        "dispatcher-spawned task workers never see this tool."',
         '        "only an authenticated native head-coordinator worker can route its own board. "\n'
         '        "Ordinary workers cannot unblock siblings. recovery_version plus recovery_reason "\n'
         '        "resumes a repaired technical triage hold once, retaining its gates and budgets."'),
    ),
}


def adapt(name, text):
    for before, after in EDITS[name]:
        if text.count(after) == 1:
            continue
        if text.count(before) != 1:
            raise ValueError('Native recovered-resume source drift; reconcile before installation')
        text = text.replace(before, after, 1)
    compile(text, name, 'exec')
    return text
