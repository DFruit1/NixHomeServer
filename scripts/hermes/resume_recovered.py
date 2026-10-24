"""Bounded native API for a repaired parked technical capability hold.

Python reuses the owning Hermes transaction, policy and lifecycle APIs. Only the
native kanban tool calls the effect; a terminal subprocess cannot shed its
native delegation fence. No LLM specification, decomposition or board sweep.
"""
import ast
import fcntl
import hashlib
import inspect
import json
import os
from pathlib import Path
import re
import sqlite3
import stat
import time


# Fleet rollback must retain a reader/enforcer once this authority is recorded.
ITERATION_GUARD_VERSION = 2


# These two reviewed native functions define parent and review-phase semantics.
# Drift requires reconciliation rather than silently adopting a different API.
NATIVE_PHASE_SOURCES = {
    '_landing_status_after_parents': 'bd60bf28eec34a6933199b50faadbdf17667e1cca8fe32399ee6276f2ffa1b77',
    '_resume_status_from_events': '7ede5b86e4e6efc5787e1ca5e92783c283fa5f2e76c95faa0793292081c2f1a8',
}


def validate_native_source(source):
    tree = ast.parse(source)
    functions = {node.name: ast.get_source_segment(source, node) + '\n'
                 for node in tree.body if isinstance(node, ast.FunctionDef)
                 and node.name in NATIVE_PHASE_SOURCES}
    for name, expected in NATIVE_PHASE_SOURCES.items():
        if hashlib.sha256(functions.get(name, '').encode()).hexdigest() != expected:
            raise ValueError('Native recovery phase API drift; reconcile before installation or release')


def _validate_native(kb):
    try:
        for name, expected in NATIVE_PHASE_SOURCES.items():
            if hashlib.sha256(inspect.getsource(getattr(kb, name)).encode()).hexdigest() != expected:
                raise ValueError('Native recovery phase API drift')
    except (OSError, TypeError, AttributeError):
        raise ValueError('Native recovery phase API unavailable') from None


def _sync_directory(path):
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def coordinator_origin():
    """Authenticate the current native process, never a caller's role string."""
    from hermes_cli import nixhomeserver_worker_origin as origin
    try:
        if not origin.dispatcher_owned():
            return None
        binding = origin._native_binding()
        return binding if binding and binding['profile'] == 'head-coordinator' else None
    except (OSError, ValueError, TypeError, sqlite3.Error):
        return None


def require_actor_board(conn, actor):
    from hermes_cli.kanban_db_connect import _main_db_file
    path = _main_db_file(conn)
    if not actor or not path or Path(path) != Path(actor['db']):
        raise ValueError('Recovery requires the authenticated coordinator own board')
    if coordinator_origin() != actor:
        raise ValueError('Native coordinator changed before routing')
    return Path(path).parents[3], actor['board']


def _private_directory(parent, name):
    path = parent / name
    try:
        path.mkdir(mode=0o700)
        _sync_directory(parent)
    except FileExistsError:
        pass
    info = path.lstat()
    if (not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid()
            or info.st_mode & 0o077):
        raise ValueError('Recovery journal directory must be private and not a symlink')
    return path


def _journal(root):
    # A fixed, private tree; never follow a caller-provided journal path.
    runtime = root / 'runtime'
    try:
        runtime.mkdir(mode=0o700)
        _sync_directory(root)
    except FileExistsError:
        pass
    info = runtime.lstat()
    if (not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid()
            or info.st_mode & 0o022):
        raise ValueError('Recovery runtime directory is not safe')
    return _private_directory(runtime, 'recovered-resume')


def _lock(journal):
    fd = os.open(journal / 'operation.lock', os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        info = os.fstat(fd)
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
                or info.st_mode & 0o077 or info.st_nlink != 1):
            raise ValueError('Recovery lock is not a private regular file')
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return fd
    except BaseException:
        os.close(fd)
        raise


def _hold(conn, root, board, tid):
    from cron import nixhomeserver_capability_recovery as recovery
    holds = recovery.read_board(conn, root, board, recovery.helper_identity(root))
    matches = [hold for hold in holds if hold['task_id'] == tid]
    if len(matches) != 1:
        raise ValueError('No unique current technical recovery hold')
    return matches[0]


