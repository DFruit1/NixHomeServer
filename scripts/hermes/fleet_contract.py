"""Structured task contracts shared by native Hermes seams and read-only tools.

Python is required by the existing Hermes lifecycle. No service or dependency is
introduced. Creation events retain authority; rendered prose is a compatibility
view, never a way to amend a structured contract.
"""
import hashlib
import json
import re
from pathlib import Path

TOKEN = r'[A-Za-z0-9_-]{1,80}'
TRACKER_ID = r'[A-Za-z0-9_-]{1,64}:t_[A-Za-z0-9_]{1,80}'


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


def validate(value):
    if (not isinstance(value, dict) or type(value.get('version')) is not int
            or value['version'] != 1
            or set(value) - {'version', 'review', 'plan_author', 'feature', 'requirements'}):
        raise ValueError('workflow requires version=1 and known structured fields')
    if value.get('review') not in (None, 'native-review-v1'):
        raise ValueError('Unknown workflow review contract')
    if value.get('review') and not re.fullmatch(TOKEN, str(value.get('plan_author', ''))):
        raise ValueError('workflow.plan_author must name the actual author token')
    if 'plan_author' in value and (not isinstance(value['plan_author'], str)
                                  or not re.fullmatch(TOKEN, value['plan_author'])):
        raise ValueError('workflow.plan_author must name the actual author token')
    feature = value.get('feature')
    if feature is not None:
        if (not isinstance(feature, dict) or set(feature) - {'tracker', 'role', 'scope', 'stage'}
                or not {'tracker', 'role', 'scope'} <= set(feature)
                or not isinstance(feature['tracker'], str)
                or not re.fullmatch(TRACKER_ID, feature['tracker'])
                or feature['role'] not in {'producer', 'delivery', 'documentary-closure'}
                or not isinstance(feature['scope'], str) or not feature['scope'].strip()
                or len(feature['scope']) > 1000):
            raise ValueError('workflow.feature requires an exact board:tracker, role and requested scope')
        if feature.get('stage', 'integrated') not in {'accepted', 'integrated'}:
            raise ValueError('Automatic delivery supports accepted or integrated scope; live acceptance retains its own gate')
        if feature['role'] == 'delivery' and value.get('review'):
            raise ValueError('Delivery reconciliation is distinct from implementation acceptance')
    requirements = value.get('requirements', {})
    if not isinstance(requirements, dict) or set(requirements) - {'tools', 'imports', 'source_revision', 'review'}:
        raise ValueError('Unknown execution requirements')
    review_requirements = requirements.get('review', {})
    if not isinstance(review_requirements, dict) or set(review_requirements) - {'tools', 'imports'}:
        raise ValueError('Review requirements accept tools and imports only')
    for phase in (requirements, review_requirements):
        for name, pattern in (('tools', TOKEN), ('imports', r'[A-Za-z_][A-Za-z0-9_]{0,79}')):
            items = phase.get(name, [])
            if (not isinstance(items, list) or len(items) > 32
                    or any(not isinstance(item, str) or not re.fullmatch(pattern, item) for item in items)
                    or len(set(items)) != len(items)):
                raise ValueError('Execution requirements need bounded unique tool/module names')
    revision = requirements.get('source_revision')
    if revision is not None and (not isinstance(revision, str)
                                 or not re.fullmatch(r'[a-f0-9]{40}|[a-f0-9]{64}', revision)):
        raise ValueError('source_revision must be an exact full revision')
    return json.loads(json.dumps(value))


def render(body, workflow):
    workflow = validate(workflow)
    text = re.sub(r'(?m)^(?:Workflow|Feature tracker|Feature handoff|Feature role):[^\n]*\n?', '', body or '').rstrip()
    lines = [text] if text else []
    if workflow.get('review'):
        lines.append('Workflow: ' + workflow['review'])
    feature = workflow.get('feature')
    if feature:
        lines.append('Feature tracker: ' + feature['tracker'])
        if feature['role'] == 'delivery':
            lines.append('Feature handoff: delivery')
        if feature['role'] == 'documentary-closure':
            lines.append('Feature role: documentary-closure')
    return '\n'.join(lines) + '\n'


def validate_markers(body, workflow):
    """Require structured native review while preserving legacy feature recovery.

    Maintained CLI recovery controllers deliberately retain Feature markers and
    assessed_defer. Only an explicitly supplied workflow owns those markers.
    """
    if workflow is None:
        if re.search(r'^Workflow: native-review-v1\s*$', body or '', re.M):
            raise ValueError('New Workflow: native-review-v1 implementations require structured workflow')
        return
    markers = re.findall(r'(?m)^(?:Workflow|Feature tracker|Feature handoff|Feature role):[^\n]*', body or '')
    if markers and any(line not in render('', workflow).splitlines() for line in markers):
        raise ValueError('New Workflow/Feature machine markers require matching structured workflow fields')


