"""Versioned, fail-closed native release contracts for parked Hermes cards.

Python is intentional: these are in-process extensions to Hermes' Python SQLite
lifecycle and its existing supervisor, using the standard library only. A second
Rust backend could not share the native transaction or process-origin checks.
"""
from contextlib import contextmanager, closing
import hashlib
import base64
import json
import os
from pathlib import Path
import re
import sqlite3
import stat
import time

REGISTERED = 'release_conditions_registered'
APPLIED = 'release_conditions_applied'
IGNORED = ('commented', 'attached', 'subscribed', 'unsubscribed', REGISTERED, 'release_output_sealed', 'release_artifact_published')
PARKED = ('blocked', 'scheduled', 'triage', 'todo')
MAX_BYTES = 32768
ARTIFACT_SCHEMA = '''
CREATE TABLE IF NOT EXISTS task_release_artifacts (
 attachment_id INTEGER PRIMARY KEY,
 task_id TEXT NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
 filename TEXT NOT NULL, sha256 TEXT NOT NULL, content BLOB NOT NULL,
 created_at INTEGER NOT NULL
);
'''


def encoded(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), allow_nan=False)


def digest(value):
    return hashlib.sha256(encoded(value).encode()).hexdigest()


def object_json(value):
    result = json.loads(value or '{}')
    if not isinstance(result, dict):
        raise ValueError('Expected a JSON object')
    return result


def task_row(db, tid, schema='main'):
    row = db.execute(f'SELECT * FROM {schema}.tasks WHERE id=?', (tid,)).fetchone()
    if not row or row['status'] == 'archived':
        raise ValueError('Condition task is missing or archived')
    return dict(row)


def hold_version(db, tid):
    task = task_row(db, tid)
    # Commentary is not a new execution contract. Native task fields, lifecycle,
    # run ledger and graph are; no body parser can quietly supply permission.
    task = {k: v for k, v in task.items() if k not in ('updated_at', 'last_activity_at')}
    marks = ','.join('?' for _ in IGNORED)
    event = db.execute(f'SELECT id,kind,payload,run_id FROM task_events WHERE task_id=? '
        f'AND kind NOT IN ({marks}) ORDER BY id DESC LIMIT 1', (tid, *IGNORED)).fetchone()
    run = db.execute('SELECT * FROM task_runs WHERE task_id=? ORDER BY id DESC LIMIT 1', (tid,)).fetchone()
    graph = db.execute('SELECT * FROM task_links WHERE parent_id=? OR child_id=? '
                       'ORDER BY parent_id,child_id', (tid, tid)).fetchall()
    return digest(dict(task=task, event=dict(event) if event else None,
                       run=dict(run) if run else None, graph=[dict(x) for x in graph]))


def load(db, tid):
    row = db.execute('SELECT id,payload FROM task_events WHERE task_id=? AND kind=? '
                     'ORDER BY id DESC LIMIT 1', (tid, REGISTERED)).fetchone()
    if not row:
        return None
    if len(row['payload'] or '') > MAX_BYTES:
        raise ValueError('Release contract exceeds its bound')
    return dict(registration_id=row['id'], **object_json(row['payload']))


