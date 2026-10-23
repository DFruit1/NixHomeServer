"""Version-checked integration points for the installed native Hermes lifecycle.

Upstream currently has no pre-dispatch policy hook. Keep this adapter small,
explicit and fail closed on source drift; never replace an entire native file.
"""

EDITS = {
    'kanban_db.py': (
        ('    assignee = _canonical_assignee(assignee)\n    if not title',
         '    assignee = _canonical_assignee(assignee)\n'
         '    from hermes_cli import nixhomeserver_worker_policy as worker_policy\n'
         '    max_retries = worker_policy.creation(assignee, body, max_runtime_seconds, max_retries)\n'
         '    if not title'),
        ('    with write_txn(conn):\n        resume_status = (',
         '    with write_txn(conn):\n'
         '        from hermes_cli import nixhomeserver_worker_policy as worker_policy\n'
         '        worker_policy.require_release(conn, task_id)\n'
         '        resume_status = ('),
    ),
    'tools/kanban_tools.py': (
        ('    parents = _coerce_str_list(args.get("parents") or [], "parents", "task ids")\n'
         '    with _board(args.get("board")) as (kb, conn):\n'
         '        from gateway.session_context import get_session_env\n',
         '    parents = _coerce_str_list(args.get("parents") or [], "parents", "task ids")\n'
         '    # Name the board before any board file is opened, created or written.\n'
         '    from hermes_cli.nixhomeserver_create_board import require_explicit_board\n'
         '    board = require_explicit_board(args.get("board"))\n'
         '    with _board(board) as (kb, conn):\n'
         '        from gateway.session_context import get_session_env\n'),
        ('            board=args.get("board"),\n',
         '            board=board,\n'),
    ),
    'tools/kanban_tools_schemas.py': (
        ('_DESC_BOARD = (\n'
         '    "Kanban board slug to target. When omitted, the call resolves the "\n'
         '    "active board the usual way: HERMES_KANBAN_DB env → "\n'
         '    "HERMES_KANBAN_BOARD env → the \'current\' symlink under the kanban "\n'
         '    "home → \'default\'. Pass an explicit slug only when the caller (e.g. "\n'
         '    "a Telegram routing layer) needs to override the env-pinned active "\n'
         '    "board for this one call."\n',
         '_DESC_BOARD = (\n'
         '    "Kanban board slug to target. kanban_create requires it explicitly: "\n'
         '    "name the board the card belongs on. Every other tool resolves the "\n'
         '    "active board when the caller omits it: HERMES_KANBAN_DB env → "\n'
         '    "HERMES_KANBAN_BOARD env → the \'current\' symlink under the kanban "\n'
         '    "home → \'default\'. A dispatched worker stays pinned to the board "\n'
         '    "its card was claimed from."\n'),
        ('    ["title", "assignee"],\n)',
         '    ["title", "assignee", "board"],\n)'),
    ),
    'kanban_db_dispatch.py': (
        ('        claimed.skills = list(dict.fromkeys([*(claimed.skills or []), "sdlc-review"]))\n',
         '        claimed.skills = list(dict.fromkeys([*worker_policy.execution_skills(\n'
         '            conn, task_id, assignee, claimed.skills), "sdlc-review"]))\n'),
        ('        if check_respawn_guard(conn, row["id"], lane="review") is None:\n',
         '        # Reserve capacity only for reviews the dispatch policy admits.\n'
         '        from hermes_cli import nixhomeserver_worker_policy as worker_policy\n'
         '        if worker_policy.reason(conn, row["id"], assignee) is not None:\n'
         '            continue\n'
         '        if check_respawn_guard(conn, row["id"], lane="review") is None:\n'),
        ('    # Per-profile cap: one profile\'s local model / API quota / browser pool\n',
         '    from hermes_cli import nixhomeserver_worker_policy as worker_policy\n'
         '    policy_reason = worker_policy.reason(conn, task_id, assignee)\n'
         '    if policy_reason is not None:\n'
         '        result.respawn_guarded.append((task_id, "worker_policy"))\n'
         '        if not dry_run:\n'
         '            _kb.block_task(conn, task_id, reason=policy_reason, kind="capability")\n'
         '        return False\n'
         '    # Per-profile cap: one profile\'s local model / API quota / browser pool\n'),
        ('    if claimed is None:\n        return False\n    try:\n        resolved_branch_name = None\n',
         '    if claimed is None:\n        return False\n'
         '    # Check the claimed snapshot too: an edit can race pre-claim validation.\n'
         '    policy_reason = worker_policy.assignment_reason(assignee, claimed.body,\n'
         '        claimed.max_runtime_seconds, claimed.max_retries)\n'
         '    if policy_reason is not None:\n'
         '        _kb.block_task(conn, task_id, reason=policy_reason, kind="capability")\n'
         '        result.respawn_guarded.append((task_id, "worker_policy"))\n'
         '        return False\n'
         '    try:\n        resolved_branch_name = None\n'),
        ('    try:\n        pid = _call_spawn_fn(',
         '    try:\n'
         '        # Validate skills at the actual prepared workspace, inside native cleanup.\n'
         '        policy_reason = worker_policy.reason(conn, task_id, assignee)\n'
         '        if policy_reason is not None:\n'
         '            _kb.block_task(conn, task_id, reason=policy_reason, kind="capability")\n'
         '            result.respawn_guarded.append((task_id, "worker_policy"))\n'
         '            return False\n'
         '        pid = _call_spawn_fn('),
    ),
}


def adapt(name, text):
    for before, after in EDITS[name]:
        if text.count(after) == 1:
            continue
        if text.count(before) != 1:
            raise ValueError('Native worker adapter source drift; reconcile before installation')
        text = text.replace(before, after, 1)
    compile(text, name, 'exec')
    return text