def _eligible(conn, task, hold):
    if task.status not in {'triage','blocked','scheduled'} or '[FEATURE TRACKER' in task.title.upper():
        raise ValueError('Only a parked non-tracker technical capability task may resume')
    event = conn.execute("SELECT kind,payload FROM task_events WHERE task_id=? "
                         "AND kind IN ('blocked','block_loop_detected','unblocked','completed',"
                         "'block_reclassified') ORDER BY id DESC LIMIT 1", (task.id,)).fetchone()
    if not event or event['kind'] not in {'blocked', 'block_loop_detected', 'block_reclassified'}:
        raise ValueError('Task has no current native technical block episode')
    if hold['supplier'] not in {'agent', 'model/provider'} or task.block_kind != 'capability':
        raise ValueError('Only agent-recoverable capability triage is eligible')
    row = conn.execute('SELECT worker_pid,claim_lock,claim_expires FROM tasks WHERE id=?', (task.id,)).fetchone()
    if (row['worker_pid'] is not None or row['claim_lock'] is not None
            or row['claim_expires'] is not None):
        raise ValueError('Recovery refuses a task with a worker or lease')
    active = conn.execute("SELECT id FROM task_runs WHERE task_id=? AND "
                          "(status IN ('running','pending','claimed','starting') OR "
                          "(ended_at IS NULL AND outcome IS NULL)) LIMIT 1", (task.id,)).fetchone()
    if active:
        raise ValueError('Recovery refuses an active or pending native run')


def requires_iteration_disposition(conn, tid):
    """A spent finite continuation or iteration trip of the native breaker."""
    return conn.execute("SELECT 1 FROM task_events WHERE task_id=? AND ("
        "json_type(payload,'$.iteration_continuation') IS NOT NULL OR "
        "json_extract(payload,'$.branch')='iteration-exhaustion-reaffirmation' OR "
        "(kind='gave_up' AND json_type(payload,'$.budget_max') IS NOT NULL)) LIMIT 1",
        (tid,)).fetchone() is not None


def has_iteration_history(conn, tid):
    if requires_iteration_disposition(conn,tid):
        return True
    # Below the breaker, native finalization discards budget fields but retains
    # its exact iteration error. This prevents ordinary failure resets; it does
    # not turn a remaining configured automatic attempt into a new owner gate.
    return conn.execute("SELECT 1 FROM task_events WHERE task_id=? AND kind='timed_out' AND "
        "json_extract(payload,'$.error') GLOB 'Iteration budget exhausted (*) — task could not complete within the allowed iterations' LIMIT 1",
        (tid,)).fetchone() is not None


def require_iteration_ordinary_unblock(conn, tid):
    if has_iteration_history(conn,tid):
        raise ValueError('Finite iteration authority requires exact-version guarded recovery; '
                         'ordinary unblock cannot reset spent failures or authorize another run')


def iteration_claim_authority(conn, tid, *, allow_current=False):
    """Consume one release at the native claim, including automatic requeues.

    A committed claim is consumption even if spawning or the worker protocol
    later fails. Native independent review of that exact producer's handoff
    remains a separate, once-only verification; it grants no implementation rework.
    """
    if not requires_iteration_disposition(conn,tid):
        return None
    release=conn.execute("SELECT id,payload FROM task_events WHERE task_id=? AND kind='unblocked' "
                         "AND json_type(payload,'$.iteration_continuation') IS NOT NULL "
                         'ORDER BY id DESC LIMIT 1',(tid,)).fetchone()
    refusal='Finite iteration continuation requires a fresh independently assessed disposition. Input supplier: agent.'
    if release is None:
        raise ValueError(refusal)
    record=json.loads(release['payload'] or '{}')
    authority=record.get('iteration_continuation')
    task=conn.execute('SELECT * FROM tasks WHERE id=?',(tid,)).fetchone()
    if (not isinstance(authority,dict) or record.get('applied') is not True
            or record.get('actor_profile')!='head-coordinator' or not task
            or authority.get('max_runs')!=1 or type(authority.get('max_runs')) is not int
            or not isinstance(authority.get('executor'),str)
            or authority.get('max_runtime_seconds')!=task['max_runtime_seconds']
            or authority.get('max_retries')!=task['max_retries']
            or type(authority.get('consecutive_failures')) is not int
            or task['consecutive_failures']<authority['consecutive_failures']):
        raise ValueError(refusal)
    claims=list(conn.execute("SELECT id,run_id,payload FROM task_events WHERE task_id=? "
                            "AND kind='claimed' AND id>? ORDER BY id LIMIT 3",(tid,release['id'])))
    producer=dict(authority,release_event=release['id'],phase='continuation')
    expected=producer
    if claims:
        first=json.loads(claims[0]['payload'] or '{}')
        if first.get('iteration_continuation')!=producer:
            raise ValueError(refusal)
        handoff=conn.execute("SELECT id,run_id,payload FROM task_events WHERE task_id=? "
                            "AND kind='review_requested' AND id>? ORDER BY id DESC LIMIT 1",
                            (tid,claims[0]['id'])).fetchone()
        if handoff and handoff['run_id']==claims[0]['run_id']:
            reviewed=json.loads(handoff['payload'] or '{}')
            origin=conn.execute('SELECT profile,status,outcome FROM task_runs WHERE task_id=? AND id=?',
                                (tid,handoff['run_id'])).fetchone()
            if (origin and origin['profile']==authority['executor']
                    and origin['outcome']=='review_requested' and origin['status'] in {'review','review_requested'}
                    and reviewed.get('implementer')==authority['executor']
                    and reviewed.get('reviewer')==task['assignee']
                    and task['assignee'] in {'feature-reviewer','project-auditor'}):
                expected=dict(authority,release_event=release['id'],phase='independent-review',
                              review_handoff_event=handoff['id'])
                if len(claims)==1 and task['status']=='review' and task['current_run_id'] is None:
                    return expected
        if allow_current and task['status']=='running' and len(claims) in {1,2}:
            last=claims[-1]
            payload=json.loads(last['payload'] or '{}')
            run=conn.execute('SELECT profile,status,outcome,ended_at FROM task_runs WHERE task_id=? AND id=?',
                             (tid,last['run_id'])).fetchone()
            if (last['run_id']==task['current_run_id'] and run and run['profile']==task['assignee']
                    and run['status']=='running' and run['outcome'] is None and run['ended_at'] is None
                    and payload.get('iteration_continuation')==expected
                    and ((len(claims)==1 and expected['phase']=='continuation'
                          and task['assignee']==authority['executor'])
                         or (len(claims)==2 and expected['phase']=='independent-review'
                             and last['id']>handoff['id']))):
                return expected
        raise ValueError(refusal)
    if task['assignee']!=authority['executor']:
        raise ValueError(refusal)
    return producer


