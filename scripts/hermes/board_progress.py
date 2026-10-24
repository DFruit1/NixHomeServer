#!/usr/bin/env python3
"""Bounded, read-only dispatch evidence and native supervision completion checks.

Python operations glue reuses Hermes' SQLite lifecycle; no backend, new
runtime dependency, task transition or permission is introduced here.
"""
from contextlib import closing
import hashlib
import json
import os
from pathlib import Path
import re
import sqlite3
import time

MONITORS = {'fleet-supervisor', 'board-progress-monitor', 'deadlock-recovery-monitor',
            'aging-escalation', 'cron-loop-monitor'}
RUNNING = {'running', 'in_progress'}
DELEGATE_ROLES = {'standard-implementer', 'local-implementer', 'feature-reviewer', 'project-auditor'}
POLICY = 'Dispatch policy: parallel-v1'
WAIT = 'Dispatch wait: '


def bounded(db, sql, parameters=(), limit=1000):
    rows = db.execute(sql + ' LIMIT ?', (*parameters, limit + 1)).fetchall()
    if len(rows) > limit:
        raise ValueError('Board progress evidence exceeds its read bound')
    return [dict(row) for row in rows]


def productive(task):
    return (task['tenant'] not in {'technical-recovery', 'board-progress'}
            and task['created_by'] not in MONITORS
            and not task['title'].startswith('[FEATURE TRACKER'))


def starts(db, task_ids, *, since=0, current=False):
    """A native claim alone is insufficient: bind an actual spawn to its run."""
    if not task_ids:
        return []
    marks = ','.join('?' for _ in task_ids)
    live = ("AND t.status IN ('running','in_progress') AND r.status='running' "
            'AND r.id=t.current_run_id AND r.outcome IS NULL ' if current else '')
    rows = bounded(db,
        'SELECT r.id AS run_id,r.task_id,r.profile,r.started_at,r.status,r.outcome,r.ended_at,'
        'e.kind,e.created_at AS spawned_at,e.payload,t.tenant,t.created_by,t.title,'
        't.current_run_id,t.status AS task_status FROM task_runs r '
        'JOIN task_events e ON e.run_id=r.id AND e.task_id=r.task_id '
        'JOIN tasks t ON t.id=r.task_id '
        f'WHERE r.task_id IN ({marks}) AND r.started_at>=? '
        "AND e.kind IN ('spawned','worker_registered') AND e.created_at>=r.started_at "
        + live + 'ORDER BY r.id,e.id', (*task_ids, since), limit=4000)
    result = {}
    for row in rows:
        if not productive(row) or row['profile'] not in DELEGATE_ROLES:
            continue
        if current and (row['task_status'] not in RUNNING or row['status'] != 'running'
                        or row['current_run_id'] != row['run_id'] or row['outcome'] is not None):
            continue
        try:
            payload = json.loads(row['payload'] or '{}')
        except (ValueError, TypeError):
            continue
        if (not isinstance(payload, dict) or type(payload.get('pid')) is not int
                or payload['pid'] <= 0 or type(payload.get('started_at')) not in {str, int}
                or not payload['started_at']):
            continue
        result[row['task_id']] = {
            key: row[key] for key in ('task_id', 'run_id', 'started_at', 'spawned_at', 'kind', 'status', 'outcome')}
    return list(result.values())


def scheduled_receipt(db, task_id):
    """Retain dispatch IDs in native schedule evidence across a continuation."""
    event = db.execute("SELECT e.id,e.run_id,e.payload,r.profile,r.status,r.outcome,r.ended_at "
        "FROM task_events e JOIN task_runs r ON r.id=e.run_id AND r.task_id=e.task_id "
        "WHERE e.task_id=? AND e.kind='scheduled' ORDER BY e.id DESC LIMIT 1", (task_id,)).fetchone()
    if (not event or event['profile'] != 'head-coordinator' or event['status'] != 'scheduled'
            or event['outcome'] != 'scheduled' or event['ended_at'] is None):
        raise ValueError('Dispatch continuation needs its actual ended scheduled run')
    payload = json.loads(event['payload'] or '{}')
    reason = payload.get('reason') if isinstance(payload, dict) else None
    if not isinstance(reason, str) or not reason.startswith(WAIT) or len(reason) > 4096:
        raise ValueError('Schedule with Dispatch wait: followed by dispatched_task_ids JSON')
    return dict(event), {'board_progress': json.loads(reason[len(WAIT):])}


