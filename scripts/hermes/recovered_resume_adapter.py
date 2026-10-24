"""Pin the native recovery tool seam; reject incompatible upstream sources."""

import ast
import hashlib

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

# Pin both reviewed native function states, including the transaction boundary.
_SPECIFY_HASHES = (
    'ed8da929174eeb91df6d94c773054d1f24f26b77deb1f205eba84c56038918c7',
    'ece60dcb01c3de59830511d9654fd99a41f99f6f75a15843eb0ca220e97d1fef',
)
_SPECIFY_BEFORE = '''            "SELECT title, body, assignee FROM tasks WHERE id = ? AND status = 'triage'",
            (task_id,),
        ).fetchone()
        if existing is None:
            return False
'''
_SPECIFY_AFTER = _SPECIFY_BEFORE.replace(
    'title, body, assignee FROM', 'title, body, assignee, block_kind FROM',
) + '''        if existing["block_kind"] == "capability":
            raise ValueError("Capability-held triage requires exact-version guarded recovery, not specify")
'''

_UNBLOCK_BEFORE = '''def unblock_task(conn: sqlite3.Connection, task_id: str) -> bool:
    """``blocked``/``scheduled`` -> its resumable phase (parent re-gated; ``review``
    when that is where it left off), closing any leaked run first."""
'''
_UNBLOCK_AFTER = _UNBLOCK_BEFORE + '''    from hermes_cli.nixhomeserver_worker_origin import require_ordinary_unblock
    require_ordinary_unblock()
'''

_WAIT_BUDGET_BEFORE = '''        # (the dispatcher's spawn/crash counter) IS reset — a deliberate unblock
        # is a fresh start for the retry budget.
        cur = conn.execute(
            "UPDATE tasks SET status = ?, current_run_id = NULL, "
            "consecutive_failures = 0, last_failure_error = NULL "
            "WHERE id = ? AND status IN ('blocked', 'scheduled')", (new_status, task_id),
'''
_WAIT_BUDGET_AFTER = '''        # (the dispatcher's spawn/crash counter) retains the existing blocked
        # reset semantics. Resuming a scheduled event wait preserves consumed
        # failures and their evidence; waiting does not grant another attempt.
        cur = conn.execute(
            "UPDATE tasks SET status = ?, current_run_id = NULL, "
            "consecutive_failures = CASE WHEN status = 'scheduled' THEN consecutive_failures ELSE 0 END, "
            "last_failure_error = CASE WHEN status = 'scheduled' THEN last_failure_error ELSE NULL END "
            "WHERE id = ? AND status IN ('blocked', 'scheduled')", (new_status, task_id),
'''

_ITERATION_UNBLOCK_BEFORE = '''        _reclaim_dangling_run(
            conn, task_id, statuses=("blocked", "scheduled"), now=now,
'''
_ITERATION_UNBLOCK_AFTER = '''        from hermes_cli.nixhomeserver_resume_recovered import require_iteration_ordinary_unblock
        require_iteration_ordinary_unblock(conn, task_id)
''' + _ITERATION_UNBLOCK_BEFORE

_CLAIM_BEFORE = '''    """CAS ``source_status -> running``, open a run row, emit ``claimed``; None
    when the CAS lost. Caller holds the txn."""
'''
_CLAIM_AFTER = _CLAIM_BEFORE + '''    from hermes_cli.nixhomeserver_resume_recovered import iteration_claim_authority
    try:
        authority = iteration_claim_authority(conn, task_id)
    except ValueError:
        return None
    if authority is not None:
        event_extra = {**(event_extra or {}), "iteration_continuation": authority}
'''

