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
    'kanban_db_dispatch.py': (
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
