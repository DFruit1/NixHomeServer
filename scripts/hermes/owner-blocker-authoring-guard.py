#!/usr/bin/env python3
"""Check owner-gate authorship before native Hermes writes, using existing hooks.

Standard-library operations glue; technical blockers and ordinary comments
remain available to their workers. The shared account is a workflow boundary.
"""
import importlib.util
from contextlib import closing
import json
import os
from pathlib import Path
import re
import sqlite3
import sys

PROFILE = 'head-coordinator'


def guard(payload, root, alerts):
    tool = payload.get('tool_name')
    args = payload.get('tool_input') or {}
    body = str(args.get('body') or '')
    if tool == 'kanban_block' and args.get('kind') == 'dependency':
        # Hermes turns a dependency block with no open parent into needs_input.
        # Do not let that fallback manufacture an owner question from evidence
        # missing at the coordinator. A real prerequisite must be linked first.
        board = args.get('board') or os.environ.get('HERMES_KANBAN_BOARD')
        task_id = args.get('task_id') or os.environ.get('HERMES_KANBAN_TASK')
        try:
            if not isinstance(board, str) or not re.fullmatch(r'[A-Za-z0-9_-]+', board) or not task_id:
                raise ValueError('Provide explicit board/task identifiers for the dependency check')
            path = root / 'kanban/boards' / board / 'kanban.db'
            with closing(sqlite3.connect(path.resolve().as_uri() + '?mode=ro', uri=True)) as db:
                db.execute('PRAGMA query_only=ON')
                parent = db.execute("SELECT 1 FROM task_links l JOIN tasks p ON p.id=l.parent_id "
                                    "WHERE l.child_id=? AND p.status NOT IN ('done','archived') LIMIT 1",
                                    (task_id,)).fetchone()
            if not parent:
                raise ValueError('No open prerequisite is linked; Hermes would turn this into needs_input')
        except (ValueError, OSError, sqlite3.Error) as exc:
            return {'action': 'block', 'message':
                    f'Dependency block was not written: {exc}. Record the evidence gap '
                    'and ask the coordinator to link its actual prerequisite; do not ask the owner.'}
    fields = bool(re.search(r'^Blocking:', body, re.M)
                  and re.search(r'^(?:Why owner|Unblock):', body, re.M))
    owner_create = tool == 'kanban_create' and (fields or bool(re.search(r'^\s*ASK:|^Hard Blocker\b', body, re.M | re.I)))
    owner_block = tool == 'kanban_block' and args.get('kind') == 'needs_input'
    owner_comment = tool == 'kanban_comment' and fields
    if not (owner_create or owner_block or owner_comment):
        return {}
    if payload.get('profile') != PROFILE:
        return {'action': 'block', 'message':
                'Only head-coordinator authors owner-facing blockers. Report technical '
                'evidence to the coordinator and use a technical block or a linked '
                'prerequisite. Do not turn missing evidence into an owner decision.'}
    try:
        board = args.get('board')
        if not isinstance(board, str) or not re.fullmatch(r'[A-Za-z0-9_-]+', board):
            raise ValueError('Provide the explicit board for an owner-facing write')
        if owner_create:
            if len(body) > 1000 or len(body.splitlines()) > 15 or any(len(line) > 90 for line in body.splitlines()):
                raise ValueError('Owner gate body must fit 15 lines, 1000 characters and 90 per line')
            task = {'title': args.get('title') or 'Owner gate', 'body': body,
                    'created_by': PROFILE, 'comment': '', 'reason': ''}
        elif owner_comment:
            alerts.check_summary(body)
            task = {'title': 'Owner gate', 'body': '', 'comment': body, 'reason': ''}
        else:
            task_id = args.get('task_id')
            if not isinstance(task_id, str) or not re.fullmatch(r't_[A-Za-z0-9_]+', task_id):
                raise ValueError('Provide the exact task_id for an owner block')
            tasks = alerts.snapshot(root / 'kanban/boards' / board / 'board.json', task_id)
            if not tasks:
                raise ValueError('Unknown owner-gate task')
            task = {**tasks[0], 'reason': str(args.get('reason') or '')}
        shown, complete = alerts.decision_text('preview', board, task)
        if not complete:
            raise ValueError(shown.splitlines()[-1])
        return {}
    except (ValueError, OSError, sqlite3.Error) as exc:
        return {'action': 'block', 'message':
                f'Owner blocker was not published: {exc}. Write checked Blocking:, '
                'Why owner: and Unblock: lines with the concrete problem, specific '
                'owner-only wall and exact recommended action, then retry.'}


if __name__ == '__main__':
    try:
        spec = importlib.util.spec_from_file_location('owner_alerts', Path(__file__).with_name('kanban-owner-alerts.py'))
        alerts = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(alerts)
        root = Path(os.environ.get('HERMES_ROOT', str(Path.home() / '.hermes')))
        print(json.dumps(guard(json.load(sys.stdin), root, alerts)))
    except (ValueError, TypeError, AttributeError, OSError) as exc:
        print(json.dumps({'action': 'block', 'message': f'Owner authoring check failed closed: {exc}'}))
