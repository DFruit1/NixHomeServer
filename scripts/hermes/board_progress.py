#!/usr/bin/env python3
"""Read-only low-activity evidence for fleet and steward supervision.

Python scheduler glue reuses the existing SQLite boards and native coordinator
lane. It proposes inspection targets, never declares a gated task ready.
"""
from contextlib import closing
import hashlib
import json
import os
from pathlib import Path
import sqlite3
import time

MONITORS = {'fleet-supervisor', 'deadlock-recovery-monitor', 'aging-escalation', 'cron-loop-monitor'}


def collect(root, board=None):
    packets = []
    for manifest in sorted((root / 'kanban/boards').glob('*/board.json')):
        if manifest.parent.name.startswith(('_', '.')):
            continue
        if board is not None and manifest.parent.name != board:
            continue
        path = manifest.with_name('kanban.db')
        with closing(sqlite3.connect(path.resolve().as_uri() + '?mode=ro', uri=True, timeout=1)) as db:
            db.row_factory = sqlite3.Row
            db.execute('PRAGMA query_only=ON')
            db.execute('BEGIN')
            deadline = time.monotonic() + 2
            db.set_progress_handler(lambda: int(time.monotonic() > deadline), 1000)
            if not db.execute("SELECT 1 FROM tasks WHERE status NOT IN ('done','archived','cancelled') LIMIT 1").fetchone():
                continue
            rows = [dict(row) for row in db.execute(
                "SELECT id,title,body,status,assignee,priority,tenant,created_by,block_kind FROM tasks "
                "WHERE status NOT IN ('done','archived','cancelled') ORDER BY priority DESC,id LIMIT 1001")]
            if len(rows) > 1000:
                raise ValueError('Board progress inspection exceeds 1000 open cards')
            # A supervision worker cannot make its own board appear productive.
            rows = [row for row in rows if row['tenant'] != 'board-progress']
            active = sum(row['status'] in ('ready', 'running') and row['tenant'] != 'technical-recovery'
                         and row['created_by'] not in MONITORS for row in rows)
            pending = [row for row in rows if row['status'] not in ('ready', 'running')]
            if active > 1 or not pending:
                continue
            links = [list(row) for row in db.execute(
                "SELECT l.parent_id,l.child_id,p.status FROM task_links l JOIN tasks p ON p.id=l.parent_id "
                "JOIN tasks c ON c.id=l.child_id WHERE c.status NOT IN ('done','archived','cancelled') "
                "AND p.status NOT IN ('done','archived','cancelled') ORDER BY l.child_id,l.parent_id LIMIT 4001")]
            if len(links) > 4000:
                raise ValueError('Board progress dependency bound exceeded')
        # Hash material source/graph state, excluding heartbeats, comments, age
        # and our own supervision cards. Unchanged ticks cannot mint new work.
        ids = {row['id'] for row in rows}
        links = [link for link in links if link[0] in ids and link[1] in ids]
        version = hashlib.sha256(json.dumps([rows, links], sort_keys=True).encode()).hexdigest()
        candidates = []
        for row in pending:
            waiting = [parent for parent, child, _ in links if child == row['id']]
            candidates.append(dict(id=row['id'], title=row['title'][:180], status=row['status'],
                assignee=row['assignee'], block_kind=row['block_kind'], waiting_on=waiting,
                scope=(row['body'] or '')[:350]))
        # Show both ungated work and blocked chains; priority alone can hide all
        # independent work behind one high-priority recovery incident.
        candidates.sort(key=lambda row: (bool(row['waiting_on']), row['status'] != 'todo'))
        # Include parent feature scope as well as recovery roots: a board whose
        # executable cards are all gated may still have a disjoint requested slice.
        scopes = [row for row in candidates if row['title'].startswith('[FEATURE TRACKER')][:2]
        selected = candidates[:8-len(scopes)]
        selected += [row for row in scopes if row not in selected]
        selected += [row for row in candidates if row not in selected][:8-len(selected)]
        packets.append(dict(board=manifest.parent.name, version=version, ready_running=active,
                            candidates=selected, omitted_candidates=max(0, len(candidates)-len(selected))))
    return packets


def monitor_lines(root):
    return ['LOW_ACTIVITY ' + json.dumps(packet, sort_keys=True) for packet in collect(root)]


if __name__ == '__main__':
    root = Path(os.environ.get('HERMES_ROOT', str(Path.home() / '.hermes')))
    for packet in collect(root, os.environ.get('HERMES_BOARD')):
        print(json.dumps(packet, sort_keys=True))