def validate_create(db, body, workflow, assignee, creator_task_id):
    # Match native profile normalization before deciding whether this is an implementer.
    if isinstance(assignee, str):
        assignee = assignee.strip().lower()
    validate_markers(body, workflow)
    if workflow is not None:
        workflow = validate(workflow)
    creator = load(db, creator_task_id) if creator_task_id else None
    feature = creator.get('feature') if creator else None
    if (feature and feature['role'] == 'delivery'
            and assignee in {'standard-implementer', 'local-implementer'}):
        producer = workflow.get('feature') if workflow else None
        if (not workflow or workflow.get('review') != 'native-review-v1'
                or not producer or producer['role'] != 'producer'
                or producer['tracker'] != feature['tracker'] or producer['scope'] != feature['scope']
                or producer.get('stage', 'integrated') != feature.get('stage', 'integrated')
                or ('plan_author' in creator and workflow.get('plan_author') != creator['plan_author'])):
            raise ValueError('Structured delivery commissioning requires a matching producer workflow, '
                             'tracker, scope, stage and declared plan author')


def validate_board(db, workflow):
    feature = workflow.get('feature') if workflow else None
    if feature:
        files = [row[2] for row in db.execute('PRAGMA database_list') if row[1] == 'main']
        if not files or not files[0] or Path(files[0]).parent.name != feature['tracker'].split(':')[0]:
            raise ValueError('Feature contract must name a tracker on this task board; use qualified outputs across boards')


def creation(db, task_id):
    # Compatibility with portable fixtures predating event history.
    if not db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='task_events'").fetchone():
        return None
    row = db.execute("SELECT payload FROM task_events WHERE task_id=? AND kind='created' ORDER BY id LIMIT 1",
                     (task_id,)).fetchone()
    if not row:
        return None
    raw = row['payload'] or '{}'
    if len(raw) > 65536:
        raise ValueError('Task creation contract exceeds bound')
    payload = json.loads(raw)
    if not isinstance(payload, dict):
        raise ValueError('Malformed task creation event')
    return payload


def load(db, task_id):
    payload = creation(db, task_id)
    return validate(payload['workflow']) if payload and 'workflow' in payload else None


def review_metadata(db, task_id, metadata):
    workflow = load(db, task_id)
    if workflow is None or not workflow.get('review'):
        return metadata
    if not isinstance(metadata, dict):
        raise ValueError('Review handoff requires executed checks and exact source metadata')
    if metadata.get('plan_author', workflow['plan_author']) != workflow['plan_author']:
        raise ValueError('Review author conflicts with the declared task contract')
    return {**metadata, 'plan_author': workflow['plan_author']}


def completion_metadata(db, task_id, metadata, delivery=None):
    """Called inside native complete's write transaction, also by preflight.

    Direct metadata submissions obey the same checks. Missing required delivery
    evidence never turns into a successful routing completion.
    """
    workflow = load(db, task_id)
    if workflow and workflow.get('review'):
        if __package__ == 'hermes_cli':
            from .nixhomeserver_fleet_workflow import acceptance, review_handoff
        else:
            from fleet_workflow import acceptance, review_handoff
        task = db.execute('SELECT assignee FROM tasks WHERE id=?', (task_id,)).fetchone()
        if not isinstance(metadata, dict) or metadata.get('verdict') != 'accept':
            raise ValueError('Structured implementation completes only through independent acceptance')
        acceptance(review_handoff(db, task_id), metadata, task['assignee'])
        checks = metadata.get('checks')
        if (not isinstance(checks, list) or not checks or any(
                not isinstance(c, dict) or not isinstance(c.get('command'), str) or not c['command'].strip()
                or type(c.get('exit_code')) is not int or c['exit_code'] != 0 for c in checks)):
            raise ValueError('Independent acceptance needs successful executed checks')
    feature = workflow.get('feature') if workflow else None
    supplied = (metadata or {}).get('feature_delivery')
    if workflow is None and delivery is None:
        return metadata  # Preserve exact legacy acceptance/disposition contracts.
    if delivery is not None and supplied is not None:
        raise ValueError('Supply delivery once, not both delivery and feature_delivery metadata')
    required = feature and feature['role'] == 'delivery'
    if delivery is None and supplied is None:
        if required:
            raise ValueError('Structured delivery needs its independent evidence and current expected_version')
        return metadata
    if __package__ == 'hermes_cli':
        from .nixhomeserver_feature_contract import prepare_delivery
    else:
        from feature_contract import prepare_delivery
    result = prepare_delivery(db, task_id, feature, delivery if delivery is not None else supplied)
    return {**(metadata or {}), 'feature_delivery': result}
