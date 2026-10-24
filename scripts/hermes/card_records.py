"""Typed card evidence in Hermes' existing append-only event log.

Python is required by the native Hermes lifecycle. No new service, database or
dependency is introduced. Comments are a read-only compatibility input; new
records never manufacture a comment, change lifecycle state or grant authority.
"""
import hashlib
import json
import re

EVENT = 'task_record'
MAX_BYTES = 32768
MAX_ROWS = 1000
SCHEMAS = {
    'decision_owner': ({'owner'}, set()),
    'feature': ({'tracker', 'role'}, set()),
    'recovery': ({'run_id', 'change', 'action'}, set()),
    'merge_back': ({'disposition', 'revision', 'reason'}, {'review_task_id'}),
    'approval': ({'finding_id', 'plan_path', 'plan_sha256', 'decision',
                  'classification', 'verifier_task_id', 'verifier_run_id'}, set()),
    'owner_summary': ({'blocking', 'why_owner', 'unblock'}, set()),
    'owner_reply': ({'text', 'origin'}, {'label'}),
    'feature_input': ({'text'}, set()),
    'deployment_decision': ({'schema_version', 'approved', 'review_task', 'review_run_id', 'scope'}, set()),
    'owner_execution_decision': ({'request_sha256', 'approved', 'executor', 'owner_reply'}, set()),
    'delegated_execution_decision': ({'request_sha256', 'approved', 'executor', 'review_task_id'}, set()),
}


def encoded(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False)


def validate(kind, value):
    if kind not in SCHEMAS or not isinstance(value, dict):
        raise ValueError('Unknown card record kind or non-object value')
    required, optional = SCHEMAS[kind]
    if not required <= set(value) or set(value) - required - optional:
        raise ValueError('Card record fields do not match ' + kind)
    if len(encoded(value).encode()) > MAX_BYTES:
        raise ValueError('Card record exceeds 32768 bytes; attach detailed evidence instead')
    for key, item in value.items():
        if key in {'run_id', 'review_run_id', 'verifier_run_id', 'schema_version'}:
            if type(item) is not int or item <= 0:
                raise ValueError(key + ' must be a positive integer')
        elif key == 'approved':
            if type(item) is not bool:
                raise ValueError('approved must be a boolean')
        elif key == 'scope':
            if not isinstance(item, dict):
                raise ValueError('scope must be an object')
        elif not isinstance(item, str) or not item.strip() or len(item) > 8000:
            raise ValueError(key + ' requires bounded nonempty text')
        elif key not in {'text', 'owner_reply'} and ('\n' in item or '\r' in item):
            raise ValueError(key + ' must be a single line')
        if key.endswith('_sha256') and not re.fullmatch('[a-f0-9]{64}', item):
            raise ValueError(key + ' requires a full SHA256')
        if key in {'review_task', 'review_task_id', 'verifier_task_id'} and not re.fullmatch(r't_[A-Za-z0-9_]+', item):
            raise ValueError(key + ' requires a task ID')
    if kind == 'decision_owner' and value['owner'] not in {'head-coordinator', 'pending-assessment'}:
        raise ValueError('Owner gates use native needs_input, not an ownership marker')
    if kind == 'feature' and (not re.fullmatch(r'[A-Za-z0-9_-]+:t_[A-Za-z0-9_]+', value['tracker'])
                             or value['role'] not in {'producer', 'delivery', 'documentary-closure'}):
        raise ValueError('Feature needs an exact board:tracker and known role')
    if kind == 'merge_back' and (value['disposition'] not in {'merged', 'defer', 'dispose'}
                                or not re.fullmatch(r'[a-f0-9]{40}|[a-f0-9]{64}', value['revision'])):
        raise ValueError('Merge disposition needs a known outcome and full revision')
    if kind == 'approval' and (value['classification'] not in {'automatic', 'delegated', 'owner-required'}
                              or value['decision'] not in {'approve', 'reject', 'defer'}
                              or not value['plan_path'].startswith('/')):
        raise ValueError('Approval needs its classification, decision and absolute plan path')
    if kind == 'owner_reply' and value['origin'] not in {'simplex', 'interactive-owner'}:
        raise ValueError('Record the actual owner reply origin')
    return json.loads(encoded(value))