def validate(contract):
    if not isinstance(contract, dict) or len(encoded(contract).encode()) > MAX_BYTES // 2:
        raise ValueError('Release contract must be a bounded JSON object')
    if (set(contract) - {'schema_version','action','supplier','reason','predicates','closure','source'}
            or type(contract.get('schema_version')) is not int or contract['schema_version'] != 1
            or contract.get('action') not in ('resume', 'close', 'manual')
            or not isinstance(contract.get('supplier'), str)
            or not re.fullmatch(r'owner|agent|model/provider|external-source-owner\([^\n]{1,120}\)', contract['supplier'])
            or not isinstance(contract.get('reason'), str) or not 1 <= len(contract['reason'].strip()) <= 600
            or not isinstance(contract.get('predicates'), list) or len(contract['predicates']) > 12):
        raise ValueError('Invalid release contract fields')
    if contract['action'] != 'manual' and (contract['supplier'] != 'agent' or not contract['predicates']):
        raise ValueError('Automatic contracts need agent-supplied evidence predicates')
    source=contract.get('source')
    if source is not None and (not isinstance(source,dict) or set(source)!={'revision','tree'}
            or any(not isinstance(source[k],str) or not re.fullmatch('[a-f0-9]{40}|[a-f0-9]{64}',source[k]) for k in source)):
        raise ValueError('Source binding requires exact revision and tree hashes')
    for p in contract['predicates']:
        if (not isinstance(p, dict) or not isinstance(p.get('board'), str)
                or not re.fullmatch(r'[a-z0-9][a-z0-9_-]{0,63}', p['board'])
                or not isinstance(p.get('task_id'), str)
                or not re.fullmatch(r't_[A-Za-z0-9_]{1,80}', p['task_id'])):
            raise ValueError('Predicate needs an explicit board and task')
        base = {'type','board','task_id'}
        if p.get('type') == 'task_result':
            if (set(p) != base | {'after_run_id','metadata'} or type(p['after_run_id']) is not int
                    or p['after_run_id'] < 0 or not isinstance(p['metadata'], dict) or not p['metadata']):
                raise ValueError('Result predicate needs a run boundary and exact metadata subset')
        elif p.get('type') == 'review_accepted':
            if (set(p) != base | {'run_id','revision','scope'} or type(p['run_id']) is not int
                    or p['run_id'] <= 0 or not isinstance(p['revision'], str) or not p['revision'].strip()
                    or not isinstance(p['scope'], dict) or not p['scope']):
                raise ValueError('Acceptance needs an exact run, revision and metadata scope')
        elif p.get('type') == 'attachment':
            if (set(p) != base | {'filename','sha256'} or not isinstance(p['filename'], str)
                    or not p['filename'] or Path(p['filename']).name != p['filename']
                    or not isinstance(p['sha256'], str) or not re.fullmatch('[a-f0-9]{64}', p['sha256'])):
                raise ValueError('Attachment needs an exact basename and SHA256')
        elif p.get('type') == 'native_wait':
            if set(p)!=base|{'handler'} or p['handler'] not in ('technical-recovery','board-progress'):
                raise ValueError('Native wait needs its original technical-recovery/board-progress handler')
        elif p.get('type') == 'task_event':
            if (set(p) != base | {'after_run_id','until'} or type(p['after_run_id']) is not int
                    or p['after_run_id'] < 0 or p['until'] not in ('started','completed')):
                raise ValueError('Event wait needs a run boundary and started/completed event')
        else:
            raise ValueError('Unknown release predicate')
    if contract['action'] == 'close':
        c = contract.get('closure')
        if (not isinstance(c, dict) or set(c) != {'kind','summary'}
                or c['kind'] not in ('diagnostic','bookkeeping')
                or not isinstance(c['summary'], str) or not 1 <= len(c['summary'].strip()) <= 1000
                or not any(p['type'] == 'review_accepted' for p in contract['predicates'])):
            raise ValueError('Closure needs an explicit diagnostic contract and independent exact-scope acceptance')
    elif 'closure' in contract:
        raise ValueError('Only diagnostic closure carries a closure contract')
    return contract


def require_parked(db, tid):
    task = task_row(db, tid)
    if task['status'] not in PARKED or any(task[k] is not None for k in
            ('current_run_id','worker_pid','claim_lock','claim_expires')):
        raise ValueError('Only an unleased parked task can register conditions')
    if db.execute("SELECT 1 FROM task_runs WHERE task_id=? AND (ended_at IS NULL OR "
                  "status IN ('running','pending','claimed','starting')) LIMIT 1", (tid,)).fetchone():
        raise ValueError('Task has an active native run')
    return task


def require_automatic(kb, db, tid, contract):
    task = require_parked(db, tid)
    if (task['status'] not in ('blocked','scheduled') or task['block_kind'] not in (None,'dependency','capability')
            or (contract['action']=='resume' and (task['consecutive_failures'] != 0 or task['block_recurrences'] != 0))
            or '[FEATURE TRACKER' in task['title'].upper()
            or (task['body'] or '').lstrip().startswith('ASK:') or task['goal_mode']):
        raise ValueError('Owner/provider, active, recurring or spent holds require manual recovery')
    reconciliation=contract['action']=='resume' and any(p['type'] in ('task_event','native_wait') for p in contract['predicates'])
    allowed_reconciliation=task['tenant']=='technical-recovery' or (task['tenant']=='board-progress' and all(p['type']=='native_wait' for p in contract['predicates']))
    if reconciliation and (task['assignee']!='head-coordinator' or not allowed_reconciliation):
        raise ValueError('Event observations can wake only their coordinator recovery owner')
    if task['workspace_kind'] in ('dir','worktree'):
        if not task['workspace_path']:
            raise ValueError('Automatic source work requires a prepared source workspace')
        path=Path(task['workspace_path'])
        if path.resolve()!=path or not path.is_dir():
            raise ValueError('Prepared source is missing or moved')
        if not reconciliation or contract.get('source') is not None:
            import subprocess
            source=contract.get('source')
            if not source:raise ValueError('Automatic source work requires an exact revision/tree binding')
            def git(*args):
                return subprocess.check_output(['git','-C',str(path),*args],text=True,timeout=5).strip()
            if (git('rev-parse','HEAD')!=source['revision']
                    or git('rev-parse','HEAD^{tree}')!=source['tree']
                    or git('status','--porcelain','--untracked-files=all')):
                raise ValueError('Prepared source changed after its condition contract')
    from hermes_cli import nixhomeserver_worker_policy as policy
    from hermes_cli.nixhomeserver_resume_recovered import require_iteration_ordinary_unblock
    if contract['action']=='resume':policy.require_release(db, tid)
    if contract['action']=='resume':require_iteration_ordinary_unblock(db, tid)
    if contract['action'] == 'close':
        from hermes_cli.nixhomeserver_fleet_contract import load as workflow_contract
        if workflow_contract(db,tid) is not None or task.get('workflow_template_id') or task.get('current_step_key'):
            raise ValueError('Structured workflow cards retain their original completion contract')
        from hermes_cli.nixhomeserver_feature_contract import _inventory as feature_inventory
        board=Path(db.execute('PRAGMA database_list').fetchone()['file']).parent.name
        _,_,membership=feature_inventory(db,board)
        if any(tid in members for members in membership.values()):
            raise ValueError('Legacy feature members retain their original completion contract')
        created = db.execute("SELECT payload FROM task_events WHERE task_id=? AND kind='created' ORDER BY id LIMIT 1",(tid,)).fetchone()
        original = object_json(created['payload']) if created else {}
        feature = (task['body'] or '') + '\n' + '\n'.join(r[0] or '' for r in db.execute("SELECT body FROM task_comments WHERE task_id=? AND (body LIKE '%Feature handoff:%' OR body LIKE '%Feature role:%' OR body LIKE '%Workflow:%' OR body LIKE '%Feature tracker:%') LIMIT 101",(tid,)))
        if (original.get('assignee') != 'head-coordinator'
                or task.get('completion_contract') not in (None,'local-only')
                or re.search(r'(?m)^(?:Workflow:|Feature tracker:|Feature handoff:|Feature role:)',feature)
                or task['assignee'] != 'head-coordinator' or task['tenant'] != 'technical-recovery'
                or 'Workflow: native-review-v1' in (task['body'] or '')
                or db.execute('SELECT 1 FROM task_links WHERE parent_id=? LIMIT 1', (tid,)).fetchone()):
            raise ValueError('Automatic closure is limited to opted-in coordinator diagnostic leaves')
    return task


