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


def guard(payload, root):
    if payload.get('tool_name') != 'kanban_complete':
        return {}
    try:
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
                    raise ValueError(f"Review {parent['id']} requested changes; link fixes and a fresh accepted review, then retire the superseded dependency with evidence")
        return {}
    except (ValueError, TypeError, OSError, sqlite3.Error) as exc:
        return {'action': 'block', 'message': f'Review completion refused: {exc}. Keep the handoff open; never treat done as acceptance or bypass this guard with the CLI.'}


if __name__ == '__main__':
    try:
        root = Path(os.environ.get('HERMES_ROOT', str(Path.home() / '.hermes'))).resolve()
        print(json.dumps(guard(json.load(sys.stdin), root)))
    except (ValueError, TypeError, AttributeError, OSError) as exc:
        print(json.dumps({'action': 'block', 'message': f'Review guard failed closed: {exc}'}))
