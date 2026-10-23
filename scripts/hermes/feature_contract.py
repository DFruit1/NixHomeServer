"""Shared, bounded feature membership and evidence-version reads.

The native completion transaction and read-only intake use the same functions.
Python is native Hermes integration glue; no extra database or service.
"""
import json
import re
from pathlib import Path
import os
import subprocess

if __package__ == 'hermes_cli':
    from .nixhomeserver_fleet_contract import digest, load, validate_board
else:
    from fleet_contract import digest, load, validate_board

TRACKER = re.compile(r'^\[FEATURE TRACKER', re.I)
BINDING = re.compile(r'^Feature tracker:\s*([a-zA-Z0-9_-]+):(t_[a-zA-Z0-9_]+)\s*$', re.M)


def _metadata(db, tid):
    row = db.execute('SELECT metadata,status,outcome,profile FROM task_runs WHERE task_id=? '
                     'ORDER BY id DESC LIMIT 1', (tid,)).fetchone()
    if not row:
        return {}, False
    try:
        value = json.loads(row['metadata'] or '{}')
    except (ValueError, TypeError):
        return {}, False
    assignee = db.execute('SELECT assignee FROM tasks WHERE id=?', (tid,)).fetchone()
    return (value if isinstance(value, dict) else {}), (row['status'] == 'done' and row['outcome'] == 'completed'
                                                        and assignee and row['profile'] == assignee[0])


def _inventory(db, board):
    tasks = [dict(r) for r in db.execute('SELECT * FROM tasks LIMIT 5001')]
    if len(tasks) > 5000:
        raise ValueError('Feature intake exceeds bounded task inventory')
    by_id = {t['id']: t for t in tasks}
    trackers = [t for t in tasks if t['status'] not in {'done', 'archived'} and TRACKER.match(t['title'])]
    if len(trackers) > 100:
        raise ValueError('Feature intake exceeds bounded tracker inventory')
    # Exact body/comment bindings are membership, unlike quoted context IDs.
    bindings = {}
    comments = db.execute("SELECT task_id,body FROM task_comments WHERE body LIKE '%Feature tracker:%' LIMIT 5001").fetchall()
    if len(comments) > 5000:
        raise ValueError('Feature intake exceeds bounded membership records')
    structured = {t['id']: load(db, t['id']) for t in tasks}
    for tid, workflow in structured.items():
        feature = workflow.get('feature') if workflow else None
        if feature:
            marker_board, tracker = feature['tracker'].split(':')
            if marker_board == board and tracker in by_id and TRACKER.match(by_id[tracker]['title']) and tid != tracker:
                bindings.setdefault(tracker, set()).add(tid)
    for tid, body in [(t['id'], t['body'] or '') for t in tasks] + [(r['task_id'], r['body']) for r in comments]:
        if structured.get(tid) is not None:
            continue
        for marker_board, tracker in BINDING.findall(body):
            if marker_board == board and tracker in by_id and TRACKER.match(by_id[tracker]['title']) and tid != tracker:
                bindings.setdefault(tracker, set()).add(tid)
    return by_id, trackers, bindings


def _inputs(db, tracker, members):
    inputs = db.execute("SELECT id,author,body,created_at FROM task_comments WHERE task_id=? AND "
                        "(author IN ('desktop','user','owner','interactive-operator','authenticated-owner','default') "
                        "OR (author='head-coordinator' AND body LIKE '%Feature input:%')) ORDER BY id LIMIT 1001",
                        (tracker['id'],)).fetchall()
    if len(inputs) > 1000:
        raise ValueError('Feature material-input inventory exceeds bound')
    ids = [tracker['id']] + [m['id'] for m in members if m['created_by'] != 'deadlock-recovery-monitor']
    receipts = db.execute('SELECT id,task_id,filename,size,created_at FROM task_attachments WHERE task_id IN ('+
                          ','.join('?' for _ in ids)+') ORDER BY id LIMIT 1001', ids).fetchall()
    if len(receipts) > 1000:
        raise ValueError('Feature receipt inventory exceeds bound')
    return inputs, receipts


def _version(db, tracker, members):
    results = []
    assessments = set()
    for member in members:
        meta, completed = _metadata(db, member['id'])
        assessment = meta.get('feature_assessment', {})
        if (completed and member['assignee'] == 'project-auditor' and isinstance(assessment, dict)
                and assessment.get('tracker') == tracker['id']
                and assessment.get('scope_sha256') == digest({'title': tracker['title'], 'body': tracker['body']})):
            # Identical repeated recovery assessments are not new evidence.
            # A genuinely changed scoped mechanism/input assessment is.
            semantic = {k: assessment[k] for k in ('scope_sha256', 'outcome', 'missing_inputs', 'supplier', 'wake_condition') if k in assessment}
            assessments.add(json.dumps(semantic, sort_keys=True))
        if completed and member['assignee'] != 'head-coordinator' and member['created_by'] != 'deadlock-recovery-monitor':
            semantic = {k: meta[k] for k in ('revision', 'verdict', 'checks', 'missing_inputs') if k in meta}
            if semantic:
                results.append([member['id'], semantic])
    inputs, receipts = _inputs(db, tracker, members)
    return digest({'tracker': tracker['id'], 'title': tracker['title'], 'body': tracker['body'], 'results': results,
                   'assessments': sorted(assessments),
                   'material_inputs': [list(r) for r in inputs], 'receipts': [list(r) for r in receipts]})