def require_actor(db):
    from hermes_cli import nixhomeserver_worker_origin as origin
    # Public CLI operators retain their normal authority. A native model terminal
    # cannot turn this helper into a sibling mutation capability.
    origin.require_ordinary_unblock()
    # dispatcher_owned() describes context eligibility, not a worker binding:
    # its default is also true in an ordinary operator CLI or no-agent process.
    if os.environ.get('HERMES_KANBAN_TASK') or os.environ.get('HERMES_DELEGATED_CHILD_CONTEXT'):
        raise ValueError('Register conditions through the authenticated native coordinator tool')
    return {'kind':'interactive-operator'}


def register(kb, db, root, tid, contract, expected_version, *, actor=None):
    validate(contract)
    actor = require_actor(db) if actor is None else coordinator_actor(db, actor)
    with kb.write_txn(db):
        return _register_locked(kb,db,tid,contract,expected_version,actor)


def _register_locked(kb,db,tid,contract,expected_version,actor):
    require_parked(db, tid)
    if hold_version(db, tid) != expected_version:
        raise ValueError('Parked task changed; inspect and register its current hold')
    if contract['action'] != 'manual':
        require_automatic(kb, db, tid, contract)
    if contract['action'] == 'close':
        required = dict(task_id=tid,hold_version=expected_version,kind=contract['closure']['kind'],
            summary_sha256=hashlib.sha256(contract['closure']['summary'].encode()).hexdigest())
        if not any(p['type']=='review_accepted' and p['scope'].get('diagnostic_closure')==required
                   for p in contract['predicates']):
            raise ValueError('Closure reviewer must accept this exact hold and closure contract')
    previous = load(db, tid)
    if previous and previous['hold_version'] == expected_version and previous['contract'] == contract:
        return previous
    kb._append_event(db, tid, REGISTERED, dict(schema_version=1, hold_version=expected_version,
                                              contract=contract, actor=actor))
    return load(db, tid)

def board_path(root, board):
    path = Path(root) / 'kanban/boards' / board / 'kanban.db'
    if (path.resolve() != path.absolute() or not path.is_file()
            or not path.with_name('board.json').is_file()):
        raise ValueError('Evidence board is missing or uses a symlink')
    manifest=object_json(path.with_name('board.json').read_text())
    if manifest.get('archived'):
        raise ValueError('Evidence board is archived')
    return path


@contextmanager
def evidence_transaction(kb, db, root, contract):
    """Reserve all evidence writers before reading; never write foreign boards.

    Dedicated BEGIN IMMEDIATE connections reserve each foreign
    writer; ATTACH mode=ro provides evidence reads in the owner transaction. This prevents a concurrent rejection/reopen during apply;
    only the owner's main database is mutated. Any unavailable lock fails closed.
    """
    if db.in_transaction:
        raise ValueError('Release requires its own native transaction')
    main = Path(db.execute('PRAGMA database_list').fetchone()['file'])
    schemas = {}
    attached = []
    guards = []
    try:
        for board in sorted({p['board'] for p in contract['predicates']}):
            path = board_path(root, board)
            if path == main:
                schemas[board] = 'main'
            else:
                schema = 'release_evidence_' + str(len(attached))
                # Reserve foreign writers on a dedicated tracked connection.
                # The attached handle is deliberately read-only; native main
                # connection policies need not grant foreign write access.
                from hermes_cli.sqlite_safe_read import connect_tracked
                guard = connect_tracked(path.as_uri()+'?mode=rw',uri=True,tracking_path=path,isolation_level=None,timeout=.25)
                guard.execute('PRAGMA busy_timeout=250')
                guards.append(guard)
                guard.execute('BEGIN IMMEDIATE')
                db.execute(f'ATTACH DATABASE ? AS {schema}', (path.as_uri() + '?mode=ro',))
                attached.append(schema); schemas[board] = schema
        with kb.write_txn(db):
            yield schemas
    finally:
        try:
            for schema in reversed(attached):
                db.execute(f'DETACH DATABASE {schema}')
        finally:
            for guard in reversed(guards):
                guard.rollback(); guard.close()