def require_resume(db, task_id):
    """Qualify one normal continuation inside the existing native unblock txn.

    Zero counters stay zero. Typed holds and failed workers keep their existing
    recovery path; this never grants a new attempt to another task or incident.
    """
    row = db.execute('SELECT * FROM tasks WHERE id=?', (task_id,)).fetchone()
    if row is None:
        return False
    owner = dict(row)
    if owner.get('tenant') != 'board-progress' or POLICY not in (owner.get('body') or '').splitlines():
        return False
    if (owner['status'] != 'scheduled' or owner['assignee'] != 'head-coordinator'
            or owner.get('block_kind') is not None or owner.get('consecutive_failures') != 0
            or owner.get('block_recurrences') != 0 or owner.get('last_failure_error')
            or any(owner.get(key) is not None for key in ('current_run_id', 'claim_lock', 'claim_expires', 'worker_pid'))):
        raise ValueError('Only a clean scheduled supervision wait may continue; preserve all technical holds')
    event, metadata = scheduled_receipt(db, task_id)
    latest = db.execute('SELECT id FROM task_runs WHERE task_id=? ORDER BY id DESC LIMIT 1', (task_id,)).fetchone()
    lifecycle = db.execute('SELECT id FROM task_events WHERE task_id=? AND kind NOT IN '
        "('commented','attachment_added','subscribed','unsubscribed') ORDER BY id DESC LIMIT 1", (task_id,)).fetchone()
    if (not latest or latest['id'] != event['run_id'] or not lifecycle or lifecycle['id'] != event['id']
            or db.execute("SELECT 1 FROM task_events WHERE task_id=? AND kind='unblocked' LIMIT 1", (task_id,)).fetchone()
            or disposition(db, owner, metadata)['state'] != 'started'):
        raise ValueError('Dispatch wait is not satisfied, was superseded or already consumed its one continuation')
    return True


def disposition(db, owner, metadata):
    """Correlate declared delegation to subsequent native execution, never prose."""
    if not isinstance(metadata, dict):
        raise ValueError('Supervision metadata must be an object')
    receipt = metadata.get('board_progress', {})
    if not isinstance(receipt, dict):
        raise ValueError('Board progress metadata must be an object')
    task_ids = receipt.get('dispatched_task_ids', [])
    if (not isinstance(task_ids, list) or len(task_ids) > 8
            or any(not isinstance(tid, str) or not re.fullmatch(r't_[A-Za-z0-9_-]+', tid) for tid in task_ids)
            or len(set(task_ids)) != len(task_ids) or owner['id'] in task_ids):
        raise ValueError('Declare up to eight distinct native dispatched_task_ids')
    first = db.execute('SELECT min(started_at) FROM task_runs WHERE task_id=?', (owner['id'],)).fetchone()[0]
    workers = starts(db, task_ids, since=first) if first is not None else []
    seen = {worker['task_id'] for worker in workers}
    state = 'started' if task_ids and seen == set(task_ids) else 'awaiting_worker_start'
    no_safe = receipt.get('no_safe_independent_work')
    if no_safe is not None:
        if (task_ids or not isinstance(no_safe, dict)
                or any(not isinstance(no_safe.get(key), str) or not no_safe[key].strip()
                       or len(no_safe[key]) > 2000 for key in ('reason', 'supplier', 'wake_condition'))
                or not re.fullmatch(r'agent|owner|model/provider|external-source-owner\([^\n]+\)', no_safe['supplier'])):
            raise ValueError('No-safe-work disposition needs reason, supplier and wake_condition; no dispatch claim')
        state = 'no_safe_independent_work'
    return dict(task_id=owner['id'], state=state, dispatched_task_ids=task_ids, worker_starts=workers,
                **({'no_safe_independent_work': no_safe} if no_safe else {}))


def require_completion(db, task_id, metadata):
    """New supervision tasks finish on observed starts or a concrete exception.

    Called by the existing native acceptance preflight inside its transaction.
    This changes no legacy card, retry budget, review or operational gate.
    """
    row = db.execute('SELECT * FROM tasks WHERE id=?', (task_id,)).fetchone()
    if row is None:
        return
    owner = dict(row)
    if owner.get('tenant') != 'board-progress' or POLICY not in (owner.get('body') or '').splitlines():
        return
    result = disposition(db, owner, metadata)
    if result['state'] == 'awaiting_worker_start':
        raise ValueError('Delegation is queued, not proven started. Keep this owner open; '
                         'schedule a bounded continuation, or record board_progress.'
                         'no_safe_independent_work with reason, supplier and wake_condition. '
                         'Never create another controller or bypass a dispatch/review gate.')


