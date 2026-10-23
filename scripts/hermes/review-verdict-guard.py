#!/usr/bin/env python3
"""Check native tool handoffs without changing board state.

Python operations glue uses the installed pre-tool hook and read-only board DB;
no upstream Hermes patch, new service or publication contract is needed.
"""
from contextlib import closing
import json
import os
from pathlib import Path
import re
import sqlite3
import sys
import subprocess

FEATURE = re.compile(r'^Feature tracker:\s*([A-Za-z0-9_-]+):(t_[A-Za-z0-9_]+)\s*$', re.M)


def _feature_contract(db, task):
    if not task:
        return ''
    workflow = load_contract(db, task['id'])
    if workflow is not None:
        return render_contract(task['body'], workflow)
    comments = db.execute("SELECT body FROM task_comments WHERE task_id=? AND "
                          "(body LIKE '%Feature tracker:%' OR body LIKE '%Feature handoff:%' OR body LIKE '%Feature role:%') "
                          'ORDER BY id LIMIT 101', (task['id'],)).fetchall()
    if len(comments) > 100:
        raise ValueError('Feature contract history exceeds bound; reconcile its maintained body')
    fields = {}
    for text in [task['body'] or ''] + [r['body'] for r in comments]:
        for line in text.splitlines():
            for key in ('Feature tracker:', 'Feature handoff:', 'Feature role:'):
                if line.startswith(key):
                    if key == 'Feature tracker:' and not FEATURE.fullmatch(line):
                        # Prose mentions are not contract updates. In particular,
                        # a trailing sentence must not erase a valid tracker and
                        # silently disable the delivery dependency guard.
                        continue
                    fields[key] = line  # Explicit latest native marker supersedes its old field.
    body = re.sub(r'(?m)^Feature (?:tracker|handoff|role):[^\n]*', '', task['body'] or '')
    return body + '\n' + '\n'.join(fields.values())


