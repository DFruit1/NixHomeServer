"""Authenticated board management for native coordinator workers.

Python extends the existing Hermes tools and transactions. It is not a new
backend. The ordinary worker lifecycle and terminal fences remain unchanged.
"""
from contextvars import ContextVar
import importlib.util
import json
import re
import sys

from hermes_cli.nixhomeserver_resume_recovered import coordinator_origin, require_actor_board
from hermes_cli.nixhomeserver_coordinator_repair import snapshot

_operation = ContextVar('hermes_coordinator_operation', default=None)
ACTIONS = ('complete', 'block', 'schedule', 'assign', 'promote', 'specify', 'reclaim', 'archive')
FIELDS = {'complete': {'evidence', 'delivery', 'metadata'}, 'block': {'kind'}, 'schedule': set(),
          'assign': {'assignee'}, 'promote': set(), 'specify': {'title', 'body'},
          'reclaim': set(), 'archive': set()}


def require_requested_board(board=None):
    actor = coordinator_origin()
    if actor is not None and board not in (None, actor['board']):
        raise ValueError('Coordinator management is confined to its authenticated board; use read-only evidence across boards')
    return actor


def attachment_target(task_id, board=None):
    """Append-only delivery is permitted; it cannot end another worker's run."""
    actor = require_requested_board(board)
    return bool(actor and task_id != actor['task_id'])


def _load(root, filename):
    path = root / 'scripts' / filename
    if not path.is_file() or path.is_symlink():
        raise ValueError('Required installed policy is unavailable: ' + filename)
    spec = importlib.util.spec_from_file_location('coordinator_' + filename.replace('-', '_'), path)
    module = importlib.util.module_from_spec(spec)
    previous = sys.path[:]
    try:
        sys.path.insert(0, str(path.parent))
        spec.loader.exec_module(module)
    finally:
        sys.path[:] = previous
    return module


def _policy(root, board, tid, action, fields, reason):
    tool = 'kanban_complete' if action == 'complete' else 'kanban_block'
    if action not in {'complete', 'block', 'reclaim'}:
        return
    if action == 'reclaim':
        if not re.search(r'Input supplier: (?:agent|model/provider)\b', reason):
            raise ValueError('Dead-worker containment needs Input supplier: agent or model/provider and its actual evidence')
        fields = {'kind': 'capability'}
    args = dict(board=board, task_id=tid, reason=reason, **fields)
    payload = dict(tool_name=tool, profile='head-coordinator', tool_input=args)
    if action == 'complete':
        metadata = fields.get('metadata', {})
        if (not isinstance(metadata, dict) or len(json.dumps(metadata)) > 32768
                or {'verdict', 'independence', 'worker_session_id', 'coordinator_action', 'execution_origin'} & set(metadata)):
            raise ValueError('Completion metadata must preserve actual coordinator provenance and cannot supply a review verdict')
        args.update(result=reason, summary=reason)
        answer = _load(root, 'review-verdict-guard.py').guard(payload, root)
    else:
        alerts = _load(root, 'kanban-owner-alerts.py')
        answer = _load(root, 'owner-blocker-authoring-guard.py').guard(payload, root, alerts)
    if answer.get('action') == 'block':
        raise ValueError(answer['message'])


def _evidence(conn, tid, evidence):
    if not isinstance(evidence, list) or not 1 <= len(evidence) <= 16:
        raise ValueError('Completion needs 1-16 exact finished native runs and why each satisfies this card')
    for item in evidence:
        if (not isinstance(item, dict) or set(item) != {'task_id', 'run_id', 'why'}
                or item['task_id'] == tid or type(item['run_id']) is not int
                or not isinstance(item['why'], str) or not item['why'].strip()
                or len(item['why']) > 2000):
            raise ValueError('Evidence requires a different task_id, integer run_id and a bounded substantive why')
        run = conn.execute('SELECT * FROM task_runs WHERE task_id=? AND id=?',
                           (item['task_id'], item['run_id'])).fetchone()
        latest = conn.execute('SELECT id FROM task_runs WHERE task_id=? ORDER BY id DESC LIMIT 1',
                              (item['task_id'],)).fetchone()
        if (not run or run['ended_at'] is None or not run['outcome']
                or run['status'] in {'running', 'pending', 'claimed', 'starting'}
                or not latest or latest['id'] != run['id']
                or not conn.execute("SELECT 1 FROM task_events WHERE task_id=? AND run_id=? AND kind='claimed'",
                                    (item['task_id'], item['run_id'])).fetchone()
                or not conn.execute("SELECT 1 FROM task_events WHERE task_id=? AND run_id=? AND kind='spawned'",
                                    (item['task_id'], item['run_id'])).fetchone()):
            raise ValueError('Evidence must name the latest finished genuine native execution of the named task')


