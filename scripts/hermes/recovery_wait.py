"""Qualify explicit native event waits without granting another execution attempt.

Python is required by Hermes' existing SQLite lifecycle and supervisor. This
small adapter uses its standard library, with no service or new dependency.
"""
from contextlib import closing
import json
from pathlib import Path
import re
import sqlite3
import time

PREFIX = 'Recovery wait: '
NOTES = ('commented', 'attached', 'subscribed', 'unsubscribed')
TERMINAL_EVENTS = {
    'completed': ('completed',),
    'blocked': ('blocked', 'block_loop_detected', 'dependency_wait'),
    'scheduled': ('scheduled',),
    'review_requested': ('review_requested',),
    'changes_requested': ('changes_requested',),
    'failed': ('failed', 'gave_up'),
    'crashed': ('crashed', 'protocol_violation', 'gave_up'),
    'rate_limited': ('rate_limited',),
    'stale': ('stale',),
    'reclaimed': ('reclaimed', 'reconciled', 'archived', 'descendant_invalidated', 'gave_up'),
    'timed_out': ('timed_out', 'gave_up'),
    'spawn_failed': ('spawn_failed', 'gave_up'),
    'gave_up': ('gave_up',),
    'protocol_violation': ('protocol_violation', 'gave_up'),
}


def receipt(db, task_id):
    # Identify opt-in before applying bounds: ordinary native schedule reasons
    # have no receipt limit. Extract only a bounded reason into Python.
    event = db.execute("SELECT id,run_id,created_at,length(payload) AS payload_length, "
        "CASE WHEN json_valid(payload) THEN CASE WHEN json_type(payload,'$.reason')='text' "
        "THEN substr(json_extract(payload,'$.reason'),1,1025) END END AS reason FROM task_events "
        "WHERE task_id=? AND kind='scheduled' ORDER BY id DESC LIMIT 1", (task_id,)).fetchone()
    if not event:
        return None
    reason = event['reason']
    if not isinstance(reason, str) or not reason.startswith(PREFIX):
        return None
    if event['payload_length'] > 4096:
        raise ValueError('Recovery schedule payload exceeds its receipt bound')
    if len(reason) > 1024:
        raise ValueError('Recovery wait exceeds its receipt bound')
    value = json.loads(reason[len(PREFIX):])
    if (not isinstance(value, dict) or set(value) != {'task_id', 'after_run_id', 'until'}
            or not isinstance(value['task_id'], str)
            or not re.fullmatch(r't_[A-Za-z0-9_]{1,80}', value['task_id'])
            or value['task_id'] == task_id
            or type(value['after_run_id']) is not int or value['after_run_id'] < 0
            or value['until'] not in ('started', 'terminal')):
        raise ValueError('Recovery wait needs one same-board task, run boundary and started/terminal event')
    return dict(event), value