def guard_feature_routing(payload, root):
    """Reject demonstrated delivery waits and malformed source assignments.

    These are preflight refusals, never lifecycle edits or release authority.
    Native project/worktree, cycle and lease checks still own actual effects.
    """
    args = payload.get('tool_input') or {}
    body = args.get('body') or ''
    if payload['tool_name'] == 'kanban_create':
        validate_markers(body, args.get('workflow'))
    if payload['tool_name'] == 'kanban_create' and args.get('workflow') is not None:
        body = render_contract(body, args['workflow'])
        args = {**args, 'body': body}
    if (payload['tool_name'] == 'kanban_create' and native_contract(body)
            and args.get('assignee') in {'feature-reviewer', 'project-auditor'}):
        raise ValueError('Workflow: native-review-v1 belongs to a same-card implementation;'
                         ' omit it on a standalone verifier that qualifies existing evidence')
    if (payload['tool_name'] == 'kanban_create'
            and args.get('assignee') in {'standard-implementer', 'local-implementer'}
            and re.search(r'native-review-v1', body, re.I) and not native_contract(body)):
        raise ValueError('Implementation review workflow claims require the standalone line '
                         'Workflow: native-review-v1; prose does not activate independent acceptance')
    board = args.get('board') or os.environ.get('HERMES_KANBAN_BOARD')
    if not isinstance(board, str) or not re.fullmatch(r'[A-Za-z0-9_-]+', board):
        if payload['tool_name'] == 'kanban_create' and re.search(r'^Feature tracker:', args.get('body') or '', re.M):
            raise ValueError('Exact board required for feature routing')
        return {}  # Unscoped/non-feature calls retain their native semantics.
    path = root/'kanban/boards'/board/'kanban.db'
    with closing(sqlite3.connect(path.resolve().as_uri()+'?mode=ro', uri=True, timeout=5)) as db:
        db.row_factory = sqlite3.Row
        db.execute('PRAGMA query_only=ON'); db.execute('BEGIN')
        if payload['tool_name'] == 'kanban_create':
            validate_create(db, body, args.get('workflow'), args.get('assignee'),
                            os.environ.get('HERMES_KANBAN_TASK'))
            child = args
            body = args.get('body') or ''
            parents = args.get('parents') or []
            if not isinstance(parents, list):
                raise ValueError('Parents must be explicit task IDs')
        else:
            child = db.execute('SELECT * FROM tasks WHERE id=?', (args.get('child_id'),)).fetchone()
            if not child:
                raise ValueError('Unknown feature dependency child')
            child = dict(child)
            body = _feature_contract(db, child)
            parents = [args.get('parent_id')]
        feature = FEATURE.search(body)
        if re.search(r'^Feature tracker:', body, re.M) and not feature:
            raise ValueError('Use a standalone Feature tracker: BOARD:t_CARD line; no trailing prose')
        for pid in parents:
            parent = db.execute('SELECT * FROM tasks WHERE id=?', (pid,)).fetchone()
            contract = _feature_contract(db, parent)
            if (parent and parent['assignee'] == 'head-coordinator' and parent['status'] not in {'done', 'archived'}
                    and FEATURE.search(contract) and re.search(r'^Feature handoff: delivery\s*$', contract, re.M)
                    and child.get('assignee') in {'standard-implementer', 'local-implementer', 'feature-reviewer', 'project-auditor'}
                    and not (child.get('assignee') == 'project-auditor' and re.search(r'^Feature role: documentary-closure\s*$', body, re.M))):
                raise ValueError('An unfinished feature delivery handoff cannot precede its input producer/reviewer. '
                                 'Use the completed plan/decision as producer parent; producer/reviewer precedes delivery. '
                                 'Only documentary auditor closure follows delivery')
        source_edit = re.search(r'(?m)^(?:Change|Source):[^\n]*(?:custom_apps/|modules/|scripts/)|\bbaseline commit [0-9a-f]{7,64}\b', body, re.I)
        if (payload['tool_name'] != 'kanban_create' or not feature or not source_edit
                or child.get('assignee') not in {'standard-implementer', 'local-implementer'}):
            return {}
        kind, raw = args.get('workspace_kind'), args.get('workspace_path')
        current_id = os.environ.get('HERMES_KANBAN_TASK')
        current = db.execute('SELECT * FROM tasks WHERE id=?', (current_id,)).fetchone()
        project = args['project'] if 'project' in args else args.get('project_id')
        if project is None and kind is None and raw is None and current:
            project = dict(current).get('project_id')
        if kind is None and raw is None and project:
            return {}  # Native project inheritance provisions an isolated worktree.
        work = Path(raw or '')
        if kind not in {'worktree', 'dir'} or not work.is_absolute() or not work.is_dir() or work.resolve() != work:
            raise ValueError('Repository feature edits require a native project or explicit workspace_kind=worktree, '
                             'workspace_path=/absolute/existing/repository; omitted fields create scratch, not source')
        from capability_recovery import workspace_identity
        if workspace_identity(str(work), {}).get('state') != 'git-root':
            raise ValueError('Feature workspace must be the exact Git repository/worktree root')
        if kind == 'dir':
            if not (work/'.git').is_file():
                raise ValueError('Prepared dir must be an exclusive linked worktree, not the main checkout')
            if db.execute("SELECT 1 FROM tasks WHERE workspace_path=? AND status NOT IN ('done','archived') LIMIT 1", (str(work),)).fetchone():
                raise ValueError('Prepared feature worktree already belongs to unfinished work; preserve its owner')
    return {}

sys.path.insert(0, str(Path(__file__).resolve().parent))
from fleet_workflow import native_contract, require_native_acceptance, validate_handoff_metadata
from fleet_contract import (load as load_contract, render as render_contract, review_metadata,
                            completion_metadata, validate_markers, validate_create)


def verification(task, db=None):
    return ((task['assignee'] == 'feature-reviewer'
             and task['tenant'] not in {'continuous-improvement', 'review-question'})
            or (task['assignee'] == 'project-auditor' and task['tenant'] == 'verification')
            or (db is not None and native_review(db, task)))


def native_review(db, task):
    """Native review provenance survives the implementation task's tenant.

    Match the latest claimed event to the current reviewer run, just as Hermes'
    native retry lifecycle does. A later ordinary claim clears this context;
    an old review_requested event alone never makes planning work verification.
    """
    if task['assignee'] not in {'feature-reviewer', 'project-auditor'}:
        return False
    claim = db.execute("SELECT payload FROM task_events WHERE task_id=? AND kind='claimed'"
                       ' ORDER BY id DESC LIMIT 1', (task['id'],)).fetchone()
    provenance = json.loads(claim['payload'] or '{}') if claim else {}
    if not isinstance(provenance, dict):
        raise ValueError('Malformed latest claim provenance')
    if task['status'] != 'review' and provenance.get('source_status') != 'review':
        return False
    current = task['current_run_id'] if 'current_run_id' in task.keys() else None
    if task['status'] == 'running' and 'current_run_id' in task.keys() and current is None:
        raise ValueError('A running native review needs its current reviewer run')
    if current is not None and task['status'] != 'review':
        run = db.execute('SELECT profile FROM task_runs WHERE task_id=? AND id=?',
                         (task['id'], current)).fetchone()
        if provenance.get('run_id') != current or not run or run['profile'] != task['assignee']:
            raise ValueError('Native review claim does not match the current reviewer run')
    return True