def _rows(db, tid):
    if not db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='task_events'").fetchone():
        return []  # Portable legacy boards/fixtures can predate native event history.
    rows = db.execute("SELECT id,payload,created_at FROM task_events WHERE task_id=? AND kind=? "
                      'ORDER BY id LIMIT ?', (tid, EVENT, MAX_ROWS + 1)).fetchall()
    if len(rows) > MAX_ROWS:
        raise ValueError('Card record history exceeds the bounded inventory')
    result = []
    for row in rows:
        try:
            if not isinstance(row['payload'], str) or len(row['payload'].encode()) > MAX_BYTES + 1024:
                raise ValueError('Card record envelope exceeds bound')
            payload = json.loads(row['payload'])
            if (set(payload) != {'version', 'kind', 'value', 'actor', 'comment_watermark'}
                    or type(payload['version']) is not int or payload['version'] != 1
                    or payload['actor'] != 'head-coordinator'
                    or type(payload['comment_watermark']) is not int or payload['comment_watermark'] < 0):
                raise ValueError('Invalid card record envelope')
            validate(payload['kind'], payload['value'])
        except (TypeError, KeyError, ValueError) as exc:
            raise ValueError('Invalid native card record; reconcile its source before proceeding') from exc
        result.append({**dict(row), **payload})
    return result


def inspect(db, tid):
    if not db.execute('SELECT 1 FROM tasks WHERE id=?', (tid,)).fetchone():
        raise ValueError('Unknown card record target')
    records = {}
    rows = _rows(db, tid)
    for row in rows:
        records[row['kind']] = {'event_id': row['id'], 'created_at': row['created_at'],
                                'actor': row['actor'], 'value': row['value'],
                                'comment_watermark': row['comment_watermark']}
    watermark = db.execute('SELECT COALESCE(MAX(id),0) FROM task_comments WHERE task_id=?', (tid,)).fetchone()[0]
    version = hashlib.sha256(encoded([rows[-1]['id'] if rows else 0, watermark]).encode()).hexdigest()
    return {'task_id': tid, 'version': version, 'records': records}


def write(kb, db, tid, kind, value, *, actor, expected_version):
    if actor != 'head-coordinator':
        raise ValueError('Only the authenticated coordinator may record card control evidence')
    value = validate(kind, value)
    with kb.write_txn(db):
        before = inspect(db, tid)
        if not isinstance(expected_version, str) or expected_version != before['version']:
            raise ValueError('Card evidence changed; inspect the current record version before writing')
        if kind == 'feature':
            creation = db.execute("SELECT payload FROM task_events WHERE task_id=? AND kind='created' ORDER BY id LIMIT 1", (tid,)).fetchone()
            if creation and 'workflow' in json.loads(creation[0] or '{}'):
                raise ValueError('Immutable structured workflow owns this feature binding')
            from pathlib import Path
            files = [row[2] for row in db.execute('PRAGMA database_list') if row[1] == 'main' and row[2]]
            if files and Path(files[0]).parent.name != value['tracker'].split(':')[0]:
                raise ValueError('Feature record must name a tracker on this board')
        if kind == 'recovery':
            run = db.execute('SELECT id,status,outcome FROM task_runs WHERE task_id=? ORDER BY id DESC LIMIT 1', (tid,)).fetchone()
            if (not run or run['id'] != value['run_id'] or not
                    ({run['status'], run['outcome']} & {'failed', 'crashed', 'timed_out', 'spawn_failed', 'gave_up'})):
                raise ValueError('Recovery receipt must bind the latest actual failed run')
        if kind == 'owner_summary':
            validate_owner_summary(value)
        previous = before['records'].get(kind)
        watermark = db.execute('SELECT COALESCE(MAX(id),0) FROM task_comments WHERE task_id=?', (tid,)).fetchone()[0]
        last_record = max((entry['event_id'] for entry in before['records'].values()), default=0)
        if (previous and previous['value'] == value and previous['event_id'] == last_record
                and previous['comment_watermark'] == watermark):
            return {**before, 'unchanged': True}
        kb._append_event(db, tid, EVENT, {'version': 1, 'kind': kind, 'value': value,
                                        'actor': actor, 'comment_watermark': watermark})
        return inspect(db, tid)