def _native_iteration_execution(conn, run):
    """Use durable native provenance; terminal cleanup clears PID columns."""
    events = {}
    for kind in ('claimed','spawned','completed'):
        row = conn.execute('SELECT id,created_at,payload FROM task_events WHERE task_id=? '
                           'AND run_id=? AND kind=? ORDER BY id DESC LIMIT 1',
                           (run['task_id'],run['id'],kind)).fetchone()
        if row is None:
            raise ValueError('Iteration decision and review need durable native claim/spawn/completion proof')
        events[kind] = row
    claim,spawn,done = (events[kind] for kind in ('claimed','spawned','completed'))
    try:
        claimed,spawned = (json.loads(row['payload'] or '{}') for row in (claim,spawn))
    except (TypeError,ValueError):
        raise ValueError('Malformed native iteration execution proof') from None
    stamps = (run['started_at'],claim['created_at'],spawn['created_at'],run['ended_at'],done['created_at'])
    if (not isinstance(claimed,dict) or not isinstance(spawned,dict)
            or not run['claim_lock'] or claimed.get('lock') != run['claim_lock']
            or type(spawned.get('pid')) is not int or spawned['pid'] <= 0
            or not isinstance(spawned.get('started_at'),str) or spawned['started_at'] == 'unverified'
            or not spawned['started_at']
            or any(type(stamp) is not int or stamp <= 0 for stamp in stamps)
            or tuple(sorted(stamps)) != stamps or not claim['id'] < spawn['id'] < done['id']
            or (run['worker_pid'] is not None and run['worker_pid'] != spawned['pid'])
            or (run['worker_started_at'] is not None and run['worker_started_at'] != spawned['started_at'])):
        raise ValueError('Iteration native execution provenance is inconsistent')


def _iteration_review(conn, tid):
    task = conn.execute('SELECT status,assignee,tenant FROM tasks WHERE id=?',(tid,)).fetchone()
    run = conn.execute('SELECT * FROM task_runs WHERE task_id=? ORDER BY id DESC LIMIT 1',(tid,)).fetchone()
    if (not task or task['status'] != 'done' or task['tenant'] != 'verification'
            or task['assignee'] not in {'feature-reviewer','project-auditor'} or not run
            or run['profile'] != task['assignee'] or run['status'] != 'done' or run['outcome'] != 'completed'):
        raise ValueError('Iteration decision needs its current completed independent review prerequisite')
    try:
        accepted = json.loads(run['metadata'] or '{}')
    except (TypeError,ValueError):
        accepted = None
    checks = accepted.get('checks') if isinstance(accepted,dict) else None
    independence = accepted.get('independence') if isinstance(accepted,dict) else None
    if (not isinstance(accepted,dict) or accepted.get('verdict') != 'accept'
            or not isinstance(accepted.get('revision'),str) or not accepted['revision'].strip()
            or not isinstance(independence,dict) or set(independence) != {'plan_author','implementer'}
            or any(independence[key] is not False for key in independence)
            or not isinstance(checks,list) or not checks
            or any(not isinstance(check,dict) or not isinstance(check.get('command'),str)
                   or not check['command'].strip() or type(check.get('exit_code')) is not int
                   or check['exit_code'] != 0 for check in checks)):
        raise ValueError('Iteration scope requires independent acceptance with executed successful checks')
    _native_iteration_execution(conn,run)
    return run,accepted