def latest_run(db, schema, tid):
    row = db.execute(f'SELECT * FROM {schema}.task_runs WHERE task_id=? ORDER BY id DESC LIMIT 1', (tid,)).fetchone()
    if not row:
        raise ValueError('Evidence has no native run')
    return dict(row)


def completed_run(db, schema, task, run, *, sealed=True):
    if (task['status'] != 'done' or task['current_run_id'] is not None
            or run['status'] not in ('done','completed') or run['outcome'] != 'completed'
            or not isinstance(run['profile'], str) or not run['profile']
            or type(run['started_at']) is not int or type(run['ended_at']) is not int
            or run['started_at'] <= 0 or run['ended_at'] < run['started_at']):
        raise ValueError('Evidence is not a completed native result')
    for kind in ('claimed','completed'):
        if not db.execute(f'SELECT 1 FROM {schema}.task_events WHERE task_id=? AND run_id=? '
                          'AND kind=? LIMIT 1', (task['id'],run['id'],kind)).fetchone():
            raise ValueError('Evidence lacks matching native claim/completion')
    metadata = object_json(run['metadata'])
    if sealed:
        seal = db.execute(f"SELECT payload FROM {schema}.task_events WHERE task_id=? AND run_id=? AND kind='release_output_sealed' ORDER BY id LIMIT 1",(task['id'],run['id'])).fetchone()
        if not seal or object_json(seal['payload']).get('metadata_sha256') != digest(metadata):
            raise ValueError('Result lacks an immutable native completion seal; retain manual review')
    return metadata


def contains(value, expected):
    # Exact JSON scalar types matter (True is not an integer exit code).
    if isinstance(expected, dict):
        return isinstance(value, dict) and all(k in value and contains(value[k], v) for k,v in expected.items())
    return type(value) is type(expected) and value == expected


def attachment_bytes(root, board, tid, row):
    path = Path(row['stored_path'])
    directory = Path(root) / 'kanban/boards' / board / 'attachments' / tid
    if not path.is_absolute():
        path = directory / path
    if path.resolve() != path.absolute() or not path.is_relative_to(directory):
        raise ValueError('Attachment is missing or outside its native directory')
    with os.fdopen(os.open(path,os.O_RDONLY|os.O_NOFOLLOW),'rb') as stream:
        before = os.fstat(stream.fileno())
        if not stat.S_ISREG(before.st_mode) or before.st_size > 65536:
            raise ValueError('Immutable release artifacts must be regular files up to 64 KiB')
        content=stream.read(65537)
        after = os.fstat(stream.fileno())
    if (len(content)>65536 or
            (before.st_ino,before.st_size,before.st_mtime_ns,before.st_ctime_ns) !=
            (after.st_ino,after.st_size,after.st_mtime_ns,after.st_ctime_ns)):
        raise ValueError('Attachment changed during verification')
    return content