def _validate(kb, conn, request):
    root, board = require_actor_board(conn, request['actor'])
    task, version = snapshot(conn, request['task_id'])
    if version != request['expected_version']:
        raise ValueError('Card changed; inspect its current version before acting')
    action, fields = request['action'], request['fields']
    tid = task['id']
    if (tid == request['actor']['task_id'] or (task['goal_mode'] and action not in {'reclaim','archive'})
            or '[FEATURE TRACKER' in task['title'].upper()
            or 'FEATURE TRACKER: NOT AN EXECUTION TASK' in (task['body'] or '')
            or task['block_kind'] == 'needs_input'):
        raise ValueError('Use the owning lifecycle for own tasks, goals, trackers and existing owner gates')
    if action == 'reclaim':
        if task['status'] != 'running' or kb._claim_is_live(task):
            raise ValueError('Reclaim requires a demonstrably dead worker; live workers are protected')
    else:
        if (task['status'] not in ({'done'} if action == 'archive' else {'todo', 'ready', 'blocked', 'scheduled', 'triage'})
                or any(task[k] is not None for k in ('worker_pid', 'claim_lock', 'claim_expires', 'current_run_id'))
                or conn.execute("SELECT 1 FROM task_runs WHERE task_id=? AND (status IN ('running','pending','claimed','starting') OR (ended_at IS NULL AND outcome IS NULL))",
                                (tid,)).fetchone()):
            raise ValueError('Management requires a parked card with no active worker, run or lease')
    if action == 'complete':
        if task['assignee'] != 'head-coordinator':
            raise ValueError('Coordinator completes coordinator handoffs only; implementation and independent verdicts belong to their owners')
        if task.get('completion_contract') not in (None, 'local-only'):
            raise ValueError('Remote publication contracts retain their existing operator/review path')
        if not kb._parents_satisfied(conn, tid):
            raise ValueError('Unfinished linked prerequisites still hold this card')
        created = conn.execute("SELECT payload FROM task_events WHERE task_id=? AND kind='created' ORDER BY id LIMIT 1", (tid,)).fetchone()
        original = json.loads(created['payload'] or '{}') if created else {}
        if original.get('assignee') in {'standard-implementer', 'local-implementer', 'feature-reviewer', 'project-auditor'}:
            raise ValueError('Reassignment cannot turn implementation or review into a coordinator completion')
        _evidence(conn, tid, fields.get('evidence'))
    elif action == 'block':
        if fields.get('kind') not in {'capability', 'dependency', 'needs_input', 'transient'}:
            raise ValueError('Use an explicit native block kind and checked supplier/recovery reason')
        if task['block_kind'] is not None:
            raise ValueError('Do not retype existing gates; use the existing guarded recovery/amendment path')
        if fields['kind'] == 'dependency' and kb._parents_satisfied(conn, tid):
            raise ValueError('A dependency wait requires a linked unfinished prerequisite')
    elif action == 'schedule' and task['status'] == 'scheduled':
        raise ValueError('Already scheduled; an unchanged wait needs no new action')
    elif action in {'promote', 'specify', 'assign'}:
        if task['block_kind'] not in (None, 'dependency') or task['consecutive_failures'] or task['block_recurrences']:
            raise ValueError('This operation cannot release or transfer a failed/typed hold; use exact-version recovery')
        if action == 'assign':
            if (fields.get('assignee') not in {'head-coordinator', 'standard-implementer', 'local-implementer', 'feature-reviewer', 'project-auditor'}
                    or task['assignee'] == 'local-implementer'
                    or task['last_failure_error'] is not None
                    or conn.execute("SELECT 1 FROM task_events WHERE task_id=? AND kind IN ('review_requested','changes_requested')", (tid,)).fetchone()):
                raise ValueError('Reassignment must preserve credential lanes, review ownership and failure history')
            old, new = task['assignee'], fields['assignee']
            if (old == new or (old is not None and (old, new) not in {
                    ('standard-implementer', 'local-implementer'), ('planner', 'head-coordinator'),
                    ('feature-reviewer', 'project-auditor'), ('project-auditor', 'feature-reviewer')})):
                raise ValueError('Use a suitable unassigned/retired lane or move standard work to the local lane; never change a task into its own approver')
            if new == 'local-implementer' and not task['max_runtime_seconds']:
                raise ValueError('The local lane needs its existing finite positive runtime')
        if action == 'specify' and task['status'] != 'triage':
            raise ValueError('Specify requires an untouched generic triage card')
        if action == 'specify':
            from hermes_cli.nixhomeserver_worker_policy import EVIDENCE
            if (any(not isinstance(fields.get(k), str) or not fields[k].strip() for k in ('title', 'body'))
                    or len(fields['title']) > 1000 or len(fields['body']) > 32000
                    or bool(EVIDENCE.search(fields['body'])) != bool(EVIDENCE.search(task['body'] or ''))):
                raise ValueError('Specify needs a bounded concrete title/body preserving the evidence-recovery fence')
    _policy(root, board, tid, action, fields, request['reason'])
    return task