def _iteration_context(conn, task, event, episode):
    """Keep finite authority attached after a normal partial-checkpoint hold."""
    previous = conn.execute("SELECT id,created_at,payload FROM task_events WHERE task_id=? "
                            "AND kind='unblocked' AND instr(payload,?)>0 ORDER BY id DESC LIMIT 1",
                            (task.id,'"iteration_continuation"')).fetchone()
    lineage = None
    if previous:
        recorded = json.loads(previous['payload'] or '{}')
        lineage = recorded.get('iteration_continuation') if isinstance(recorded,dict) else None
        keys = ('root_run','root_event','source_run','source_event','max_iterations',
                'max_runtime_seconds','consecutive_failures')
        if (not isinstance(lineage,dict) or any(type(lineage.get(key)) is not int
                or lineage[key] <= 0 for key in keys)
                or recorded.get('applied') is not True or recorded.get('actor_profile') != 'head-coordinator'):
            raise ValueError('Iteration authority lineage needs qualified native reconciliation')
    initial = isinstance(episode,dict) and episode.get('branch') == 'iteration-exhaustion-reaffirmation'
    if not initial and lineage is None:
        if requires_iteration_disposition(conn,task.id):
            raise ValueError('Iteration history needs qualified native recognition before any continuation')
        return None
    current = dict(conn.execute('SELECT * FROM tasks WHERE id=?',(task.id,)).fetchone())
    if (current['current_run_id'] is not None or current['assignee']=='local-implementer'
            or (current['body'] or '').lstrip().startswith('ASK:')
            or re.search(r'^Recovery mode:\s*evidence-only\s*$',current['body'] or '',re.M)):
        raise ValueError('Iteration continuation needs a parked technical task without a current-run binding')
    if lineage and (task.consecutive_failures < lineage['consecutive_failures']
            or task.max_runtime_seconds != lineage['max_runtime_seconds']
            or current['max_retries'] != lineage.get('max_retries')):
        raise ValueError('Historical iteration consumption conflicts with the current ledgers; reconcile before release')
    original = conn.execute('SELECT * FROM task_runs WHERE task_id=? ORDER BY id DESC LIMIT 1',(task.id,)).fetchone()
    reaffirmation = isinstance(episode,dict) and episode.get('branch') in {
        'timed-out-reaffirmation','reclaimed-reaffirmation','iteration-continuation-failure-reaffirmation'}
    if initial or reaffirmation:
        source = conn.execute('SELECT * FROM task_events WHERE task_id=? AND id=?',
                              (task.id,episode.get('source_event'))).fetchone()
        if (not original or original['id'] != episode.get('source_run') or not source
                or episode.get('reaffirmed') is not True
                or not source['id'] < event['id'] or source['created_at'] > event['created_at']):
            raise ValueError('Iteration decision no longer names the latest original episode')
        from hermes_cli.nixhomeserver_coordinator_repair import (
            _iteration_reaffirm, _reaffirm, _continuation_failure_reaffirm)
        payload = json.loads(source['payload'] or '{}')
        if initial:
            _iteration_reaffirm(conn,current,original,source,payload)
            maximum = payload['budget_max']
        else:
            # Native elapsed timeouts and reclaims retain their own terminal
            # run, then append a task-scoped classification. Bind the fresh
            # decision to the underlying trip, not the classification row.
            found=(_continuation_failure_reaffirm(conn,current,original,source,payload)
                   if episode['branch']=='iteration-continuation-failure-reaffirmation'
                   else _reaffirm(conn,current,original,source,payload,task.id))
            if found != episode['branch']:
                raise ValueError('Iteration followup classification conflicts with its native trip')
            claim = conn.execute("SELECT id FROM task_events WHERE task_id=? AND kind='claimed' "
                                 'AND run_id=? ORDER BY id DESC LIMIT 1',
                                 (task.id,original['id'])).fetchone()
            if (not claim or not previous['id'] < claim['id'] < source['id']
                    or any(type(original[key]) is not int or original[key] <= 0
                           for key in ('started_at','ended_at'))
                    or not previous['created_at'] <= original['started_at'] <= original['ended_at']):
                raise ValueError('Iteration followup needs its own ended native run after the prior continuation')
            maximum = lineage['max_iterations']
        if lineage and maximum != lineage['max_iterations']:
            raise ValueError('Iteration lineage cannot change its per-run ceiling')
    else:
        source = event
        terminal_pair=('blocked','blocked')
        branch=episode.get('branch') if isinstance(episode,dict) else None
        if branch in {'terminal-containment','block-loop-supplier-clarification','iteration-continuation-consumed'}:
            source=conn.execute('SELECT * FROM task_events WHERE task_id=? AND id=?',
                                (task.id,episode.get('source_event'))).fetchone()
            if (not source or not original or episode.get('source_run')!=original['id']
                    or not source['id']<event['id'] or source['created_at']>event['created_at']):
                raise ValueError('Iteration classification needs its own retained raw checkpoint episode')
            raw=json.loads(source['payload'] or '{}')
            if not isinstance(raw,dict):
                raise ValueError('Iteration checkpoint classification has no native raw payload')
            if branch=='terminal-containment':
                if source['kind']!='blocked' or raw.get('kind') is not None:
                    raise ValueError('Iteration containment must reference its original untyped checkpoint')
            elif branch=='block-loop-supplier-clarification' and (source['kind']!='block_loop_detected' or raw.get('kind')!='capability'
                    or type(raw.get('recurrences')) is not int or type(raw.get('limit')) is not int
                    or raw['limit']<=0 or raw['recurrences']<raw['limit']
                    or raw['recurrences']!=current['block_recurrences']):
                raise ValueError('Iteration supplier clarification must reference its native capability loop')
        if (branch=='iteration-continuation-consumed' and original
                and original['status']==original['outcome']=='crashed' and source['kind']=='crashed'):
            # Crash reclaim and failure accounting are separate native commits.
            # A process loss between them leaves a real ended crash with no
            # breaker trip. Preserve that actual counter state and raw episode.
            raw=json.loads(source['payload'] or '{}')
            metadata=json.loads(original['metadata'] or '{}')
            from hermes_cli.kanban_db import KANBAN_RATE_LIMIT_EXIT_CODE, KANBAN_TERMINAL_PROVIDER_EXIT_CODE
            kind,code=raw.get('exit_kind'),raw.get('exit_code')
            terminal=raw.get('terminal_provider') is True
            valid_exit=((kind=='nonzero_exit' and type(code) is int and code>0
                         and code not in {KANBAN_RATE_LIMIT_EXIT_CODE,KANBAN_TERMINAL_PROVIDER_EXIT_CODE})
                        or (kind=='signaled' and type(code) is int and code>0)
                        or (kind is None and code is None)
                        or (kind=='terminal_provider' and code==KANBAN_TERMINAL_PROVIDER_EXIT_CODE and terminal))
            if (not isinstance(raw,dict) or not isinstance(metadata,dict) or not valid_exit
                    or raw.get('protocol_violation') or raw.get('retry_status') not in {'ready','review'}
                    or raw.get('claimer')!=original['claim_lock']
                    or type(raw.get('pid')) is not int or raw['pid']<=0
                    or any(metadata.get(key)!=value for key,value in raw.items())):
                raise ValueError('Iteration crash containment needs its actual native interrupted crash sweep')
            terminal_pair=('crashed','crashed')
        elif (branch=='iteration-continuation-consumed' and original
                and original['status']==original['outcome']
                and original['outcome'] in {'crashed','rate_limited'}
                and isinstance(episode,dict) and isinstance(episode.get('reason'),str)
                and episode['reason'].startswith('Worker policy: Finite iteration continuation requires ')):
            # Protocol and quota requeues do not necessarily trip the failure
            # breaker. The claim guard still consumes their one run, and the
            # dispatcher parks the same task for an exact fresh assessment.
            kind='protocol_violation' if original['outcome']=='crashed' else 'rate_limited'
            if source['kind']!=kind:
                raise ValueError('Iteration requeue hold needs its actual native protocol/quota episode')
            raw=json.loads(source['payload'] or '{}')
            metadata=json.loads(original['metadata'] or '{}')
            from hermes_cli.kanban_db import KANBAN_RATE_LIMIT_EXIT_CODE
            code=0 if kind=='protocol_violation' else KANBAN_RATE_LIMIT_EXIT_CODE
            if (not isinstance(raw,dict) or not isinstance(metadata,dict)
                    or type(raw.get('exit_code')) is not int or raw['exit_code']!=code
                    or raw.get('retry_status') not in {'ready','review'}
                    or any(metadata.get(key)!=raw.get(key) for key in ('exit_code','retry_status','protocol_violation'))
                    or (kind=='protocol_violation' and raw.get('protocol_violation') is not True)
                    or source['created_at']>event['created_at']):
                raise ValueError('Iteration requeue hold conflicts with its native terminal evidence')
            terminal_pair=(original['outcome'],original['outcome'])
        elif (branch=='iteration-continuation-consumed' and original
                and original['status']==original['outcome']=='stale'):
            raw=json.loads(source['payload'] or '{}')
            metadata=json.loads(original['metadata'] or '{}')
            if (source['kind']!='stale' or not isinstance(raw,dict) or not isinstance(metadata,dict)
                    or any(metadata.get(key)!=value for key,value in raw.items())
                    or raw.get('retry_status') not in {'ready','review'}
                    or type(raw.get('timeout_seconds')) is not int or raw['timeout_seconds']<=0
                    or type(raw.get('elapsed_seconds')) is not int
                    or raw['elapsed_seconds']<raw['timeout_seconds']
                    or raw.get('worker_still_alive') is True):
                raise ValueError('Iteration stale containment needs its actual native heartbeat reclaim')
            terminal_pair=('stale','stale')
        elif (branch=='iteration-continuation-consumed' and original
                and original['status']==original['outcome']
                and original['outcome'] in {'timed_out','reclaimed'}):
            # Native timeout/TTL reclamation commits the ended run before its
            # separate failure accounting. A lost process must not leave the
            # consumed claim runnable or fabricate the missing counter update.
            raw=json.loads(source['payload'] or '{}')
            metadata=json.loads(original['metadata'] or '{}')
            if not isinstance(raw,dict) or not isinstance(metadata,dict):
                raise ValueError('Iteration terminal containment requires native metadata')
            if original['outcome']=='timed_out':
                elapsed,limit=raw.get('elapsed_seconds'),raw.get('limit_seconds')
                valid=(source['kind']=='timed_out' and type(elapsed) is int and type(limit) is int
                    and limit==lineage['max_runtime_seconds'] and limit>0 and elapsed>=limit
                    and raw.get('retry_status') in {'ready','review'}
                    and all(metadata.get(key)==value for key,value in raw.items())
                    and original['error']==f'elapsed {elapsed}s > limit {limit}s')
            elif source['kind']=='reconciled':
                valid=(raw.get('reason')=='orphaned_running'
                    and (raw.get('claim_lock') is None or raw.get('claim_expires') is None)
                    and all(metadata.get(key)==value for key,value in raw.items())
                    and original['error']=='orphaned running card (broken claim bookkeeping)')
            else:
                expiry,now=raw.get('claim_expires'),raw.get('now')
                valid=(source['kind']=='reclaimed' and raw.get('stale_lock')==original['claim_lock']
                    and type(expiry) is int and expiry>original['started_at']
                    and type(now) is int and now>expiry
                    and raw.get('retry_status') in {'ready','review'}
                    and all(raw.get(key)==value for key,value in metadata.items() if key!='source_status')
                    and original['error']==f"stale_lock={original['claim_lock']}")
            if not valid:
                raise ValueError('Iteration terminal containment conflicts with its actual native timeout/reclaim')
            terminal_pair=(original['outcome'],original['outcome'])
        elif (branch=='iteration-continuation-consumed' and original
                and original['status']==original['outcome']=='spawn_failed'):
            raw=json.loads(source['payload'] or '{}')
            metadata=json.loads(original['metadata'] or '{}')
            if (source['kind']!='spawn_failed' or not isinstance(raw,dict) or not isinstance(metadata,dict)
                    or raw.get('infrastructure') is not True or metadata.get('infrastructure') is not True
                    or type(raw.get('failures')) is not int or raw['failures']!=task.consecutive_failures
                    or raw.get('retry_status') not in {'ready','review'}
                    or any(metadata.get(key)!=raw.get(key) for key in ('failures','retry_status'))
                    or raw.get('error')!=original['error']):
                raise ValueError('Iteration spawn containment needs its actual native infrastructure refusal')
            terminal_pair=('spawn_failed','spawn_failed')
        elif (branch=='iteration-continuation-consumed' and original
                and original['outcome']=='changes_requested' and original['status'] in {'ready','todo'}):
            raw=json.loads(source['payload'] or '{}')
            if (source['kind']!='changes_requested' or not isinstance(raw,dict)
                    or raw.get('implementer')!=task.assignee or raw.get('reviewer')!=original['profile']
                    or original['profile'] not in {'feature-reviewer','project-auditor'}):
                raise ValueError('Iteration rework hold needs its genuine independent native request-changes')
            terminal_pair=(original['status'],'changes_requested')
        claim = conn.execute("SELECT id,created_at FROM task_events WHERE task_id=? AND kind='claimed' "
                             'AND run_id=? ORDER BY id DESC LIMIT 1',
                             (task.id,original['id'])).fetchone() if original else None
        if (not original or not claim or source['run_id'] != original['id']
                or (original['status'],original['outcome']) != terminal_pair
                or not previous['id'] < claim['id'] < source['id']):
            raise ValueError('A later iteration hold needs its own ended native checkpoint run and new assessment')
        stamps = (previous['created_at'],original['started_at'],claim['created_at'],
                  original['ended_at'],source['created_at'])
        if any(type(stamp) is not int or stamp <= 0 for stamp in stamps) or tuple(sorted(stamps)) != stamps:
            raise ValueError('Iteration checkpoint chronology is inconsistent')
        maximum = lineage['max_iterations']
    return dict(source_run=original['id'],source_event=source['id'],max_iterations=maximum,
                max_runtime_seconds=task.max_runtime_seconds,consecutive_failures=task.consecutive_failures,
                max_retries=current['max_retries'],max_runs=1,executor=task.assignee,
                root_run=lineage['root_run'] if lineage else original['id'],
                root_event=lineage['root_event'] if lineage else source['id'])