def evaluate(db, root, task, contract, schemas):
    proofs = []
    for p in contract['predicates']:
        schema = schemas[p['board']]
        source = task_row(db, p['task_id'], schema)
        if p['type']=='native_wait':
            if schema!='main' or p['task_id']!=task['id'] or p['handler']!=task['tenant']:
                raise ValueError('Native wait can qualify only its original coordinator owner/handler')
            from hermes_cli.nixhomeserver_recovery_wait import require_resume as recovery_wait
            from hermes_cli.nixhomeserver_board_progress import require_resume as dispatch_wait
            proof=(recovery_wait if p['handler']=='technical-recovery' else dispatch_wait)(db,task['id'])
            if not proof:raise ValueError('No native wait receipt qualifies this owner')
            event=db.execute("SELECT id FROM task_events WHERE task_id=? AND kind='scheduled' ORDER BY id DESC LIMIT 1",(task['id'],)).fetchone()
            proofs.append(dict(type='native_wait',handler=p['handler'],schedule_event_id=event['id'],native_proof=proof))
            continue
        if source['id'] == task['id'] and schema == 'main':
            raise ValueError('A task cannot provide its own release evidence')
        if p['type'] == 'attachment':
            row = db.execute(f'SELECT * FROM {schema}.task_attachments WHERE task_id=? AND filename=? '
                             'ORDER BY id DESC LIMIT 1', (p['task_id'],p['filename'])).fetchone()
            if not row:
                raise ValueError('Required native attachment is absent')
            publication = db.execute(f'SELECT payload FROM {schema}.task_events WHERE task_id=? '
                "AND kind='release_artifact_published' AND json_extract(payload,'$.attachment_id')=? ORDER BY id LIMIT 1",
                (p['task_id'],row['id'])).fetchone()
            artifact = object_json(publication['payload']) if publication else {}
            canonical=db.execute(f'SELECT * FROM {schema}.task_release_artifacts WHERE task_id=? AND attachment_id=?',(p['task_id'],row['id'])).fetchone()
            content=canonical['content'] if canonical else b''
            if (not canonical or canonical['sha256']!=p['sha256'] or artifact.get('filename')!=p['filename'] or artifact.get('sha256')!=p['sha256']
                    or hashlib.sha256(content).hexdigest()!=p['sha256']):
                raise ValueError('Attachment needs a matching immutable native publication')
            proofs.append(dict(type=p['type'], board=p['board'], task_id=p['task_id'], attachment_id=row['id'],sha256=p['sha256']))
            continue
        run = latest_run(db,schema,p['task_id'])
        if p['type'] == 'task_event' and p['until'] == 'started':
            if run['id'] <= p['after_run_id'] or type(run['started_at']) is not int or run['started_at'] <= 0:
                raise ValueError('Still awaiting a new native execution')
            claim = db.execute(f"SELECT 1 FROM {schema}.task_events WHERE task_id=? AND run_id=? AND kind='claimed'", (p['task_id'],run['id'])).fetchone()
            events = db.execute(f"SELECT id,payload FROM {schema}.task_events WHERE task_id=? AND run_id=? AND kind IN ('spawned','worker_registered') ORDER BY id DESC LIMIT 16", (p['task_id'],run['id'])).fetchall()
            event = next((e for e in events if type(object_json(e['payload']).get('pid')) is int
                          and object_json(e['payload'])['pid'] > 0 and object_json(e['payload']).get('started_at')),None)
            if not claim or not event:
                raise ValueError('Still awaiting native claim and worker-start evidence')
            proofs.append(dict(type=p['type'],board=p['board'],task_id=p['task_id'],run_id=run['id'],event_id=event['id']))
            continue
        metadata = completed_run(db,schema,source,run,sealed=p['type']!='task_event')
        if p['type']=='task_result' and metadata.get('verdict') not in (None,'accept'):
            raise ValueError('A rejected or unknown result cannot release this hold')
        if p['type'] in ('task_result','task_event'):
            if run['id'] <= p['after_run_id'] or not contains(metadata,p.get('metadata',{})):
                raise ValueError('Completed result does not satisfy the expected output')
        else:
            if (run['id'] != p['run_id'] or run['profile'] not in ('feature-reviewer','project-auditor')
                    or run['profile'] == task['assignee'] or source['assignee'] != run['profile']
                    or metadata.get('verdict') != 'accept' or metadata.get('revision') != p['revision']
                    or not contains(metadata,p['scope'])):
                raise ValueError('Review lacks exact independent accepted revision/scope')
            claim=db.execute(f"SELECT payload FROM {schema}.task_events WHERE task_id=? AND run_id=? AND kind='claimed' ORDER BY id DESC LIMIT 1",(source['id'],run['id'])).fetchone()
            native_review=claim and object_json(claim['payload']).get('source_status')=='review'
            qualified=(run['profile']=='feature-reviewer' and source['tenant'] not in ('continuous-improvement','review-question')) or (run['profile']=='project-auditor' and source['tenant']=='verification') or native_review
            if not qualified:
                raise ValueError('Acceptance needs qualified native verification provenance')
            checks = metadata.get('checks')
            if not isinstance(checks,list) or not checks or any(not isinstance(c,dict)
                    or not isinstance(c.get('command'),str) or not c['command'].strip()
                    or type(c.get('exit_code')) is not int or c['exit_code'] != 0 for c in checks):
                raise ValueError('Acceptance needs executed passing checks')
            if run['profile'] == 'feature-reviewer':
                handoff = db.execute(f"SELECT payload FROM {schema}.task_events WHERE task_id=? AND kind='review_requested' ORDER BY id DESC LIMIT 1",(source['id'],)).fetchone()
                if handoff:
                    h=object_json(handoff['payload'])
                    if not h.get('implementer') or h['implementer']==run['profile'] or h.get('reviewer',run['profile'])!=run['profile']:
                        raise ValueError('Native handoff does not prove independent review')
            if run['profile'] == 'project-auditor':
                independence=metadata.get('independence')
                if (not isinstance(independence,dict) or set(independence)!={'plan_author','implementer'}
                        or any(value is not False for value in independence.values())):
                    raise ValueError('Auditor acceptance lacks independent authorship evidence')
        proofs.append(dict(type=p['type'],board=p['board'],task_id=p['task_id'],run_id=run['id'],metadata_sha256=digest(metadata)))
    return proofs