def require_resume(db, task_id):
    """Read-only qualification, also called inside native ordinary unblock.

    A satisfied receipt authorizes reconciliation by this same clean recovery
    owner. It never accepts the observed result or releases its consumers.
    """
    observed = receipt(db, task_id)
    if observed is None:
        return False
    event, wait = observed
    row = db.execute('SELECT * FROM tasks WHERE id=?', (task_id,)).fetchone()
    if row is None:
        raise ValueError('Recovery wait owner is missing')
    owner = dict(row)
    if (owner['status'] != 'scheduled' or owner['assignee'] != 'head-coordinator'
            or owner['tenant'] != 'technical-recovery'
            or '[FEATURE TRACKER' in owner['title'].upper()
            or owner['block_kind'] not in (None, 'dependency')
            or owner['consecutive_failures'] != 0 or owner['block_recurrences'] != 0
            or any(owner[k] is not None for k in
                   ('current_run_id', 'worker_pid', 'claim_lock', 'claim_expires'))):
        raise ValueError('Only a clean scheduled coordinator recovery wait may resume')
    run = db.execute('SELECT * FROM task_runs WHERE task_id=? ORDER BY id DESC LIMIT 1',
                     (task_id,)).fetchone()
    lifecycle = db.execute("SELECT id FROM task_events WHERE task_id=? AND kind NOT IN "
        "('commented','attached','subscribed','unsubscribed') ORDER BY id DESC LIMIT 1",
        (task_id,)).fetchone()
    active = db.execute('SELECT 1 FROM task_runs WHERE task_id=? '
        'AND (ended_at IS NULL OR status IN (\'running\',\'pending\',\'claimed\',\'starting\')) LIMIT 1',
        (task_id,)).fetchone()
    if (not run or active or run['id'] != event['run_id']
            or run['profile'] != 'head-coordinator' or run['status'] != 'scheduled'
            or run['outcome'] != 'scheduled' or type(run['started_at']) is not int
            or type(run['ended_at']) is not int or run['started_at'] <= 0
            or run['ended_at'] < run['started_at'] or event['created_at'] < run['ended_at']
            or not lifecycle or lifecycle['id'] != event['id']):
        raise ValueError('Recovery wait has an active, consumed or superseded native schedule')
    source = db.execute('SELECT * FROM tasks WHERE id=?', (wait['task_id'],)).fetchone()
    original = db.execute('SELECT * FROM task_runs WHERE task_id=? ORDER BY id DESC LIMIT 1',
                          (wait['task_id'],)).fetchone()
    if (not source or '[FEATURE TRACKER' in source['title'].upper() or not original
            or original['id'] <= wait['after_run_id']
            or not isinstance(original['profile'], str) or not original['profile']
            or type(original['started_at']) is not int or original['started_at'] <= 0):
        raise ValueError('Recovery wait has no matching new original execution')
    claim = db.execute("SELECT 1 FROM task_events WHERE task_id=? AND run_id=? AND kind='claimed' "
        'AND created_at>=? LIMIT 1',
        (wait['task_id'], original['id'], original['started_at'])).fetchone()
    if not claim:
        raise ValueError('Recovery wait needs genuine native original claim evidence')
    if wait['until'] == 'started':
        events = db.execute("SELECT id,payload FROM task_events WHERE task_id=? AND run_id=? "
            "AND kind IN ('spawned','worker_registered') AND created_at>=? ORDER BY id LIMIT 16",
            (wait['task_id'], original['id'], max(run['started_at'], original['started_at']))).fetchall()
        for started in events:
            payload = json.loads(started['payload'] or '{}')
            if (isinstance(payload, dict) and type(payload.get('pid')) is int and payload['pid'] > 0
                    and type(payload.get('started_at')) in (str, int) and payload['started_at']):
                return dict(task_id=task_id, schedule_event_id=event['id'],
                            observed_task_id=wait['task_id'], observed_run_id=original['id'],
                            observed_event_id=started['id'], until='started')
        raise ValueError('Recovery wait is still awaiting a fresh native worker start')
    kinds = TERMINAL_EVENTS.get(original['outcome'], ())
    if (not kinds or original['status'] in ('running', 'pending', 'claimed', 'starting')
            or type(original['ended_at']) is not int
            or original['ended_at'] < max(original['started_at'], run['started_at'])):
        raise ValueError('Recovery wait is still awaiting a fresh native terminal result')
    marks = ','.join('?' for _ in kinds)
    terminal = db.execute('SELECT id FROM task_events WHERE task_id=? AND run_id=? '
        f'AND kind IN ({marks}) AND created_at>=? ORDER BY id DESC LIMIT 1',
        (wait['task_id'], original['id'], *kinds, original['ended_at'])).fetchone()
    if not terminal:
        raise ValueError('Recovery wait needs the matching native terminal event')
    return dict(task_id=task_id, schedule_event_id=event['id'],
                observed_task_id=wait['task_id'], observed_run_id=original['id'],
                observed_event_id=terminal['id'], until='terminal')


def inspect(root):
    """Bounded read-only inventory; legacy prose is visible but never inferred."""
    result = dict(ready=[], waiting=[], unregistered=0)
    paths = sorted(p for p in (Path(root) / 'kanban/boards').glob('*/board.json')
                   if not p.parent.name.startswith(('_', '.')))
    if len(paths) > 32:
        raise ValueError('Recovery wait inventory exceeds 32 boards')
    for manifest in paths:
        board = manifest.parent.name
        if not re.fullmatch(r'[a-z0-9][a-z0-9_-]{0,63}', board):
            raise ValueError('Recovery wait board slug is invalid')
        path = manifest.with_name('kanban.db')
        with closing(sqlite3.connect(path.resolve().as_uri() + '?mode=ro', uri=True, timeout=1)) as db:
            db.row_factory = sqlite3.Row
            db.execute('PRAGMA query_only=ON')
            db.execute('BEGIN')
            deadline = time.monotonic() + 2
            db.set_progress_handler(lambda: int(time.monotonic() > deadline), 1000)
            rows = db.execute("SELECT id FROM tasks WHERE status='scheduled' "
                "AND tenant='technical-recovery' ORDER BY id LIMIT 1001").fetchall()
            if len(rows) > 1000:
                raise ValueError('Recovery wait inventory exceeds 1000 owners per board')
            for row in rows:
                try:
                    proof = require_resume(db, row['id'])
                    if proof:
                        result['ready'].append(dict(board=board, **proof))
                    else:
                        result['unregistered'] += 1
                except (ValueError, TypeError) as exc:
                    result['waiting'].append(dict(board=board, task_id=row['id'], reason=str(exc)))
    return result


if __name__ == '__main__':
    import argparse
    import os
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--inspect', action='store_true')
    parser.parse_args()
    print(json.dumps(inspect(Path(os.environ.get('HERMES_ROOT', str(Path.home() / '.hermes')))), sort_keys=True))