def _independent_native_acceptance(db, task):
    handoff = db.execute("SELECT payload FROM task_events WHERE task_id=? AND kind='review_requested'"
                         ' ORDER BY id DESC LIMIT 1', (task['id'],)).fetchone()
    evidence = json.loads(handoff['payload'] or '{}') if handoff else {}
    if (not isinstance(evidence, dict)
            or not isinstance(evidence.get('implementer'), str) or not evidence['implementer'].strip()
            or evidence['implementer'] == task['assignee']
            or evidence.get('reviewer', task['assignee']) != task['assignee']):
        raise ValueError('Native acceptance requires an independent implementer/reviewer handoff')
    return True


def validate(metadata, allow_unknown=False, *, profile=None):
    """verdict contract for a completed verification card.

    `unknown` is the first-missing-input outcome: the verifier could not reach
    a verdict because a required input is absent. It is only valid when the
    task body sanctions it, and it must carry the concrete missing inputs so
    the coordinator consumes an evidence-backed signal rather than manufacturing
    a rework loop from a refusal.
    """
    allowed = {'accept', 'request-changes'}
    if allow_unknown:
        allowed = allowed | {'unknown'}
    if not isinstance(metadata, dict) or metadata.get('verdict') not in allowed:
        raise ValueError('Set metadata.verdict to accept or request-changes, in lowercase'
                         + (' (or unknown when the card body permits a first-missing-input outcome)'
                            if allow_unknown else ''))
    if profile == 'project-auditor':
        independence = metadata.get('independence')
        if (not isinstance(independence, dict)
                or set(independence) != {'plan_author', 'implementer'}
                or independence['plan_author'] is not False
                or independence['implementer'] is not False):
            raise ValueError('Auditor verification requires metadata.independence with'
                             ' plan_author=false and implementer=false')
    if metadata.get('verdict') == 'unknown':
        fixes = metadata.get('missing_inputs')
        if not isinstance(fixes, list) or not fixes or any(not isinstance(f, str) or not f.strip() for f in fixes):
            raise ValueError('An unknown verdict needs the concrete absent inputs in metadata.missing_inputs')
        return
    if not isinstance(metadata.get('revision'), str) or not metadata['revision'].strip():
        raise ValueError('Name the exact reviewed source revision in metadata.revision')
    checks = metadata.get('checks')
    if not isinstance(checks, list) or not checks:
        raise ValueError('Record executed checks with command and integer exit_code')
    for check in checks:
        if not isinstance(check, dict) or not isinstance(check.get('command'), str) or not check['command'].strip() or type(check.get('exit_code')) is not int:
            raise ValueError('Every check needs a command and actual integer exit_code')
        if metadata['verdict'] == 'accept' and check['exit_code'] != 0:
            raise ValueError('A failing check cannot support acceptance; request changes or resolve it')
    if 'operation_scope' in metadata:
        scope = metadata['operation_scope']
        if (not isinstance(scope, dict)
                or set(scope) != {'request_sha256', 'executor', 'risk_classes'}
                or not isinstance(scope['request_sha256'], str)
                or not re.fullmatch(r'[0-9a-f]{64}', scope['request_sha256'])
                or metadata['revision'] != scope['request_sha256']
                or scope['executor'] not in {'operator', 'head-coordinator',
                                             'standard-implementer', 'local-implementer'}
                or scope['executor'] == profile
                or not isinstance(scope['risk_classes'], list)
                or any(not isinstance(risk, str) or not risk.strip() for risk in scope['risk_classes'])
                or (metadata['verdict'] == 'accept' and scope['risk_classes'] != [])):
            raise ValueError('Operation review must bind its exact request SHA as revision,'
                             ' an independent executor and no reserved effects for acceptance')
    if metadata['verdict'] == 'request-changes':
        fixes = metadata.get('requested_changes')
        if not isinstance(fixes, list) or not fixes or any(not isinstance(f, str) or not f.strip() for f in fixes):
            raise ValueError('List concrete fixes in metadata.requested_changes')