EDITS = {
    'hermes_cli/kanban.py': (
        ('def _cmd_unblock(args: argparse.Namespace) -> int:\n',
         'def _cmd_unblock(args: argparse.Namespace) -> int:\n'
         '    from hermes_cli.nixhomeserver_worker_origin import require_ordinary_unblock\n'
         '    try:\n'
         '        require_ordinary_unblock()\n'
         '    except ValueError as exc:\n'
         '        return _err(str(exc))\n'),
        ('        op = _commented(conn, reason, author, "UNBLOCK", lambda tid: kb.unblock_task(conn, tid))\n',
         '        def op(tid):\n'
         '            changed = kb.unblock_task(conn, tid)\n'
         '            if changed and reason:\n'
         '                kb.add_comment(conn, tid, author, f"UNBLOCK: {reason}")\n'
         '            return changed\n'),
    ),
    'hermes_cli/kanban_db.py': ((_SPECIFY_BEFORE, _SPECIFY_AFTER),
                              (_UNBLOCK_BEFORE, _UNBLOCK_AFTER),
                              (_WAIT_BUDGET_BEFORE, _WAIT_BUDGET_AFTER),
                              (_ITERATION_UNBLOCK_BEFORE, _ITERATION_UNBLOCK_AFTER),
                              (_CLAIM_BEFORE, _CLAIM_AFTER)),
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
         '        "recovery_version": _prop("string", "Exact 64-hex capability-recovery hold version; authenticated head-coordinator resumes repaired parked capability without resetting failures."),\n'
         '        "recovery_reason": _prop("string", "Nonempty verified repair evidence or native comment reference for this exact hold."),'),
        ('        "dispatcher-spawned task workers never see this tool."',
         '        "only an authenticated native head-coordinator worker can route its own board. "\n'
         '        "Ordinary workers cannot unblock siblings. recovery_version plus recovery_reason "\n'
         '        "resumes a repaired parked capability hold once, retaining gates and failure budgets."'),
    ),
}


def migrate_legacy(text):
    for old,new in (
        ('Exact 64-hex capability-recovery hold version; only authenticated head-coordinator may resume repaired triage.',
         'Exact 64-hex capability-recovery hold version; authenticated head-coordinator resumes repaired parked capability without resetting failures.'),
        ('resumes a repaired technical triage hold once, retaining its gates and budgets.',
         'resumes a repaired parked capability hold once, retaining gates and failure budgets.'),
    ):
        text=text.replace(old,new)
    return text


def adapt(name, text):
    if name == 'hermes_cli/kanban_db.py':
        tree=ast.parse(text)
        matches=[node for node in tree.body if isinstance(node,ast.FunctionDef)
                 and node.name == 'specify_triage_task']
        if len(matches) != 1 or hashlib.sha256(
                (ast.get_source_segment(text,matches[0])+'\n').encode()).hexdigest() not in _SPECIFY_HASHES:
            raise ValueError('Native specify source drift; reconcile before installation')
        unblock=[node for node in tree.body if isinstance(node,ast.FunctionDef)
                 and node.name == 'unblock_task']
        original=(ast.get_source_segment(text,unblock[0])+'\n'
                  if len(unblock) == 1 else '')
        original=original.replace(_UNBLOCK_AFTER,_UNBLOCK_BEFORE)
        original=original.replace(_WAIT_BUDGET_AFTER,_WAIT_BUDGET_BEFORE)
        original=original.replace(_ITERATION_UNBLOCK_AFTER,_ITERATION_UNBLOCK_BEFORE)
        # The reviewed parallel-dispatch guard belongs only to ordinary
        # unblock. Qualify its one exact insertion without accepting any other
        # native-body drift or changing guarded recovery's release policy.
        release = '        worker_policy.require_release(conn, task_id)\n'
        original = original.replace(release +
            '        from hermes_cli.nixhomeserver_board_progress import require_resume\n'
            '        require_resume(conn, task_id)\n', release)
        if hashlib.sha256(original.encode()).hexdigest() != 'fa1d9541f09631fa990c4222bc712ac305d0271a70ecc733f7b591e151e8cd81':
            raise ValueError('Native ordinary unblock source drift; reconcile before installation')
        claim=[node for node in tree.body if isinstance(node,ast.FunctionDef) and node.name=='_claim_and_open_run']
        original=(ast.get_source_segment(text,claim[0])+'\n' if len(claim)==1 else '')
        original=original.replace(_CLAIM_AFTER,_CLAIM_BEFORE)
        if hashlib.sha256(original.encode()).hexdigest()!='7cda44d4d77d7ecb592a1cc4762c14a19cdc7a9992373dd6a63c261fc9ffb37e':
            raise ValueError('Native run-claim source drift; reconcile before installation')
    text=migrate_legacy(text)
    for before, after in EDITS[name]:
        if text.count(after) == 1:
            continue
        if text.count(before) != 1:
            raise ValueError('Native recovered-resume source drift; reconcile before installation')
        text = text.replace(before, after, 1)
    compile(text, name, 'exec')
    return text