def apply(kb, db, root, tid, registration_id):
    require_actor(db)
    registration = load(db, tid)
    if not registration or registration['registration_id'] != registration_id:
        raise ValueError('Release registration was replaced or is absent')
    contract = validate(registration['contract'])
    if contract['action'] == 'manual':
        raise ValueError('Manual gate: ' + contract['reason'])
    with evidence_transaction(kb,db,root,contract) as schemas:
        applied = db.execute('SELECT payload FROM task_events WHERE task_id=? AND kind=? '
                             "AND json_extract(payload,'$.registration_id')=? ORDER BY id DESC LIMIT 1",
                             (tid,APPLIED,registration_id)).fetchone()
        if applied:
            return dict(already_applied=True, **object_json(applied['payload']))
        current = load(db,tid)
        if current != registration or hold_version(db,tid) != registration['hold_version']:
            raise ValueError('Registered hold changed; no transition performed')
        task = require_automatic(kb,db,tid,contract)
        proofs = evaluate(db,root,task,contract,schemas)
        parents = db.execute('SELECT l.parent_id,t.status FROM task_links l '
                            'LEFT JOIN tasks t ON t.id=l.parent_id WHERE l.child_id=?',(tid,)).fetchall()
        if any(p['status'] != 'done' for p in parents):
            raise ValueError('A required parent result is missing, archived or unfinished')
        if contract['action'] == 'close':
            status = 'done'
            db.execute("UPDATE tasks SET status='done',completed_at=?,result=? WHERE id=?",
                       (int(time.time()),contract['closure']['summary'],tid))
            # A system closure event is not a fabricated worker run/verdict.
            kb._append_event(db,tid,'diagnostic_closed',dict(registration_id=registration_id,
                summary=contract['closure']['summary'],kind=contract['closure']['kind']))
        else:
            from hermes_cli.nixhomeserver_board_progress import require_resume
            from hermes_cli.nixhomeserver_recovery_wait import require_resume as require_wait
            require_resume(db,tid); require_wait(db,tid)
            status = kb._resume_status_from_events(db,tid) if task['status'] == 'blocked' else 'ready'
            db.execute('UPDATE tasks SET status=? WHERE id=?',(status,tid))
        receipt = dict(registration_id=registration_id,hold_version=registration['hold_version'],
                       action=contract['action'],status=status,proofs=proofs,actor=dict(kind='native-condition-api',pid=os.getpid()))
        kb._append_event(db,tid,APPLIED,receipt)
        return receipt


def inspect(root):
    result = dict(ready=[],waiting=[],manual=[],unregistered=0)
    paths = sorted((Path(root)/'kanban/boards').glob('*/board.json'))
    if len(paths) > 32:
        raise ValueError('Release inventory exceeds 32 boards')
    for manifest in paths:
        if manifest.parent.name.startswith(('_','.')) or object_json(manifest.read_text()).get('archived'):
            continue
        path = board_path(root,manifest.parent.name)
        with closing(sqlite3.connect(path.as_uri()+'?mode=ro',uri=True,timeout=1)) as db:
            db.row_factory=sqlite3.Row;db.execute('PRAGMA query_only=ON');db.execute('BEGIN')
            rows=db.execute("SELECT id FROM tasks WHERE status IN ('blocked','scheduled','triage','todo') ORDER BY id LIMIT 1001").fetchall()
            if len(rows)>1000:raise ValueError('Release inventory exceeds 1000 parked tasks per board')
            for row in rows:
                registration=load(db,row['id'])
                if not registration:
                    result['unregistered']+=1;continue
                entry=dict(board=manifest.parent.name,task_id=row['id'],registration_id=registration['registration_id'])
                contract=validate(registration['contract'])
                if hold_version(db,row['id'])!=registration['hold_version']:
                    result['waiting'].append(dict(entry,reason='Registered hold changed; coordinator must reassess'))
                    continue
                if contract['action']=='manual':
                    result['manual'].append(dict(entry,supplier=contract['supplier'],reason=contract['reason']));continue
                # Read-only inventory is advisory. Native apply is the only
                # transition path and repeats all checks under writer reservations.
                result['ready'].append(dict(entry,native_handlers=sorted({p['handler'] for p in contract['predicates'] if p['type']=='native_wait'})))
    return result


def cli(args, kb, kbc):
    with kbc.connect_closing() as db:
        main=Path(db.execute('PRAGMA database_list').fetchone()['file'])
        root=main.parents[3]
        if args.conditions_action=='migrate':
            raw=Path(args.file).read_bytes()
            if len(raw)>1024*1024:raise ValueError('Migration manifest exceeds 1 MiB')
            result=migrate(kb,db,root,json.loads(raw))
        elif args.conditions_action=='show':
            result=dict(hold_version=hold_version(db,args.task_id),release_conditions=load(db,args.task_id))
        elif args.conditions_action=='artifact':
            row=db.execute('SELECT * FROM task_release_artifacts WHERE task_id=? AND attachment_id=?',(args.task_id,args.attachment_id)).fetchone()
            if not row:raise ValueError('Immutable artifact is absent')
            result=dict(filename=row['filename'],sha256=row['sha256'],content_base64=base64.b64encode(row['content']).decode())
        elif args.conditions_action=='publish':
            result=publish(kb,db,root,args.task_id,args.attachment_id,args.sha256,args.classification)
        elif args.conditions_action=='register':
            raw=Path(args.file).read_bytes()
            if len(raw)>MAX_BYTES:raise ValueError('Release contract file exceeds bound')
            result=register(kb,db,root,args.task_id,json.loads(raw),args.conditions_version)
        else:
            result=apply(kb,db,root,args.task_id,args.registration_id)
        print(json.dumps(result,sort_keys=True))
    return 0