def _latest_review_state(db, review_id):
    """(parent row, latest completed verifier run) for a verification card.

    Only a completed run carries a verdict. Anchoring on the latest attempt of
    any status would let an interrupted (blocked) attempt move the supersession
    window past an acceptance that already landed, so the query filters the way
    _accepted_verdict() does.
    """
    parent = db.execute('SELECT * FROM tasks WHERE id=?',
                        (review_id,)).fetchone()
    if parent is None:
        return None, None
    run = db.execute("SELECT profile,status,outcome,metadata,ended_at FROM task_runs"
                     " WHERE task_id=? AND profile=?"
                     " AND status='done' AND outcome='completed'"
                     ' ORDER BY ended_at DESC, id DESC LIMIT 1',
                     (review_id, parent['assignee'])).fetchone()
    return parent, run


def _accepted_verdict(run, profile):
    if not run or run['profile'] != profile or run['status'] != 'done' \
            or run['outcome'] != 'completed':
        return False
    try:
        metadata = json.loads(run['metadata'] or '{}')
        validate(metadata, profile=profile)
        return metadata['verdict'] == 'accept'
    except (ValueError, TypeError, AttributeError):
        return False


def _retained_review_path(db, review_id, removed_parent, child):
    """Keep the same review gate while inserting a parked routing decision."""
    child_id = child['id']
    if not db.execute('SELECT 1 FROM task_links WHERE parent_id=? AND child_id=?',
                      (removed_parent, child_id)).fetchone():
        return False
    # A coordinator edge can be retired once the original direct gate is restored.
    if removed_parent != review_id and db.execute(
            'SELECT 1 FROM task_links WHERE parent_id=? AND child_id=?',
            (review_id, child_id)).fetchone():
        return True
    # Do not manufacture nested coordinator chains that would hide the gate.
    if child['assignee'] == 'head-coordinator':
        return False
    return db.execute("""SELECT 1 FROM task_links first
        JOIN tasks route ON route.id=first.child_id
        JOIN task_links second ON second.parent_id=route.id
        WHERE first.parent_id=? AND second.child_id=?
        AND route.id NOT IN (?,?,?) AND route.assignee='head-coordinator'
        AND route.status IN ('todo','blocked','scheduled','triage')
        AND NOT EXISTS (SELECT 1 FROM task_runs r WHERE r.task_id=route.id AND r.status='running')
        LIMIT 1""", (review_id, child_id, removed_parent, review_id, child_id)).fetchone() is not None


def _review_unlink(db, parent, run, removed_parent, child):
    parent_id, child_id = parent['id'], child['id']
    if _retained_review_path(db, parent_id, removed_parent, child):
        return
    if run is None:
        raise ValueError(f'Review {parent_id} has no completed verifier run;'
                         ' its gate cannot be retired by unlink')
    latest = db.execute('SELECT profile,status,outcome,metadata FROM task_runs'
                        ' WHERE task_id=? ORDER BY id DESC LIMIT 1', (parent_id,)).fetchone()
    if parent['status'] == 'done' and _accepted_verdict(latest, parent['assignee']):
        if native_review(db, parent):
            _independent_native_acceptance(db, parent)
        return
    # A replacement must remain linked to this same consumer. Unrelated
    # acceptance and a failed retry cannot release its direct or inherited gate.
    replacements = db.execute(
        'SELECT t.* FROM task_links l JOIN tasks t ON t.id=l.parent_id'
        " WHERE l.child_id=? AND t.id!=? AND t.status='done'",
        (child_id, parent_id)).fetchall()
    for replacement in replacements:
        if not verification(replacement, db):
            continue
        candidate = db.execute(
            'SELECT profile,status,outcome,metadata,ended_at FROM task_runs'
            ' WHERE task_id=? ORDER BY id DESC LIMIT 1', (replacement['id'],)).fetchone()
        if (candidate and candidate['ended_at'] is not None
                and candidate['ended_at'] > (run['ended_at'] or 0)
                and _accepted_verdict(candidate, replacement['assignee'])):
            if native_review(db, replacement):
                _independent_native_acceptance(db, replacement)
            return
    raise ValueError(
        f'Review {parent_id} requested changes, so this link is the live review'
        f' gate for {child_id}: unlinking it now would let the card complete'
        ' unreviewed. Link a fresh review card as a second parent and let it'
        f' accept first; then retiring {parent_id} is bookkeeping. For rejection'
        ' routing, retain review -> parked coordinator -> child before unlinking'
        ' the direct review edge. If the work is superseded outright, the'
        ' coordinator closes it with evidence')


