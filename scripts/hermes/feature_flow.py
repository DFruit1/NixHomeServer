"""Read-only delivery-gap intake for parked feature trackers.

Python shares the native recovery collector's SQLite operations; no new service
or model lane. A tracker is an evidence anchor, never an execution dependency.
"""
import json
import re
import argparse
from contextlib import closing
import os
from pathlib import Path
import sqlite3
import time
import importlib.util
from functools import lru_cache

from capability_recovery import digest

QUIET_SECONDS = 48 * 3600
TRACKER = re.compile(r'^\[FEATURE TRACKER', re.I)
BINDING = re.compile(r'^Feature tracker:\s*([a-zA-Z0-9_-]+):(t_[a-zA-Z0-9_]+)\s*$', re.M)
TASK_ID = re.compile(r'\bt_[a-zA-Z0-9_]+\b')


@lru_cache(maxsize=1)
def _verifier():
    spec = importlib.util.spec_from_file_location('feature_verdict_contract', Path(__file__).with_name('review-verdict-guard.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


from feature_contract import _metadata, _inventory, _inputs, _version


def inspect_feature(db, board, tid):
    by_id, trackers, bindings = _inventory(db, board)
    tracker = next((t for t in trackers if t['id'] == tid), None)
    if not tracker:
        raise ValueError('Exact open feature tracker required')
    members = [by_id[m] for m in sorted(bindings.get(tid, set())) if m in by_id]
    return {'tracker': tid, 'board': board, 'evidence_version': _version(db, tracker, members),
            'scope_sha256': digest({'title': tracker['title'], 'body': tracker['body']}),
            'members': [{'id': m['id'], 'status': m['status']} for m in members]}


def observe_features(db, board, now):
    by_id, trackers, bindings = _inventory(db, board)
    issues = []
    for tracker in trackers:
        tid = tracker['id']
        if now - tracker['created_at'] < QUIET_SECONDS:
            continue
        members = [by_id[m] for m in sorted(bindings.get(tid, set())) if m in by_id]
        recent = db.execute('SELECT body FROM task_comments WHERE task_id=? ORDER BY id DESC LIMIT 5', (tid,)).fetchall()
        hints = set(TASK_ID.findall((tracker['body'] or '') + '\n' + '\n'.join(r['body'] for r in recent)))
        # Protect an actual writer even before legacy membership is reconciled.
        if any(by_id[h]['status'] == 'running' or by_id[h].get('worker_pid') is not None
               for h in hints | bindings.get(tid, set()) if h in by_id):
            continue
        open_members = [m for m in members if m['status'] not in {'done', 'archived'}]
        owner_gates = [m for m in open_members if m['block_kind'] == 'needs_input']
        if owner_gates:
            inputs, receipts = _inputs(db, tracker, members)
            latest_input = max([r['created_at'] for r in inputs + receipts] or [0])
            gate_time = max(db.execute("SELECT COALESCE(MAX(created_at),?) FROM task_events WHERE task_id=? AND kind='blocked'",
                                       (m['created_at'], m['id'])).fetchone()[0] for m in owner_gates)
            if latest_input <= gate_time:
                continue
        productive = [m for m in open_members if m['created_by'] != 'deadlock-recovery-monitor' and m not in owner_gates]
        if any(m['assignee'] != 'head-coordinator' and m['status'] in {'ready', 'todo', 'review'} for m in productive):
            continue
        # Fresh routing or a fresh parked producer gets its existing recovery
        # path first. Old waiting handoffs are evidence for reconciliation.
        fresh = False
        for member in productive:
            row = db.execute('SELECT MAX(ended_at) FROM task_runs WHERE task_id=?', (member['id'],)).fetchone()
            if now - max(member['created_at'], row[0] or 0) < QUIET_SECONDS:
                fresh = True
                break
        if fresh:
            continue
        version = _version(db, tracker, members)
        disposed = False
        for member in members:
            if member['assignee'] != 'head-coordinator':
                continue
            meta, completed = _metadata(db, member['id'])
            disposition = meta.get('feature_delivery', {})
            if (not completed or not isinstance(disposition, dict) or disposition.get('tracker') != tid
                    or disposition.get('evidence_version') != version):
                continue
            evidence = by_id.get(disposition.get('evidence_task_id'))
            if (not evidence or evidence['status'] != 'done' or evidence['id'] == member['id']
                    or evidence['id'] not in bindings.get(tid, set()) | hints):
                continue
            evidence_meta, evidence_done = _metadata(db, evidence['id'])
            state = disposition.get('state')
            if evidence_done and state == 'delivered_scope' and evidence_meta.get('verdict') == 'accept':
                verifier = _verifier()
                try:
                    if verifier.verification(evidence, db):
                        verifier.validate(evidence_meta, profile=evidence['assignee'])
                        if verifier.native_review(db, evidence):
                            verifier._independent_native_acceptance(db, evidence)
                        disposed = True
                except (ValueError, TypeError):
                    pass
            assessment = evidence_meta.get('feature_assessment', {})
            if (evidence_done and state == 'assessed_defer' and evidence['assignee'] == 'project-auditor'
                    and isinstance(assessment, dict) and assessment.get('tracker') == tid
                    and assessment.get('scope_sha256') == digest({'title': tracker['title'], 'body': tracker['body']})
                    and assessment.get('outcome') == 'defer'
                    and isinstance(assessment.get('missing_inputs'), list) and assessment['missing_inputs']
                    and all(isinstance(v, str) and v.strip() for v in assessment['missing_inputs'])
                    and isinstance(assessment.get('supplier'), str) and assessment['supplier'].strip()
                    and isinstance(disposition.get('wake_condition'), str) and disposition['wake_condition'].strip()
                    and assessment.get('wake_condition') == disposition['wake_condition']):
                disposed = True
        if disposed:
            continue
        issues.append({'key': board + ':' + tid + ':feature-delivery-gap', 'task_id': tid,
                       'kind': 'feature-delivery-gap', 'version': version, 'priority': tracker['priority'],
                       'reason': 'Requested feature lacks productive work or a qualified current-scope disposition',
                       'existing_owners': [m['id'] for m in open_members], 'context_refs': sorted(hints & by_id.keys()),
                       'parents': [], 'downstream': []})
    return sorted(issues, key=lambda i: (-i['priority'], i['key']))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--inspect', required=True, metavar='BOARD:t_CARD')
    args = parser.parse_args()
    if not re.fullmatch(r'[A-Za-z0-9_-]+:t_[A-Za-z0-9_]+', args.inspect):
        parser.error('Exact board:tracker identity required')
    board, tid = args.inspect.split(':')
    root = Path(os.environ.get('HERMES_ROOT', str(Path.home()/'.hermes'))).resolve()
    path = root/'kanban/boards'/board/'kanban.db'
    if not path.resolve().is_relative_to((root/'kanban/boards').resolve()):
        parser.error('Board path leaves maintained root')
    with closing(sqlite3.connect(path.resolve().as_uri()+'?mode=ro', uri=True, timeout=2)) as db:
        db.row_factory = sqlite3.Row
        db.execute('PRAGMA query_only=ON'); db.execute('BEGIN')
        deadline = time.monotonic()+5
        db.set_progress_handler(lambda: int(time.monotonic()>deadline), 1000)
        print(json.dumps(inspect_feature(db, board, tid), sort_keys=True))