def coordinator_actor(db, actor):
    from hermes_cli.nixhomeserver_resume_recovered import coordinator_origin, require_actor_board
    if not actor or coordinator_origin()!=actor:
        raise ValueError('Authenticated native coordinator required')
    require_actor_board(db,actor)
    return dict(kind='native-coordinator',task_id=actor['task_id'],run_id=actor['run_id'],board=actor['board'])


def seal_output(db, tid, run_id):
    """Called only by native completed-event publication in its write transaction.

    Existing historical outputs are not retroactively blessed. Editing a completed
    run later cannot change the immutable digest supplied by this receipt.
    """
    if run_id is None:
        return
    run=db.execute('SELECT metadata FROM task_runs WHERE id=? AND task_id=?',(run_id,tid)).fetchone()
    if run:
        db.execute("INSERT INTO task_events(task_id,run_id,kind,payload,created_at) VALUES(?,?,'release_output_sealed',?,?)",
            (tid,run_id,encoded(dict(schema_version=1,metadata_sha256=digest(object_json(run['metadata'])))),int(time.time())))


def publish(kb, db, root, tid, attachment_id, checksum, classification, *, actor=None):
    actor=require_actor(db) if actor is None else coordinator_actor(db,actor)
    if classification!='non-secret' or not isinstance(checksum,str) or not re.fullmatch('[a-f0-9]{64}',checksum):
        raise ValueError('Publish only an explicitly classified non-secret exact-hash artifact')
    with kb.write_txn(db):
        task=task_row(db,tid)
        if task['assignee']=='local-implementer':
            raise ValueError('Credential-lane attachments cannot be published as release evidence')
        row=db.execute('SELECT * FROM task_attachments WHERE task_id=? AND id=?',(tid,attachment_id)).fetchone()
        if not row:raise ValueError('Native attachment is absent')
        board=Path(db.execute('PRAGMA database_list').fetchone()['file']).parent.name
        content=attachment_bytes(root,board,tid,row)
        if hashlib.sha256(content).hexdigest()!=checksum:
            raise ValueError('Native attachment hash changed')
        previous=db.execute("SELECT payload FROM task_events WHERE task_id=? AND kind='release_artifact_published' AND json_extract(payload,'$.attachment_id')=? ORDER BY id LIMIT 1",(tid,attachment_id)).fetchone()
        result=dict(schema_version=1,attachment_id=attachment_id,filename=row['filename'],sha256=checksum,
                    actor=actor)
        if previous:
            if object_json(previous['payload']).get('sha256')!=checksum:
                raise ValueError('A published artifact cannot be replaced')
            return dict(attachment_id=attachment_id,sha256=checksum,already_published=True)
        db.execute('INSERT INTO task_release_artifacts(attachment_id,task_id,filename,sha256,content,created_at) VALUES(?,?,?,?,?,?)',(attachment_id,tid,row['filename'],checksum,content,int(time.time())))
        kb._append_event(db,tid,'release_artifact_published',result)
        return dict(attachment_id=attachment_id,sha256=checksum)


def scan(root, *, cursor=0, limit=4):
    """Bounded SYSTEM scan; native apply repeats every predicate and gate.

    Waiting is a normal outcome, not a failed recovery attempt. Rotate candidates
    to prevent a permanently missing input from starving a later satisfied wait.
    """
    import subprocess
    inventory=inspect(root)
    candidates=inventory.pop('ready')
    inventory['results']=[]
    inventory['automatic']=len(candidates)
    if candidates:
        cursor%=len(candidates)
        selected=(candidates[cursor:]+candidates[:cursor])[:limit]
        policy_path=Path(root)/'state/fleet/handlers.json'
        policy=object_json(policy_path.read_text()) if policy_path.is_file() else {}
        for candidate in selected:
            if any(policy.get(handler,{}).get('enabled') is not True for handler in candidate.get('native_handlers',[])):
                inventory['results'].append(dict(candidate,state='waiting',reason='Original native wait handler is paused'))
                continue
            command=['hermes','--profile','default','kanban','--board',candidate['board'],
                     'conditions','apply',candidate['task_id'],'--registration-id',str(candidate['registration_id'])]
            try:
                process=subprocess.run(command,capture_output=True,text=True,timeout=15,
                    env=dict(os.environ,HERMES_HOME=str(root),HERMES_KANBAN_HOME=str(root)))
                receipt=json.loads(process.stdout) if process.returncode==0 else None
                if receipt:
                    path=board_path(root,candidate['board'])
                    with closing(sqlite3.connect(path.as_uri()+'?mode=ro',uri=True,timeout=1)) as readback:
                        row=readback.execute("SELECT payload FROM task_events WHERE task_id=? AND kind=? AND json_extract(payload,'$.registration_id')=? ORDER BY id DESC LIMIT 1",(candidate['task_id'],APPLIED,candidate['registration_id'])).fetchone()
                        if not row or object_json(row[0])!={k:v for k,v in receipt.items() if k!='already_applied'}:
                            raise ValueError('Condition application lacks matching native readback')
                inventory['results'].append(dict(candidate,state='applied' if receipt else 'waiting',
                    receipt=receipt,reason=process.stderr.strip()[-1000:] if process.returncode else None))
            except (OSError,ValueError,subprocess.SubprocessError) as exc:
                inventory['results'].append(dict(candidate,state='error',reason=type(exc).__name__))
        cursor=(cursor+len(selected))%len(candidates)
    inventory['cursor']=cursor
    return inventory