def before_write(conn):
    """Called under BEGIN IMMEDIATE before the native operation writes anything."""
    request = _operation.get()
    if request is None or request['finished']:
        return
    from hermes_cli import kanban_db as kb
    task = _validate(kb, conn, request)
    if not request['checked']:
        request['checked'] = True
        kb._append_event(conn, task['id'], 'coordinator_board_action', request['audit'])


def after_write(conn):
    """Mark the actual native transition before commit, not an earlier attachment write."""
    request = _operation.get()
    if request is not None and request['checked'] and not request['finished']:
        _, version = snapshot(conn, request['task_id'])
        request['finished'] = version != request['expected_version']


def parked_transition(task_id):
    request = _operation.get()
    return bool(request and request['checked'] and request['task_id'] == task_id)


def closing_record(task_id, profile, metadata):
    request = _operation.get()
    if not request or request['task_id'] != task_id:
        return profile, metadata
    return 'head-coordinator', {**(metadata or {}), 'execution_origin': 'board-management',
                                'coordinator_action': request['audit']}


def manage(kb, conn, task_id, *, action=None, expected_version=None, reason=None, **fields):
    actor = coordinator_origin()
    if actor is None:
        raise ValueError('Authenticated native head-coordinator process required; terminals and delegates cannot borrow this tool')
    root, board = require_actor_board(conn, actor)
    task, version = snapshot(conn, task_id)
    if action is None:
        if fields or expected_version is not None or reason is not None:
            raise ValueError('Inspect with task_id alone; then pass its exact version to one action')
        return dict(task_id=task_id, version=version, task=task, actions=list(ACTIONS))
    if action not in ACTIONS or set(fields) - FIELDS[action]:
        raise ValueError('Unknown action or action fields')
    if not isinstance(expected_version, str) or not re.fullmatch('[a-f0-9]{64}', expected_version):
        raise ValueError('Copy expected_version from kanban_manage inspection')
    if not isinstance(reason, str) or not reason.strip() or len(reason) > 8000:
        raise ValueError('A bounded evidence-backed reason is required')
    bridge = getattr(kb.write_txn, '__wrapped__', None)
    if bridge is None or not {'before_write', 'after_write'} <= set(bridge.__code__.co_names):
        raise ValueError('Install the matching native transaction bridge before board management')
    audit = dict(board=board, actor_task=actor['task_id'], actor_run=actor['run_id'],
                 actor_profile=actor['profile'], action=action, expected_version=expected_version,
                 reason=reason, fields=fields, previous_status=task['status'])
    request = dict(actor=actor, task_id=task_id, action=action, fields=fields,
                   expected_version=expected_version, reason=reason, checked=False, finished=False, audit=audit)
    _validate(kb, conn, request)
    token = _operation.set(request)
    try:
        if action == 'complete':
            ok = kb.complete_task(conn, task_id, result=reason, summary=reason,
                                  metadata={**fields.get('metadata', {}), 'execution_origin': 'board-management', 'coordinator_action': audit},
                                  delivery=fields.get('delivery'))
        elif action == 'block':
            ok = kb.block_task(conn, task_id, reason=reason, kind=fields['kind'])
        elif action == 'schedule':
            ok = kb.schedule_task(conn, task_id, reason=reason)
        elif action == 'assign':
            ok = kb.assign_task(conn, task_id, fields.get('assignee'))
        elif action == 'promote':
            from hermes_cli.nixhomeserver_worker_policy import require_release
            require_release(conn, task_id)
            ok, detail = kb.promote_task(conn, task_id, actor='head-coordinator', reason=reason)
            if not ok:
                raise ValueError(detail)
        elif action == 'specify':
            ok = kb.specify_triage_task(conn, task_id, title=fields.get('title'), body=fields.get('body'))
        elif action == 'archive':
            ok = kb.archive_task(conn, task_id)
        else:
            # Ordinary reclaim replenishes failure counters and can signal a
            # live worker. This dead-worker containment does neither.
            with kb.write_txn(conn):
                phase = kb._retry_status_for_run(conn, task_id)
                kb._record_reclaim(conn, task_id, {}, error=reason,
                                   payload={'reason':reason, 'retry_status':phase, 'coordinator_action':audit})
                conn.execute("UPDATE tasks SET status='triage',block_kind='capability',claim_lock=NULL,"
                             "claim_expires=NULL,worker_pid=NULL,worker_started_at=NULL WHERE id=?", (task_id,))
                kb._append_event(conn, task_id, 'blocked', {'kind':'capability', 'reason':reason,
                    'resume_status':phase, 'coordinator_action':audit})
            ok = True
        if not request['checked'] or not request['finished']:
            raise ValueError('Native transaction bridge unavailable; operation was not authorized')
        if not ok:
            raise ValueError('Native operation refused; inspect current state before another action')
    finally:
        _operation.reset(token)
    after, new_version = snapshot(conn, task_id)
    kb.notify_task_updated(conn, task_id, ['status', 'assignee'], board=board)
    return dict(task_id=task_id, action=action, applied=True, status=after['status'], version=new_version)