def _iteration_continuation(conn, task, reason):
    """Bind iteration recovery to an actual finite native decision and review.

    Recognition alone is not a continuation allowance. This additional contract
    applies only to the new iteration branch; existing recovery is unchanged.
    """
    event = conn.execute("SELECT id,run_id,kind,created_at,payload FROM task_events WHERE task_id=? AND "
                         "kind IN ('blocked','block_loop_detected','block_reclassified') "
                         "ORDER BY id DESC LIMIT 1",(task.id,)).fetchone()
    episode = json.loads(event['payload'] or '{}')
    context = _iteration_context(conn,task,event,episode)
    if context is None:
        return None
    refs = re.findall(r'\bIteration decision: (t_[a-z0-9_]{1,64})/run([1-9][0-9]*)\b',reason)
    if len(refs) != 1 or reason.count('Iteration decision:') != 1:
        raise ValueError('Iteration recovery requires one exact Iteration decision: t_CARD/runN reference')
    decision, decision_run = refs[0][0], int(refs[0][1])
    grant_task = conn.execute('SELECT status,assignee FROM tasks WHERE id=?',(decision,)).fetchone()
    run = conn.execute('SELECT * FROM task_runs WHERE task_id=? ORDER BY id DESC LIMIT 1',
                       (decision,)).fetchone()
    if (not grant_task or grant_task['status'] != 'done' or grant_task['assignee'] != 'head-coordinator'
            or not run or run['id'] != decision_run or run['profile'] != 'head-coordinator'
            or run['status'] != 'done' or run['outcome'] != 'completed'):
        raise ValueError('Iteration recovery needs the current completed native coordinator decision')
    try:
        metadata = json.loads(run['metadata'] or '{}')
        grant = metadata.get('iteration_continuation') if isinstance(metadata,dict) else None
    except (TypeError,ValueError):
        grant = None
    integers = {'version','run_id','event_id','max_runs','max_iterations',
                'max_runtime_seconds','consecutive_failures','review_run_id'}
    fields = integers | {'decision','task_id','checkpoint','review_task_id','scope_revision'}
    if (not isinstance(grant,dict) or set(grant) != fields
            or any(type(grant[key]) is not int or grant[key] <= 0 for key in integers)
            or grant['version'] != 1 or grant['decision'] != 'approve' or grant['max_runs'] != 1
            or grant['task_id'] != task.id
            or grant['run_id'] != context['source_run'] or grant['event_id'] != context['source_event']
            or grant['max_runtime_seconds'] != task.max_runtime_seconds
            or grant['consecutive_failures'] != task.consecutive_failures
            or not isinstance(grant['checkpoint'],str) or not re.fullmatch(r'[A-Za-z0-9_-]{1,80}',grant['checkpoint'])
            or not isinstance(grant['scope_revision'],str) or not re.fullmatch(r'[0-9a-f]{40}|[0-9a-f]{64}',grant['scope_revision'])
            or not isinstance(grant['review_task_id'],str) or not re.fullmatch(r't_[a-z0-9_]{1,64}',grant['review_task_id'])):
        raise ValueError('Iteration decision must bind this exact episode, checkpoint and unchanged ledgers')
    if grant['max_iterations'] != context['max_iterations']:
        raise ValueError('Iteration decision cannot change the recorded per-run iteration ceiling')
    parents = list(conn.execute('SELECT t.id,t.status,t.tenant,t.assignee FROM task_links l '
                                'JOIN tasks t ON t.id=l.parent_id WHERE l.child_id=? LIMIT 129',(decision,)))
    if (len(parents)>128 or grant['review_task_id'] not in {parent['id'] for parent in parents}
            or any(parent['status'] != 'done' for parent in parents)):
        raise ValueError('Iteration decision needs its current completed independent review prerequisite')
    reviewed,accepted = _iteration_review(conn,grant['review_task_id'])
    scope_fields = {'task_id','run_id','event_id','checkpoint','max_runs','max_iterations',
                    'max_runtime_seconds','consecutive_failures','scope_revision'}
    scope = {key:grant[key] for key in scope_fields}
    scope_digest = hashlib.sha256(json.dumps(scope,sort_keys=True,separators=(',',':')).encode()).hexdigest()
    if (reviewed['id'] != grant['review_run_id']
            or accepted.get('revision') != grant['scope_revision']
            or accepted.get('iteration_continuation_scope') != scope
            or accepted.get('iteration_scope_sha256') != scope_digest):
        raise ValueError('Independent acceptance must bind the exact continuation scope and canonical digest')
    for parent in parents:
        if (parent['id'] != grant['review_task_id'] and parent['tenant']=='verification'
                and parent['assignee'] in {'feature-reviewer','project-auditor'}):
            _iteration_review(conn,parent['id'])
    _native_iteration_execution(conn,run)
    return dict(context,decision_task=decision,decision_run=decision_run,checkpoint=grant['checkpoint'],
                scope_revision=grant['scope_revision'])


