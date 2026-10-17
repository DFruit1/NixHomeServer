#!/usr/bin/env python3
"""Report and repair open Kanban cards held only by dead prerequisites.

Dry-run is read-only. Applying uses Hermes' native link API so lifecycle events,
write fences, and ready-state recomputation retain their normal semantics.
"""
import argparse
from contextlib import closing
import json
import os
from pathlib import Path
import re
import sqlite3
import sys


MAX_TASKS, MAX_LINKS = 5000, 25000


def board_path(root, board):
    if board == 'default':
        return root / 'kanban.db'
    if not re.fullmatch(r'[A-Za-z0-9_-]+', board):
        raise ValueError('Invalid board slug')
    return root / 'kanban/boards' / board / 'kanban.db'


def plan(root, board):
    path = board_path(root, board)
    with closing(sqlite3.connect(path.resolve().as_uri() + '?mode=ro', uri=True, timeout=2)) as db:
        db.execute('PRAGMA query_only=ON')
        db.execute('BEGIN')
        task_rows = db.execute(
            'SELECT id,status FROM tasks ORDER BY id LIMIT ?', (MAX_TASKS + 1,)).fetchall()
        edges = db.execute(
            'SELECT parent_id,child_id FROM task_links ORDER BY child_id,parent_id LIMIT ?',
            (MAX_LINKS + 1,)).fetchall()
        if len(task_rows) > MAX_TASKS or len(edges) > MAX_LINKS:
            raise ValueError('Board exceeds prerequisite repair bounds')
    tasks = dict(task_rows)
    parents = {}
    for parent, child in edges:
        parents.setdefault(child, []).append(parent)
    candidates = []
    for child, child_status in sorted(tasks.items()):
        if child_status in ('done', 'archived'):
            continue
        child_parents = parents.get(child, [])
        if not child_parents:
            continue
        open_parents = [p for p in child_parents if tasks.get(p) not in (None, 'done', 'archived')]
        if not open_parents and any(tasks.get(p) != 'done' for p in child_parents):
            candidates.append({'task_id': child, 'parents': child_parents})
    return {'board': board, 'candidates': candidates}


def native_api():
    """Load the installed Hermes board API from its managed virtualenv."""
    repo = Path(os.environ.get('HERMES_REPO', str(Path.home() / '.hermes/hermes-agent')))
    python = repo / '.venv/bin/python'
    if not python.is_file():
        raise RuntimeError(f'Hermes managed Python environment not found under {repo}')
    sys.path.insert(0, str(repo))
    site_packages = repo / '.venv/lib'
    for candidate in sorted(site_packages.glob('python*/site-packages')):
        sys.path.insert(0, str(candidate))
    import hermes_bootstrap  # noqa: F401
    from hermes_cli import kanban_db as kb
    from hermes_cli.kanban_db_connect import connect
    return kb, connect


def apply(root, board, profile=None):
    profile = profile if profile is not None else os.environ.get('HERMES_PROFILE', '')
    if profile != 'head-coordinator':
        raise PermissionError('--apply requires HERMES_PROFILE=head-coordinator')
    candidates = plan(root, board)['candidates']
    if not candidates:
        return []
    kb, connect = native_api()
    path = board_path(root, board)
    released = []
    with closing(connect(path)) as conn:
        for candidate in candidates:
            child = candidate['task_id']
            # Re-read under the native write path just before each mutation. Do
            # not unlink any edge if a live parent now exists.
            child_row = conn.execute('SELECT status FROM tasks WHERE id=?', (child,)).fetchone()
            if child_row is None or child_row['status'] in ('done', 'archived'):
                continue
            rows = conn.execute(
                'SELECT l.parent_id,p.status FROM task_links l '
                'LEFT JOIN tasks p ON p.id=l.parent_id WHERE l.child_id=? ORDER BY l.parent_id',
                (child,)).fetchall()
            if any(row['status'] not in (None, 'done', 'archived') for row in rows):
                continue
            dead = [row['parent_id'] for row in rows if row['status'] != 'done']
            removed = []
            for parent in dead:
                if kb.unlink_tasks(conn, parent, child):
                    removed.append(parent)
            remaining = conn.execute(
                'SELECT 1 FROM task_links l JOIN tasks p ON p.id=l.parent_id '
                "WHERE l.child_id=? AND p.status NOT IN ('done','archived') LIMIT 1",
                (child,)).fetchone()
            if removed and remaining is None:
                released.append({'task_id': child, 'parents': removed})
    return released


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--board', default=os.environ.get('HERMES_KANBAN_BOARD', 'default'))
    parser.add_argument('--root', type=Path,
                        default=Path(os.environ.get('HERMES_ROOT', str(Path.home() / '.hermes'))))
    parser.add_argument('--apply', action='store_true', help='Unlink dead prerequisite edges.')
    args = parser.parse_args(argv)
    try:
        if args.apply:
            result = {'board': args.board, 'released': apply(args.root, args.board)}
        else:
            result = plan(args.root, args.board)
    except (OSError, sqlite3.Error, ValueError, PermissionError, RuntimeError) as exc:
        parser.error(str(exc))
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