def migrate(kb, db, root, manifest):
    """Reviewed explicit migration through native APIs, never runtime inference.

    Every rewrite retains a full native attachment with the old task, comments,
    events and runs. Registration and edit share the same owner CAS transaction.
    No comments, counters, graph or historical evidence are removed or rewritten.
    """
    actor=require_actor(db)
    board=Path(db.execute('PRAGMA database_list').fetchone()['file']).parent.name
    if (not isinstance(manifest,dict) or set(manifest)!={'schema_version','board','records'}
            or manifest['schema_version']!=1 or manifest['board']!=board
            or not isinstance(manifest['records'],list) or len(manifest['records'])>200):
        raise ValueError('Migration needs a bounded versioned own-board manifest')
    records=manifest['records']
    seen=set()
    for record in records:
        if not isinstance(record,dict) or set(record)!={'task_id','expected_version','contract','title','body'}:
            raise ValueError('Migration records require exact hold, condition contract and reviewed title/body')
        if record['task_id'] in seen:raise ValueError('Duplicate migration task')
        seen.add(record['task_id']);validate(record['contract'])
        if (not isinstance(record['title'],str) or not 1<=len(record['title'])<=60
                or not isinstance(record['body'],str) or not record['body'].strip() or len(record['body'])>32000):
            raise ValueError('Migration rewrite exceeds its concise card bounds')
    results=[]
    for record in records:
        tid=record['task_id'];attachment_path=None
        try:
            with kb.write_txn(db):
                task=require_parked(db,tid)
                previous=load(db,tid)
                if (previous and previous['contract']==record['contract'] and task['title']==record['title']
                        and task['body']==record['body'] and previous['hold_version']==hold_version(db,tid)):
                    results.append(dict(task_id=tid,state='already_registered',registration_id=previous['registration_id']));continue
                if hold_version(db,tid)!=record['expected_version']:
                    raise ValueError('Migration hold changed; re-read and reassess this card')
                schedule=db.execute("SELECT payload FROM task_events WHERE task_id=? AND kind='scheduled' ORDER BY id DESC LIMIT 1",(tid,)).fetchone()
                schedule_reason=object_json(schedule['payload']).get('reason','') if schedule else ''
                native_wait=task['status']=='scheduled' and isinstance(schedule_reason,str) and schedule_reason.startswith(('Recovery wait: ','Dispatch wait: '))
                if native_wait and (task['title']!=record['title'] or task['body']!=record['body']):
                    raise ValueError('Native event waits retain their exact title/body; register conditions without rewriting that receipt')
                markers=('Workflow:','Recovery mode:','Feature tracker:','Feature handoff:','Feature role:','Dispatch policy:')
                before_markers=[line for line in (task['body'] or '').splitlines() if line.startswith(markers)]
                after_markers=[line for line in record['body'].splitlines() if line.startswith(markers)]
                if before_markers!=after_markers:
                    raise ValueError('Migration must preserve native workflow/recovery/feature markers')
                if task['block_kind']=='needs_input' and not record['body'].lstrip().startswith('ASK:'):
                    raise ValueError('Migration cannot remove an owner ask')
                snapshot=dict(task=task,comments=[dict(r) for r in db.execute('SELECT * FROM task_comments WHERE task_id=? ORDER BY id',(tid,))],
                    events=[dict(r) for r in db.execute('SELECT * FROM task_events WHERE task_id=? ORDER BY id',(tid,))],
                    runs=[dict(r) for r in db.execute('SELECT * FROM task_runs WHERE task_id=? ORDER BY id',(tid,))])
                data=json.dumps(snapshot,sort_keys=True,indent=2).encode()
                # Native attachment publication participates via an explicitly
                # nested composition API. An outer failure removes only our blob.
                aid=kb.store_attachment_bytes(db,tid,'release-context.json',data,
                    content_type='application/json',uploaded_by='interactive-operator',board=board)
                attachment_path=Path(db.execute('SELECT stored_path FROM task_attachments WHERE id=?',(aid,)).fetchone()[0])
                if task['title']!=record['title'] or task['body']!=record['body']:
                    db.execute('UPDATE tasks SET title=?,body=? WHERE id=?',(record['title'],record['body'],tid))
                    kb._append_event(db,tid,'edited',dict(fields=['title','body'],reason='Versioned release-condition migration',context_attachment_id=aid,previous_hold=record['expected_version']))
                registration=_register_locked(kb,db,tid,record['contract'],hold_version(db,tid),actor)
                results.append(dict(task_id=tid,state='registered',registration_id=registration['registration_id'],context_attachment_id=aid))
        except (ValueError,sqlite3.Error) as exc:
            if attachment_path is not None:attachment_path.unlink(missing_ok=True)
            results.append(dict(task_id=tid,state='unchanged',reason=str(exc)))
    return dict(schema_version=1,board=board,results=results)