def _reserve(journal, board, tid, version, evidence):
    path = journal / (board + '--' + tid + '--' + version + '.json')
    try:
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    except FileExistsError:
        raise ValueError('Recovery version already consumed; inspect its native event and journal') from None
    with os.fdopen(fd, 'w') as stream:
        json.dump(evidence, stream, sort_keys=True)
        stream.write('\n')
        stream.flush()
        os.fsync(stream.fileno())
    _sync_directory(journal)


def resume_recovered(kb, conn, tid, version, reason):
    """One exact parked capability transition, preserving consumed allowances.

    A reservation survives interruption or transaction failure. It never claims
    success; the committed native ``unblocked`` event records an actual release.
    All source/task fields, failure counters and retry budgets survive unchanged.
    """
    if (not isinstance(tid, str) or not re.fullmatch(r't_[a-z0-9_]{1,64}', tid)
            or not isinstance(version, str) or not re.fullmatch(r'[0-9a-f]{64}', version)
            or not isinstance(reason, str) or not reason.strip() or len(reason) > 4000):
        raise ValueError('Recovery requires exact task, 64-hex version and nonempty bounded evidence')
    _validate_native(kb)
    actor = coordinator_origin()
    root, board = require_actor_board(conn, actor)
    if actor['task_id'] == tid:
        raise ValueError('A running coordinator cannot resume itself')
    journal = _journal(root)
    lock = _lock(journal)
    try:
        started = time.monotonic()
        with kb.write_txn(conn):
            from hermes_cli import nixhomeserver_worker_policy as policy
            policy.require_release(conn, tid)
            task = kb.get_task(conn, tid)
            if task is None:
                raise ValueError('Unknown recovery task')
            before = dict(conn.execute('SELECT * FROM tasks WHERE id=?', (tid,)).fetchone())
            hold = _hold(conn, root, board, tid)
            _eligible(conn, task, hold)
            if hold['version'] != version:
                raise ValueError('Recovery hold version changed; obtain recovery_version from '
                                 'python3 ~/.hermes/scripts/capability_recovery.py --inspect '
                                 'for this exact board/task. kanban_amend.version is a separate '
                                 'amendment CAS token, not a recovery_version. Re-inspect after '
                                 'relevant source, helper or task evidence changes; no release applied')
            continuation = _iteration_continuation(conn,task,reason)
            if time.monotonic() - started > 15 or coordinator_origin() != actor:
                raise ValueError('Recovery exceeded its bound or native actor changed')
            landing = kb._landing_status_after_parents(conn, tid)
            resume = kb._resume_status_from_events(conn, tid)
            status = 'review' if landing == 'ready' and resume == 'review' else landing
            evidence = dict(schema_version=1, task_id=tid, board=board,
                            recovery_version=version, recovery_reason=reason.strip(),
                            actor_task=actor['task_id'], actor_run=actor['run_id'],
                            actor_profile=actor['profile'], actor_pid=actor['pid'],
                            actor_fingerprint=actor['fingerprint'], status=status,
                            resume_status=resume, applied=True)
            if continuation is not None:
                evidence['iteration_continuation'] = continuation
            reservation = dict(evidence, applied=False, journal_state='reserved-before-transition')
            reservation['intended_status'] = reservation.pop('status')
            if continuation is not None:
                # This reservation outlives rollback and helper/version changes.
                # An interrupted one-shot stays held for explicit reconciliation;
                # another actor or decision cannot replay the same source trip.
                episode_key = 'iteration-'+str(continuation['source_run'])+'-'+str(continuation['source_event'])
                _reserve(journal,board,tid,episode_key,reservation)
            else:
                # Ordinary repair inputs are one-use by version. Finite
                # continuations instead consume the actual native episode:
                # a new independently assessed failure can have identical
                # body/helper inputs without inheriting the old permission.
                _reserve(journal, board, tid, version, reservation)
            # Maintained native API: one exact target, no board-wide recomputation.
            changed = conn.execute("UPDATE tasks SET status=? WHERE id=? AND status=?", (status, tid, task.status))
            if changed.rowcount != 1:
                raise ValueError('Recovery task changed before its transition; version consumed')
            kb._append_event(conn, tid, 'unblocked', evidence)
        expected = dict(before, status=status)
        row = conn.execute('SELECT * FROM tasks WHERE id=?', (tid,)).fetchone()
        if row is None or dict(row) != expected:
            raise ValueError('Recovery committed but task readback changed; inspect the native event')
        return dict(task_id=tid, status=status, recovery_version=version, applied=True,
                    actor_task=actor['task_id'], actor_run=actor['run_id'])
    finally:
        os.close(lock)