def guard_unlink(payload, root):
    """Protect both direct review gates and their coordinator routing edges."""
    args = payload.get('tool_input') or {}
    board = args.get('board') or os.environ.get('HERMES_KANBAN_BOARD')
    child_id = args.get('child_id')
    if not isinstance(board, str) or not re.fullmatch(r'[A-Za-z0-9_-]+', board) \
            or not isinstance(child_id, str) or not re.fullmatch(r't_[A-Za-z0-9_]+', child_id):
        raise ValueError('Provide the exact board, parent_id and child_id for the unlink check')
    parent_id = args.get('parent_id')
    if not isinstance(parent_id, str) or not re.fullmatch(r't_[A-Za-z0-9_]+', parent_id):
        raise ValueError('Provide the exact parent_id for the unlink check')
    path = root / 'kanban/boards' / board / 'kanban.db'
    with closing(sqlite3.connect(path.resolve().as_uri() + '?mode=ro', uri=True, timeout=5)) as db:
        db.row_factory = sqlite3.Row
        db.execute('PRAGMA query_only=ON')
        db.execute('BEGIN')
        child = db.execute('SELECT id,status,assignee FROM tasks WHERE id=?', (child_id,)).fetchone()
        if child is None:
            raise ValueError('Unknown child task; do not unlink from an unknown card')
        if child['status'] in ('done', 'archived'):
            return {}
        parent, run = _latest_review_state(db, parent_id)
        if parent is None:
            return {}
        if verification(parent, db):
            _review_unlink(db, parent, run, parent_id, child)
        elif parent['assignee'] == 'head-coordinator':
            # Moving a review gate through a coordinator must not turn its
            # outgoing edge into an ordinary freely removable prerequisite.
            reviews = db.execute('SELECT p.* FROM task_links l JOIN tasks p ON p.id=l.parent_id'
                                 ' WHERE l.child_id=?', (parent_id,)).fetchall()
            for review in reviews:
                if verification(review, db):
                    _parent, review_run = _latest_review_state(db, review['id'])
                    _review_unlink(db, review, review_run, parent_id, child)
        return {}


def guard(payload, root):
    """Fail-closed dispatch: any guard error blocks the handoff it guards."""
    tool = payload.get('tool_name')
    if tool not in ('kanban_complete', 'kanban_unlink', 'kanban_create', 'kanban_link', 'kanban_request_review'):
        return {}
    try:
        if tool in ('kanban_create', 'kanban_link'):
            return guard_feature_routing(payload, root)
        if tool == 'kanban_unlink':
            return guard_unlink(payload, root)
        if tool == 'kanban_request_review':
            return guard_request_review(payload, root)
        return guard_complete(payload, root)
    except (ValueError, TypeError, OSError, sqlite3.Error, subprocess.TimeoutExpired) as exc:
        return {'action': 'block',
                'message': f'{tool} refused by the review-verdict guard: {exc}.'
                           ' Keep the handoff open; never treat done as'
                           ' acceptance or bypass this guard with the CLI.'}
def guard_request_review(payload, root):
    """Preflight the same provenance contract acceptance will later enforce."""
    args = payload.get('tool_input') or {}
    board, task_id = args.get('board'), args.get('task_id')
    if (not isinstance(board, str) or not re.fullmatch(r'[A-Za-z0-9_-]+', board)
            or not isinstance(task_id, str) or not re.fullmatch(r't_[A-Za-z0-9_]+', task_id)):
        raise ValueError('Provide the exact board and task_id for the review handoff check')
    path = root/'kanban/boards'/board/'kanban.db'
    with closing(sqlite3.connect(path.resolve().as_uri()+'?mode=ro', uri=True, timeout=5)) as db:
        db.row_factory = sqlite3.Row
        db.execute('PRAGMA query_only=ON'); db.execute('BEGIN')
        task = db.execute('SELECT body FROM tasks WHERE id=?', (task_id,)).fetchone()
        if task is None:
            raise ValueError('Unknown task; do not infer review handoff scope')
        if native_contract(task['body'], db, task_id):
            validate_handoff_metadata(review_metadata(db, task_id, args.get('metadata')))
    return {}


