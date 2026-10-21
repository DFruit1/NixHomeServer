#!/usr/bin/env python3
"""Check native tool handoffs without changing board state.

Python operations glue uses the installed pre-tool hook and read-only board DB;
no upstream Hermes patch, new service or publication contract is needed.
"""
from contextlib import closing
import json
import os
from pathlib import Path
import re
import sqlite3
import sys


def verification(task):
    return task['assignee'] == 'feature-reviewer' and task['tenant'] not in {'continuous-improvement', 'review-question'}


def validate(metadata):
    if not isinstance(metadata, dict) or metadata.get('verdict') not in {'accept', 'request-changes'}:
        raise ValueError('Set metadata.verdict to accept or request-changes, in lowercase')
    if not isinstance(metadata.get('revision'), str) or not metadata['revision'].strip():
        raise ValueError('Name the exact reviewed source revision in metadata.revision')
    checks = metadata.get('checks')
    if not isinstance(checks, list) or not checks:
        raise ValueError('Record executed checks with command and integer exit_code')
    for check in checks:
        if not isinstance(check, dict) or not isinstance(check.get('command'), str) or not check['command'].strip() or type(check.get('exit_code')) is not int:
            raise ValueError('Every check needs a command and actual integer exit_code')
        if metadata['verdict'] == 'accept' and check['exit_code'] != 0:
            raise ValueError('A failing check cannot support acceptance; request changes or resolve it')
    if metadata['verdict'] == 'request-changes':
        fixes = metadata.get('requested_changes')
        if not isinstance(fixes, list) or not fixes or any(not isinstance(f, str) or not f.strip() for f in fixes):
            raise ValueError('List concrete fixes in metadata.requested_changes')


def _latest_review_state(db, review_id):
    """(parent row, latest completed verifier run) for a feature-reviewer card.

    Only a completed run carries a verdict. Anchoring on the latest attempt of
    any status would let an interrupted (blocked) attempt move the supersession
    window past an acceptance that already landed, so the query filters the way
    _accepted_verdict() does.
    """
    parent = db.execute('SELECT id,status,assignee,tenant,created_at FROM tasks WHERE id=?',
                        (review_id,)).fetchone()
    if parent is None:
        return None, None
    run = db.execute("SELECT profile,status,outcome,metadata,ended_at FROM task_runs"
                     " WHERE task_id=? AND profile='feature-reviewer'"
                     " AND status='done' AND outcome='completed'"
                     ' ORDER BY ended_at DESC, id DESC LIMIT 1', (review_id,)).fetchone()
    return parent, run


def _accepted_verdict(run):
    if not run or run['profile'] != 'feature-reviewer' or run['status'] != 'done' \
            or run['outcome'] != 'completed':
        return False
    try:
        return json.loads(run['metadata'] or '{}').get('verdict') == 'accept'
    except (ValueError, AttributeError):
        return False


def guard_unlink(payload, root):
    """Check a kanban_unlink without changing board state.

    Unlinking an ordinary prerequisite stays worker-service (the native tool's
    own contract). A feature-reviewer parent edge is different: it is the
    child's review gate. Retiring one while its verdict still stands would
    let the child complete unreviewed, so the unlink must carry its own
    evidence: an accepted verdict on the same review, or a newer accepted
    review generation, or a child that is already done/archived.
    """
    args = payload.get('tool_input') or {}
    board = args.get('board') or os.environ.get('HERMES_KANBAN_BOARD')
    child_id = args.get('child_id')
    if not isinstance(board, str) or not re.fullmatch(r'[A-Za-z0-9_-]+', board) \
            or not isinstance(child_id, str) or not re.fullmatch(r't_[A-Za-z0-9_]+', child_id):
        raise ValueError('Provide the exact board, parent_id and child_id for the unlink check')
    parent_id = args.get('parent_id')
    if not isinstance(parent_id, str) or not re.fullmatch(r't_[A-Za-z0-9_]+', parent_id):
        raise ValueError('Provide the exact parent_id for the unlink check')
    path = root / 'kanban/boards' / board / 'kanban.db'
    with closing(sqlite3.connect(path.resolve().as_uri() + '?mode=ro', uri=True, timeout=5)) as db:
        db.row_factory = sqlite3.Row
        db.execute('PRAGMA query_only=ON')
        child = db.execute('SELECT status FROM tasks WHERE id=?', (child_id,)).fetchone()
        if child is None:
            raise ValueError('Unknown child task; do not unlink from an unknown card')
        if child['status'] in ('done', 'archived'):
            return {}
        parent, run = _latest_review_state(db, parent_id)
        if parent is None or not verification(parent):
            return {}
        if run is None:
            raise ValueError(f'Review {parent_id} has no completed verifier run;'
                             ' its gate cannot be retired by unlink')
        if _accepted_verdict(run):
            return {}
        # Any completed acceptance in the window releases the gate: a later
        # request-changes elsewhere must not shadow a real acceptance.
        newer = db.execute(
            "SELECT r.metadata, r.profile, r.status, r.outcome FROM task_runs r"
            " JOIN tasks t ON t.id = r.task_id"
            " WHERE t.id != ? AND t.assignee = 'feature-reviewer'"
            " AND t.status != 'archived'"
            " AND r.profile = 'feature-reviewer'"
            " AND r.status = 'done' AND r.outcome = 'completed'"
            ' AND r.ended_at IS NOT NULL AND r.ended_at > ?'
            ' ORDER BY r.ended_at DESC',
            (parent_id, run['ended_at'] or 0)).fetchall()
        if any(_accepted_verdict(candidate) for candidate in newer):
            return {}
        raise ValueError(
            f'Review {parent_id} requested changes, so this link is the live review'
            f' gate for {child_id}: unlinking it now would let the card complete'
            ' unreviewed. Link a fresh review card as a second parent and let it'
            f' accept first; then retiring {parent_id} is bookkeeping. If the work'
            ' is superseded outright, the coordinator closes it with evidence')