def validate_owner_summary(value):
    # Reuse the owner-alert validator, including its wording and length checks.
    import importlib.util
    from pathlib import Path
    source = Path(__file__).resolve().parents[2] / 'scripts/kanban-owner-alerts.py'
    if __package__ != 'hermes_cli':
        source = Path(__file__).with_name('kanban-owner-alerts.py')
    spec = importlib.util.spec_from_file_location('card_record_owner_alerts', source)
    alerts = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(alerts)
    alerts.check_summary(render('owner_summary', value))


def render(kind, value):
    """Compatibility projection for existing validators, never stored as prose."""
    if kind.endswith('_decision'):
        return encoded({kind: value})
    if kind == 'decision_owner':
        return 'Decision owner: ' + value['owner']
    if kind == 'feature':
        return 'Feature tracker: ' + value['tracker'] + (
            '\nFeature handoff: delivery' if value['role'] == 'delivery' else
            '\nFeature role: documentary-closure' if value['role'] == 'documentary-closure' else '')
    if kind == 'recovery':
        return 'Recovery run: {}\nRecovery change: {}\nRecovery action: {}'.format(value['run_id'], value['change'], value['action'])
    if kind == 'owner_summary':
        return 'Blocking: {}\nWhy owner: {}\nUnblock: {}'.format(value['blocking'], value['why_owner'], value['unblock'])
    if kind == 'owner_reply':
        return value['text']
    if kind == 'feature_input':
        return 'Feature input: ' + value['text']
    if kind == 'merge_back':
        return 'merge-back disposition: {} {} {}'.format(value['disposition'], value['revision'], value['reason'])
    return encoded({kind: value})


def protocol_entries(db, tid, *, limit=1000):
    """Merge typed records and historical comments in their actual write order.

    A record captures the last comment ID it observed. This prevents a later
    owner reply in the same second from being sorted before the decision it
    invalidates. IDs retain their source; no fake comment IDs are introduced.
    """
    comments = db.execute('SELECT id,author,body,created_at FROM task_comments WHERE task_id=? ORDER BY id LIMIT ?', (tid, limit + 1)).fetchall()
    if len(comments) > limit:
        raise ValueError('Historical card evidence exceeds the bounded inventory')
    entries = [({**dict(c), 'source': 'comment'}, (c['id'], 0, 0)) for c in comments]
    for row in _rows(db, tid):
        entries.append(({'id': row['id'], 'author': 'owner' if row['kind'] == 'owner_reply' else row['actor'],
                         'body': render(row['kind'], row['value']), 'created_at': row['created_at'],
                         'source': EVENT, 'record_kind': row['kind']}, (row['comment_watermark'], 1, row['id'])))
    return [entry for entry, _ in sorted(entries, key=lambda item: item[1])]


def context(db, tid):
    state = inspect(db, tid)['records']
    if not state:
        return ''
    pointers = {kind: {'event_id': record['event_id']} for kind, record in state.items()}
    if 'decision_owner' in state:
        pointers['decision_owner'].update(state['decision_owner']['value'])
    return '\nCard records (read with kanban_record; historical evidence is not current permission):\n' + encoded(pointers) + '\n'