def guard_complete(payload, root):
    """The kanban_complete check: verdict contracts and review-gate parents."""
    args = payload.get('tool_input') or {}
    board = args.get('board') or os.environ.get('HERMES_KANBAN_BOARD')
    task_id = args.get('task_id') or os.environ.get('HERMES_KANBAN_TASK')
    if not isinstance(board, str) or not re.fullmatch(r'[A-Za-z0-9_-]+', board) or not isinstance(task_id, str) or not re.fullmatch(r't_[A-Za-z0-9_]+', task_id):
        raise ValueError('Provide the exact board and task_id for the completion check')
    path = root / 'kanban/boards' / board / 'kanban.db'
    with closing(sqlite3.connect(path.resolve().as_uri() + '?mode=ro', uri=True, timeout=5)) as db:
        db.row_factory = sqlite3.Row
        db.execute('PRAGMA query_only=ON')
        db.execute('BEGIN')
        task = db.execute('SELECT * FROM tasks WHERE id=?', (task_id,)).fetchone()
        if task is None:
            raise ValueError('Unknown task; do not infer review acceptance')
        metadata = completion_metadata(db, task_id, args.get('metadata'), args.get('delivery'))
        native = native_review(db, task)
        require_native_acceptance(db, task, metadata, native)
        if verification(task) or native:
            # The body sanction: a verifier card may complete with
            # metadata.verdict=unknown for a first-missing-input outcome only
            # when its body states that contract. Parent review evidence below
            # stays strict: an unknown verdict never releases a child.
            allow_unknown = bool(re.search(r'verdict[=:]\s*unknown', task['body'] or ''))
            validate(metadata, allow_unknown=allow_unknown, profile=task['assignee'])
            if native and metadata['verdict'] == 'accept':
                _independent_native_acceptance(db, task)
            if metadata['verdict'] != 'accept':
                if native and metadata['verdict'] == 'request-changes':
                    raise ValueError('Native review rejection uses kanban_request_changes, not completion')
                children = db.execute("SELECT c.assignee FROM task_links l JOIN tasks c ON c.id=l.child_id WHERE l.parent_id=? AND c.status NOT IN ('done','archived')", (task_id,)).fetchall()
                if any(c['assignee'] != 'head-coordinator' for c in children):
                    raise ValueError('Non-acceptance would release non-coordinator work; ask the coordinator to repair those dependencies first')
                # Reporting rejection or absent inputs cannot require acceptance
                # of a previous rejected revision. Only parked coordinator
                # routing may follow; its own completion still checks every
                # inherited review gate below.
                return {}
        parents = db.execute('SELECT p.* FROM task_links l JOIN tasks p ON p.id=l.parent_id WHERE l.child_id=?', (task_id,)).fetchall()
        for parent in parents:
            if not verification(parent, db):
                continue
            if parent['status'] != 'done':
                raise ValueError(f"Review {parent['id']} is not complete")
            run = db.execute("SELECT profile,status,outcome,metadata FROM task_runs WHERE task_id=? ORDER BY id DESC LIMIT 1", (parent['id'],)).fetchone()
            if not run or run['profile'] != parent['assignee'] or run['status'] != 'done' or run['outcome'] != 'completed':
                raise ValueError(f"Latest run for review {parent['id']} is not a completed verifier run")
            evidence = json.loads(run['metadata'] or '{}') if run else {}
            validate(evidence, profile=parent['assignee'])
            if evidence['verdict'] == 'accept' and native_review(db, parent):
                _independent_native_acceptance(db, parent)
            if evidence['verdict'] != 'accept':
                raise ValueError(
                    f"Review {parent['id']} requested changes. The review gate"
                    ' is live: complete only after an accepted review of the'
                    ' current revision is linked as a parent. Self-service:'
                    ' kanban_link a fresh review card as a parent (a review'
                    ' card that depends on this card can never run), let it'
                    f' accept, then kanban_unlink the superseded {parent["id"]}'
                    ' edge and complete. Coordinator routes: the same relink,'
                    ' or close this card as superseded with evidence')
    return {}


if __name__ == '__main__':
    try:
        root = Path(os.environ.get('HERMES_ROOT', str(Path.home() / '.hermes'))).resolve()
        print(json.dumps(guard(json.load(sys.stdin), root)))
    except (ValueError, TypeError, AttributeError, OSError) as exc:
        print(json.dumps({'action': 'block', 'message': f'Review guard failed closed: {exc}'}))
