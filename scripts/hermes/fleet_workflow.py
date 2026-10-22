"""Shared fleet lifecycle rules; Python glue for Hermes' native task lifecycle."""
import json
import re

CORE_ROLES = ('head-coordinator', 'standard-implementer', 'feature-reviewer')
WORKFLOW = 'native-review-v1'
TERMINAL = {'done', 'archived'}


def native_contract(body):
    return bool(re.search(r'^Workflow: native-review-v1\s*$', body or '', re.M))


def proactive_allowed(tasks):
    """Reserve one proactive chain and finish actionable repairs first.

    Owner gates and ordinary ongoing implementation do not starve audit intake.
    Existing audits and manual requests are never interrupted by this predicate.
    """
    for task in tasks:
        if task.get('status') in TERMINAL:
            continue
        if task.get('tenant') == 'continuous-improvement':
            return False
        if (task.get('block_kind') == 'capability'
                or task.get('last_outcome') == 'changes_requested'
                or task.get('created_by') in {'fleet-supervisor', 'deadlock-recovery-monitor'}
                or task.get('tenant') == 'technical-recovery'
                or (task.get('status') == 'triage' and task.get('consecutive_failures', 0))):
            return False
    return True


def acceptance(handoff, metadata, reviewer):
    """Bind a new-contract acceptance to its actual native implementer handoff."""
    evidence = handoff.get('metadata') or {}
    independence = metadata.get('independence')
    if (handoff.get('implementer') == reviewer
            or not handoff.get('implementer')
            or handoff.get('reviewer') != reviewer
            or not isinstance(evidence, dict)
            or not isinstance(evidence.get('plan_author'),str)
            or not re.fullmatch(r'[A-Za-z0-9_-]{1,80}',evidence['plan_author'])
            or evidence.get('plan_author') == reviewer
            or not isinstance(evidence.get('revision'),str)
            or not re.fullmatch(r'[a-f0-9]{40}|[a-f0-9]{64}',evidence['revision'])
            or evidence.get('revision') != metadata.get('revision')
            or not isinstance(independence, dict)
            or set(independence) != {'plan_author', 'implementer'}
            or independence['plan_author'] is not False
            or independence['implementer'] is not False):
        raise ValueError('Acceptance needs the handed-off revision and a reviewer who neither'
                         ' authored the plan nor implemented the change')


def review_handoff(db, task_id):
    """Native metadata belongs to the implementer run, not the event payload."""
    event = db.execute("SELECT run_id,payload FROM task_events WHERE task_id=?"
                       " AND kind='review_requested' ORDER BY id DESC LIMIT 1", (task_id,)).fetchone()
    if not event or type(event['run_id']) is not int:
        raise ValueError('Native review needs the actual implementer run binding')
    handoff = json.loads(event['payload'] or '{}')
    run = db.execute('SELECT task_id,profile,status,outcome,metadata FROM task_runs WHERE id=?',
                     (event['run_id'],)).fetchone()
    if (not isinstance(handoff, dict) or not run or run['task_id'] != task_id
            or run['profile'] != handoff.get('implementer')
            or run['status'] != 'review' or run['outcome'] != 'review_requested'):
        raise ValueError('Review event does not bind an ended implementation handoff')
    raw=run['metadata'] or '{}'
    if not isinstance(raw,str) or len(raw)>65536:
        raise ValueError('Implementation handoff metadata exceeds the review bound')
    handoff['metadata'] = json.loads(raw)
    return handoff


def require_native_acceptance(db, task, metadata, native):
    if not native_contract(task['body']):
        return
    if not native or not isinstance(metadata, dict) or metadata.get('verdict') != 'accept':
        raise ValueError('This implementation completes only through independent native acceptance;'
                         ' use request_review, request_changes or retain a missing-input hold')
    acceptance(review_handoff(db, task['id']), metadata, task['assignee'])