def collect(root, board=None):
    packets = []
    for manifest in sorted((root / 'kanban/boards').glob('*/board.json')):
        if manifest.parent.name.startswith(('_', '.')) or (board and manifest.parent.name != board):
            continue
        with closing(sqlite3.connect(manifest.with_name('kanban.db').resolve().as_uri() + '?mode=ro',
                                     uri=True, timeout=1)) as db:
            db.row_factory = sqlite3.Row
            db.execute('PRAGMA query_only=ON')
            db.execute('BEGIN')
            deadline = time.monotonic() + 2
            db.set_progress_handler(lambda: int(time.monotonic() > deadline), 1000)
            columns = {table: {column[1] for column in db.execute('PRAGMA table_info(' + table + ')')}
                       for table in ('tasks', 'task_links', 'task_runs', 'task_events')}
            if ('status' in columns['tasks'] and not db.execute(
                    "SELECT 1 FROM tasks WHERE status NOT IN ('done','archived','cancelled') LIMIT 1").fetchone()):
                continue
            projection = {'tasks': {'id', 'title', 'body', 'status', 'assignee', 'priority',
                                    'tenant', 'created_by', 'block_kind'},
                          'task_links': {'parent_id', 'child_id'}}
            missing = sorted(table + '.' + field for table, fields in projection.items()
                             for field in fields - columns[table])
            if missing:
                packets.append(dict(board=manifest.parent.name,
                    version=hashlib.sha256(json.dumps(missing).encode()).hexdigest(),
                    ready_running=None, started_workers=None, worker_starts=[], follow_through=[],
                    evidence_status='unavailable', missing_columns=missing, candidates=[], omitted_candidates=0))
                continue
            rows = bounded(db, "SELECT * FROM tasks WHERE status NOT IN ('done','archived','cancelled') ORDER BY priority DESC,id")
            rows = [row for row in rows if row['tenant'] != 'board-progress']
            owner = db.execute("SELECT * FROM tasks WHERE tenant='board-progress' ORDER BY rowid DESC LIMIT 1").fetchone()
            if not rows and (not owner or owner['status'] in {'done', 'archived', 'cancelled'}
                             or POLICY not in (owner['body'] or '').splitlines()):
                continue
            required = {'task_runs': {'id', 'task_id', 'profile', 'started_at', 'status', 'outcome', 'ended_at', 'metadata'},
                        'task_events': {'id', 'task_id', 'run_id', 'kind', 'created_at', 'payload'},
                        'tasks': {'current_run_id'}}
            available = all(fields <= columns[table] for table, fields in required.items())
            workers = starts(db, [row['id'] for row in rows], current=True) if available else []
            follow = []
            if owner and available:
                owner = dict(owner)
                run = db.execute('SELECT metadata FROM task_runs WHERE task_id=? ORDER BY id DESC LIMIT 1',
                                 (owner['id'],)).fetchone()
                try:
                    metadata = json.loads(run['metadata'] or '{}') if run else {}
                    if isinstance(metadata, dict) and 'board_progress' not in metadata:
                        try:
                            _, metadata = scheduled_receipt(db, owner['id'])
                        except ValueError:
                            pass
                    follow = [disposition(db, owner, metadata)]
                except (ValueError, TypeError):
                    follow = [dict(task_id=owner['id'], state='invalid_evidence', worker_starts=[],
                                   error='Unusable native supervision metadata; existing owner needs repair.')]
            if len(workers) > 1 and not follow:
                continue
            links = bounded(db,
                'SELECT l.parent_id,l.child_id,p.status FROM task_links l JOIN tasks p ON p.id=l.parent_id '
                "JOIN tasks c ON c.id=l.child_id WHERE c.status NOT IN ('done','archived','cancelled') "
                "AND p.status NOT IN ('done','archived','cancelled') ORDER BY l.child_id,l.parent_id", limit=4000)
        ids = {row['id'] for row in rows}
        links = [link for link in links if link['parent_id'] in ids and link['child_id'] in ids]
        # Native heartbeats/run counters and supervision cannot create new episodes.
        material = [{key: row[key] for key in ('id', 'title', 'body', 'status', 'assignee',
                                              'priority', 'tenant', 'created_by', 'block_kind')} for row in rows]
        version = hashlib.sha256(json.dumps([material, links], sort_keys=True).encode()).hexdigest()
        candidates = []
        active_ids = {worker['task_id'] for worker in workers}
        for row in rows:
            if row['id'] in active_ids:
                continue
            waiting = [link['parent_id'] for link in links if link['child_id'] == row['id']]
            candidates.append(dict(id=row['id'], title=row['title'][:180], status=row['status'],
                assignee=row['assignee'], block_kind=row['block_kind'], waiting_on=waiting,
                scope=(row['body'] or '')[:350]))
        candidates.sort(key=lambda row: (bool(row['waiting_on']), row['status'] not in {'todo','ready','review'}))
        scopes = [row for row in candidates if row['title'].startswith('[FEATURE TRACKER')][:2]
        selected = candidates[:8-len(scopes)]
        selected += [row for row in scopes if row not in selected]
        count = len(workers) if available else None
        packets.append(dict(board=manifest.parent.name, version=version, ready_running=count,
            started_workers=count, worker_starts=workers, follow_through=follow,
            evidence_status='observed' if available else 'unavailable', candidates=selected,
            omitted_candidates=len(candidates)-len(selected)))
    return packets


def monitor_lines(root):
    return ['LOW_ACTIVITY ' + json.dumps(packet, sort_keys=True) for packet in collect(root)]


if __name__ == '__main__':
    root = Path(os.environ.get('HERMES_ROOT', str(Path.home() / '.hermes')))
    for packet in collect(root, os.environ.get('HERMES_BOARD')):
        print(json.dumps(packet, sort_keys=True))