def guard(payload, root):
    """Fail-closed dispatch: any guard error blocks the handoff it guards."""
    tool = payload.get('tool_name')
    if tool not in ('kanban_complete', 'kanban_unlink'):
        return {}
    try:
        if tool == 'kanban_unlink':
            return guard_unlink(payload, root)
        return guard_complete(payload, root)
    except (ValueError, TypeError, OSError, sqlite3.Error) as exc:
        return {'action': 'block',
                'message': f'{tool} refused by the review-verdict guard: {exc}.'
                           ' Keep the handoff open; never treat done as'
                           ' acceptance or bypass this guard with the CLI.'}
def guard_complete(payload, root):
    """The kanban_complete check: verdict contracts and review-gate parents."""
    args = payload.get('tool_input') or {}
    board = args.get('board') or os.environ.get('HERMES_KANBAN_BOARD')
    task_id = args.get('task_id') or os.environ.get('HERMES_KANBAN_TASK')
    if not isinstance(board, str) or not re.fullmatch(r'[A-Za-z0-9_-]+', board) or not isinstance(task_id, str) or not re.fullmatch(r't_[A-Za-z0-9_]+', task_id):
        raise ValueError('Provide the exact board and task_id for the completion check')
    path = root / 'kanban/boards' / board / 'kanban.db'
    with closing(sqlite3.connect(path.resolve().as_uri() + '?mode=ro', uri=True, timeout=5)) as db:
        db.row_factory = sqlite3.Row
        db.execute('PRAGMA query_only=ON')
        db.execute('BEGIN')
        task = db.execute('SELECT id,status,assignee,tenant FROM tasks WHERE id=?', (task_id,)).fetchone()
        if task is None:
            raise ValueError('Unknown task; do not infer review acceptance')
        metadata = args.get('metadata')
        if verification(task):
            validate(metadata)
            if metadata['verdict'] == 'request-changes':
                claim = db.execute("SELECT payload FROM task_events WHERE task_id=? AND kind='claimed' ORDER BY id DESC LIMIT 1", (task_id,)).fetchone()
                provenance = json.loads(claim['payload'] or '{}') if claim else {}
                if task['status'] == 'review' or provenance.get('source_status') == 'review':
                    raise ValueError('Native review rejection uses kanban_request_changes, not completion')
                children = db.execute("SELECT c.assignee FROM task_links l JOIN tasks c ON c.id=l.child_id WHERE l.parent_id=? AND c.status NOT IN ('done','archived')", (task_id,)).fetchall()
                if any(c['assignee'] != 'head-coordinator' for c in children):
                    raise ValueError('Rejection would release non-coordinator work; ask the coordinator to repair those dependencies first')
        parents = db.execute('SELECT p.id,p.status,p.assignee,p.tenant FROM task_links l JOIN tasks p ON p.id=l.parent_id WHERE l.child_id=?', (task_id,)).fetchall()
        for parent in parents:
            if not verification(parent):
                continue
            if parent['status'] != 'done':
                raise ValueError(f"Review {parent['id']} is not complete")
            run = db.execute("SELECT profile,status,outcome,metadata FROM task_runs WHERE task_id=? ORDER BY id DESC LIMIT 1", (parent['id'],)).fetchone()
            if not run or run['profile'] != 'feature-reviewer' or run['status'] != 'done' or run['outcome'] != 'completed':
                raise ValueError(f"Latest run for review {parent['id']} is not a completed verifier run")
            evidence = json.loads(run['metadata'] or '{}') if run else {}
            validate(evidence)
            if evidence['verdict'] != 'accept':
                raise ValueError(
                    f"Review {parent['id']} requested changes. The review gate"
                    ' is live: complete only after an accepted review of the'
                    ' current revision is linked as a parent. Self-service:'
                    ' kanban_link a fresh review card as a parent (a review'
                    ' card that depends on this card can never run), let it'
                    f' accept, then kanban_unlink the superseded {parent["id"]}'
                    ' edge and complete. Coordinator routes: the same relink,'
                    ' or close this card as superseded with evidence')
    return {}


if __name__ == '__main__':
    try:
        root = Path(os.environ.get('HERMES_ROOT', str(Path.home() / '.hermes'))).resolve()
        print(json.dumps(guard(json.load(sys.stdin), root)))
    except (ValueError, TypeError, AttributeError, OSError) as exc:
        print(json.dumps({'action': 'block', 'message': f'Review guard failed closed: {exc}'}))