def prepare_delivery(db, task_id, feature, delivery):
    if (not isinstance(delivery, dict) or delivery.get('state') != 'delivered_scope'
            or set(delivery) - {'state', 'tracker', 'expected_version', 'evidence_version', 'evidence_task_id',
                                'scope', 'stage', 'revision'}):
        raise ValueError('Delivery needs delivered_scope, an evidence task and expected_version')
    if not feature or feature['role'] != 'delivery':
        raise ValueError('A structured delivery operation requires a delivery task contract')
    validate_board(db, {'feature': feature})
    board, tid = feature['tracker'].split(':')
    actor = db.execute('SELECT assignee FROM tasks WHERE id=?', (task_id,)).fetchone()
    if not actor or actor['assignee'] != 'head-coordinator':
        raise ValueError('Delivery reconciliation belongs to the coordinator')
    if delivery.get('tracker', tid) != tid:
        raise ValueError('Delivery tracker conflicts with the task contract')
    by_id, trackers, bindings = _inventory(db, board)
    tracker = next((t for t in trackers if t['id'] == tid), None)
    if tracker is None:
        raise ValueError('Delivery requires its exact open feature tracker')
    members = [by_id[m] for m in sorted(bindings.get(tid, set())) if m in by_id]
    version = _version(db, tracker, members)
    if delivery.get('expected_version', delivery.get('evidence_version')) != version:
        raise ValueError('Delivery scope changed; inspect current evidence_version before completing')
    evidence_id = delivery.get('evidence_task_id')
    evidence = by_id.get(evidence_id)
    meta, completed = _metadata(db, evidence_id)
    source_contract = load(db, evidence_id) if evidence else None
    source_feature = source_contract.get('feature') if source_contract else None
    if (not evidence or evidence_id == task_id or evidence_id not in bindings.get(tid, set())
            or evidence['status'] != 'done' or not completed or meta.get('verdict') != 'accept'
            or not source_feature or source_feature['role'] != 'producer'
            or source_feature['tracker'] != feature['tracker'] or source_feature['scope'] != feature['scope']
            or source_feature.get('stage', 'integrated') != feature.get('stage', 'integrated')
            or not source_contract.get('review')):
        raise ValueError('Delivery needs completed independent implementation acceptance for this exact scope')
    if __package__ == 'hermes_cli':
        from .nixhomeserver_fleet_workflow import acceptance, review_handoff
    else:
        from fleet_workflow import acceptance, review_handoff
    acceptance(review_handoff(db, evidence_id), meta, evidence['assignee'])
    checks = meta.get('checks')
    if (not isinstance(checks, list) or not checks or any(
            not isinstance(c, dict) or not isinstance(c.get('command'), str) or not c['command'].strip()
            or type(c.get('exit_code')) is not int or c['exit_code'] != 0 for c in checks)):
        raise ValueError('Delivery evidence needs successful executed checks')
    if feature.get('stage', 'integrated') == 'integrated':
        from hermes_cli.kanban_db_connect import _main_db_file
        path = Path(_main_db_file(db))
        registration = json.loads(path.with_name('board.json').read_text())
        work = registration.get('default_workdir')
        if not isinstance(work, str) or not Path(work).is_absolute() or not Path(work).is_dir():
            raise ValueError('Integrated delivery needs the registered source checkout')
        env = dict(os.environ, GIT_OPTIONAL_LOCKS='0', GIT_TERMINAL_PROMPT='0')
        for key in ('GIT_DIR', 'GIT_WORK_TREE', 'GIT_COMMON_DIR'):
            env.pop(key, None)
        result = subprocess.run(['git', '--no-optional-locks', '-C', work, 'merge-base',
                                 '--is-ancestor', meta['revision'], 'HEAD'],
                                capture_output=True, env=env, timeout=5)
        if result.returncode:
            raise ValueError('Accepted source is not integrated into the registered checkout')
    result = dict(tracker=tid, evidence_version=version, state='delivered_scope',
                  evidence_task_id=evidence_id, scope=feature['scope'],
                  stage=feature.get('stage', 'integrated'), revision=meta['revision'])
    if any(key in delivery and delivery[key] != result[key] for key in ('scope', 'stage', 'revision')):
        raise ValueError('Submitted delivery fields conflict with the actual accepted scope')
    return result
