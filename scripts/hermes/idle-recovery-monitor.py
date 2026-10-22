#!/usr/bin/env python3
"""Stable read-only digest for the existing idle recovery job.

Python glue reuses Hermes monitor change detection. No model, writes, dispatch,
private source reads or new scheduling state. Heartbeats and routine coordinator comments
never change the digest; completed-source receipts and owner answers do.
"""
from contextlib import closing
import hashlib
import json
import os
from pathlib import Path
import sqlite3
import sys


def digest(rows):
    return hashlib.sha256(json.dumps(rows, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


def snapshot(root):
    boards = sorted(p for p in (root / 'kanban/boards').glob('*/board.json') if not p.parent.name.startswith(('_', '.')))
    if not boards:
        raise ValueError('No active board manifests; cannot establish idle state')
    summaries = []
    busy = False
    for board in boards:
        path = board.with_name('kanban.db')
        with closing(sqlite3.connect(path.resolve().as_uri() + '?mode=ro', uri=True, timeout=5)) as db:
            db.execute('PRAGMA query_only=ON')
            busy |= bool(db.execute("SELECT 1 FROM tasks WHERE status='running' LIMIT 1").fetchone())
            tasks = db.execute("SELECT id,status,assignee,tenant,priority,block_kind,body,result FROM tasks WHERE status!='archived' ORDER BY id").fetchall()
            links = db.execute('SELECT parent_id,child_id FROM task_links ORDER BY parent_id,child_id').fetchall()
            # Owner replies can supply new authority without changing task state.
            comments = db.execute("SELECT c.id,c.task_id,c.author,c.body FROM task_comments c JOIN tasks t ON t.id=c.task_id WHERE c.author!='head-coordinator' OR t.status='done' ORDER BY c.id").fetchall()
            runs = db.execute("SELECT task_id,id,status,outcome,metadata FROM task_runs WHERE id IN (SELECT MAX(id) FROM task_runs GROUP BY task_id) ORDER BY task_id").fetchall()
            summaries.append((board.parent.name, digest([tasks, links, comments, runs])))
    # Running work may change continuously. Only its end should wake recovery.
    if busy:
        return 'BUSY: existing global-idle recovery rule applies'
    return '\n'.join(f'IDLE {name} {checksum}' for name, checksum in summaries)


if __name__ == '__main__':
    try:
        print(snapshot(Path(os.environ.get('HERMES_ROOT', str(Path.home() / '.hermes')))))
    except (OSError, ValueError, sqlite3.Error) as exc:
        print(f'IDLE_RECOVERY_MONITOR_ERROR: {exc}', file=sys.stderr)
        sys.exit(2)
