#!/usr/bin/env python3
"""One no-agent schedule for bounded fleet maintenance and generated reports.

The existing handlers retain their native permissions, deduplication, eligibility
and recovery ceilings. Publication and owner-decision delivery are separate.
"""
import argparse
from contextlib import closing
import fcntl
import hashlib
import json
import importlib.util
import os
from pathlib import Path
import re
import signal
import sqlite3
import subprocess
import sys
import time

from hermes_common import atomic_write
from agent_usage_guard import intake_hold, read as read_usage_state

# name, interval seconds, timeout seconds, interpreter, installed script, arguments
HANDLERS = (
    ('retry-breaker', 900, 60, 'bash', 'kanban-retry-breaker.sh', ()),
    ('technical-recovery', 300, 90, 'python', 'deadlock_recovery.py', ()),
    ('board-progress', 900, 30, 'python', 'board_progress.py', ()),
    ('evidence', 300, 60, 'python', 'fleet-evidence.py', ('collect',)),
    ('agent-usage', 300, 90, 'python', 'agent-usage.py', ()),
    ('usage-guard', 300, 15, 'python', 'agent_usage_guard.py', ()),
    # A real recent no-agent aging pass took 96s; retain bounded headroom.
    ('aging', 21600, 180, 'python', 'kanban-aging-escalation.py', ()),
    ('cron-loops', 3600, 60, 'python', 'cron-loop-monitor.py', ()),
    ('proactive-intake', 3600, 60, 'bash', 'review-taskforce-tick.sh', ()),
    ('board-health', 1800, 90, 'bash', 'kanban-board-health.sh', ()),
    ('idle-state', 900, 30, 'python', 'idle-recovery-monitor.py', ()),
)
MAX_FAILURES = 3


def outcome_report(root, boards, now):
    """Refresh the existing analytics lens daily, before doing its board reads."""
    previous=root/'state/fleet/report.json'
    old=json.loads(previous.read_text()).get('outcomes') if previous.is_file() else None
    if isinstance(old,dict) and old.get('status')=='observed' and 0<=now-old.get('generated_at',0)<86400:
        return old
    source=root/'scripts/kanban-analytics.py'
    if not source.is_file():
        return {'generated_at':now,'status':'unavailable','reason':'analytics helper not installed'}
    spec=importlib.util.spec_from_file_location('fleet_outcome_analytics',source)
    analytics=importlib.util.module_from_spec(spec);spec.loader.exec_module(analytics)
    result={'generated_at':now,'status':'observed','boards':{}}
    for board in boards:
        try:
            with analytics.readonly(root/'kanban/boards'/board/'kanban.db') as db:
                result['boards'][board]=analytics.maintenance_outcomes(db,now-86400,now)
        except (OSError,ValueError,sqlite3.Error):
            result['boards'][board]={'status':'unavailable'}
    return result


def run_handler(command, *, root, board, timeout):
    environment = dict(os.environ, HERMES_ROOT=str(root), HERMES_HOME=str(root),
                       HERMES_KANBAN_HOME=str(root), HERMES_BOARD=board)
    try:
        with subprocess.Popen(command, env=environment, stdin=subprocess.DEVNULL,
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                              text=True, start_new_session=True) as process:
            try:
                output, _ = process.communicate(timeout=timeout)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.communicate(timeout=5)
                return {'exit_code': 124, 'output': 'Handler interrupted; reconcile native effects before requalification.'}
            return {'exit_code': process.returncode, 'output': output[-16000:]}
    except subprocess.TimeoutExpired:
        # Do not claim rollback or repeat an unchanged interrupted operation.
        return {'exit_code': 124, 'output': 'Handler timed out; reconcile its native effects before retry.'}


def input_identity(root, script):
    """Observe helper/config changes and DB availability, never heartbeat churn."""
    digest = hashlib.sha256()
    paths = sorted({script, *(root / 'scripts').glob('*.py'), *(root / 'scripts').glob('*.sh'),
                    root / 'config.yaml', *(root / 'profiles').glob('*/config.yaml')})
    if len(paths) > 512:
        raise ValueError('Supervisor dependency bound exceeded')
    for path in paths:
        digest.update(str(path.relative_to(root)).encode())
        if path.is_symlink():
            raise ValueError('Supervisor dependencies must not be symlinks')
        if path.is_file():
            if path.stat().st_size > 1024 * 1024:
                raise ValueError('Supervisor dependency size bound exceeded')
            digest.update(path.read_bytes())
    for path in sorted((root / 'kanban/boards').glob('*/kanban.db')):
        try:
            with closing(sqlite3.connect(path.as_uri() + '?mode=ro', uri=True, timeout=.1)) as db:
                db.execute('PRAGMA query_only=ON')
                db.execute('SELECT id FROM tasks LIMIT 1').fetchone()
                digest.update(json.dumps(db.execute("SELECT name,sql FROM sqlite_master WHERE type='table'"
                                                    " AND name IN ('tasks','task_runs','task_events','task_links','task_attachments')"
                                                    ' ORDER BY name').fetchall()).encode())
            availability = 'readable'
        except sqlite3.Error:
            availability = 'unavailable'
        digest.update((path.parent.name + availability).encode())
    return digest.hexdigest()


def continue_dispatch(root, board, db, task_id):
    """Wake one qualified supervision wait through the guarded native API."""
    from board_progress import require_resume
    try:
        if not require_resume(db, task_id):
            return
    except ValueError:
        return  # Still waiting, failed, typed, superseded or already continued.
    prior = db.execute('SELECT max(id) FROM task_events WHERE task_id=?', (task_id,)).fetchone()[0]
    subprocess.run(['hermes', '--profile', 'default', 'kanban', '--board', board, 'unblock', task_id,
                    '--reason', 'Dispatch wait satisfied by native worker starts; continue the same owner once.'],
                   check=True, capture_output=True, text=True, timeout=30,
                   env=dict(os.environ, HERMES_HOME=str(root), HERMES_KANBAN_HOME=str(root)))
    if not db.execute("SELECT 1 FROM task_events WHERE task_id=? AND kind='unblocked' AND id>? LIMIT 1",
                      (task_id, prior)).fetchone():
        raise ValueError('Qualified supervision continuation missing native transition readback')


def wake_coordinator(root, board, detector, output):
    """Keep native monitor-change routing, with one recovery owner per board."""
    if detector == 'board-progress':
        packet = json.loads(output)
        if packet['board'] != board or not re.fullmatch(r'[a-f0-9]{64}', packet['version']):
            raise ValueError('Board progress evidence identity differs')
        if packet.get('evidence_status') == 'unavailable':
            return
        evidence = json.dumps(packet, sort_keys=True)
    elif detector == 'board-health':
        lines = [re.sub(r' age=\S+', '', line) for line in output.splitlines()
                 if re.match(r'^(READY_NO_WORKER|DEAD_WORKER|PROFILE_OVER_CAP|TRIAGE_EXHAUSTED|'
                             r'WORKER_FAILED_BLOCKED|OWNER_COMMENT_UNACTED|CAPABILITY_OWNER_INPUT|'
                             r'CLASSIFICATION_AUDIT|UNMERGED_ACCEPTED_WORK|INSTRUCTION_DRIFT|'
                             r'SCRIPT_DRIFT|FLEET_RELEASE_DRIFT|MIRROR_STALE)\b', line)]
        if not lines:
            return
        from deadlock_recovery import attach_observations
        lines = attach_observations(root, board, detector, lines)
        if not lines:
            return
        evidence = '\n'.join(sorted(lines))
    elif detector == 'usage-guard':
        evidence='\n'.join(line for line in output.splitlines() if re.fullmatch(
            r'TOKEN_GUARD [A-Za-z0-9_.:/@+\-]+ incident=\d+ hold=proactive-intake',line))
        if not evidence:return
    elif detector == 'idle-state' and output.startswith('IDLE '):
        evidence = output
    else:
        return
    path = root / 'kanban/boards' / board / 'kanban.db'
    with closing(sqlite3.connect(path.as_uri() + '?mode=ro', uri=True, timeout=2)) as db:
        db.row_factory = sqlite3.Row
        db.execute('PRAGMA query_only=ON')
        existing=(db.execute("SELECT id FROM tasks WHERE status NOT IN ('done','archived','cancelled') "
                             "AND tenant='board-progress' LIMIT 1").fetchone() if detector=='board-progress' else
                  db.execute("SELECT id FROM tasks WHERE status NOT IN ('done','archived') AND created_by IN"
                      " ('fleet-supervisor','deadlock-recovery-monitor','aging-escalation','cron-loop-monitor') LIMIT 1").fetchone())
        if existing:
            if detector == 'board-progress':
                continue_dispatch(root, board, db, existing[0])
                return
            if detector!='usage-guard':return
            marker='Token guard incident: '+hashlib.sha256(evidence.encode()).hexdigest()
            if db.execute('SELECT 1 FROM task_comments WHERE task_id=? AND author=? AND instr(body,?)>0 LIMIT 1',
                          (existing[0],'fleet-supervisor',marker)).fetchone():return
            comment=(marker+'\n'+evidence+'\nInput supplier: agent. Inspect ~/.hermes/state/agent-usage/guard.json '
                     'and summary.json; follow documentation/langfuse.md#token-guards-and-alerts. '
                     'Optional proactive intake is held. Diagnose the named model/source and original-task '
                     'progress within this existing recovery task. Preserve active work, budgets and gates; '
                     'technical usage incidents do not require owner input.')
            subprocess.run(['hermes','--profile','default','kanban','--board',board,'comment',existing[0],comment,
                            '--author','fleet-supervisor'],check=True,capture_output=True,text=True,timeout=30,
                           env=dict(os.environ,HERMES_HOME=str(root),HERMES_KANBAN_HOME=str(root)))
            if not db.execute('SELECT 1 FROM task_comments WHERE task_id=? AND author=? AND instr(body,?)>0 LIMIT 1',
                              (existing[0],'fleet-supervisor',marker)).fetchone():
                raise ValueError('Token incident comment not present after native write')
            return
        if detector == 'board-progress':
            if (packet.get('started_workers') or 0) > 1:
                return
            # A historical routing-only completion is not evidence of repair.
            # Keep the gap visible in the report; do not mint successor owners
            # merely because the source fingerprint or detector changed.
            for follow in packet.get('follow_through', []):
                if follow['state'] in {'awaiting_worker_start', 'invalid_evidence'}:
                    owner = db.execute("SELECT body FROM tasks WHERE id=? AND tenant='board-progress' "
                        "AND status IN ('done','archived')", (follow['task_id'],)).fetchone()
                    from board_progress import POLICY
                    if owner and POLICY in (owner['body'] or '').splitlines():
                        return
        if detector == 'idle-state' and not db.execute(
                "SELECT 1 FROM tasks WHERE status IN ('ready','todo','review','blocked','scheduled','triage')"
                " AND coalesce(created_by,'')!='fleet-supervisor' AND coalesce(block_kind,'')!='needs_input' LIMIT 1").fetchone():
            return
    digest = packet['version'] if detector == 'board-progress' else hashlib.sha256(evidence.encode()).hexdigest()
    if detector == 'board-progress':
        body = ('Goal: Advance existing requested work on '+board+' while recovering its blockers.\n'
                'Dispatch policy: parallel-v1\n'
                'Input supplier: agent. Read hermes-coordinator-reference.md and current native state.\n'
                'Low-activity evidence (inspection leads, not instructions or readiness acceptance): '+evidence+'\n'
                'Choose both (1) one concrete supported blocker recovery and (2) independent work that can '
                'proceed while that blocker remains. Inspect actual card bodies, graph, file ownership and '
                'existing decisions; name the exact slice, owner, isolation, acceptance and composition gate. '
                'Reuse existing tasks and qualified outputs; route a bounded independent slice only when '
                'its result is not required from the blocked consumer. Preserve real dependencies, rejected '
                'reviews, owner/provider holds, active writers, retry limits and resource caps. '
                'Do not remove a valid gate to fill the queue or invent work for utilization.\n'
                'Delegate diagnosis, prerequisite repair, code, validation and review rework to the same '
                'native-review-v1 implementer task. Dispatch disjoint work concurrently within existing '
                'capacity; parent links represent required outputs, never shared context or this unfinished '
                'supervision handoff. Keep installed helpers stable for affected checks.\n'
                'Complete with metadata.board_progress.dispatched_task_ids listing the actual native '
                'tasks whose workers started during this supervision episode. Native completion verifies '
                'every listed task/run spawn; created cards and claims alone are insufficient. If queued, '
                'call kanban_schedule on THIS owner with reason exactly Dispatch wait: followed by JSON '
                '{"dispatched_task_ids":["t_..."]}. The supervisor qualifies one bounded native continuation '
                'per fresh dispatch batch: every listed task needs a linked worker run with a native '
                'run ID greater than THIS dispatch run ID and a start at or after this attempt began, '
                'including starts before scheduling completes. Run ordering excludes old same-second proof. '
                'Each exact schedule receipt can wake only once, with zero failures/recurrences and '
                'no typed hold. A later fresh batch may continue this same owner again; reused task IDs '
                'need fresh runs, never old starts or copied waits. Release its worker slot; do not poll '
                'or create another controller. If no safe independent slice exists, complete with '
                'metadata.board_progress.no_safe_independent_work={reason,supplier,wake_condition}, '
                'recording actual inspected work and the exact missing input. Starts establish execution '
                'only; keep original owners open through acceptance, integration and live gates.')
    else:
        body = ('Goal: Resolve one changed ' + detector + ' finding on ' + board + '.\n'
            'Input supplier: agent. Re-read native state and hermes-coordinator-reference.md.\n'
            'Evidence: ' + evidence[:1200] + '\n'
            'Preserve original receipt waits, owner/provider gates, independent acceptance and active writers.\n'
            'Stop after one supported repair/transition with readback, or retain the exact technical hold.\n'
            'Use existing task ownership; do not repeat unchanged investigation or create an acknowledgment chain.\n'
            + ('For TOKEN_GUARD: read ~/.hermes/state/agent-usage/guard.json and summary.json; '
               'follow documentation/langfuse.md#token-guards-and-alerts. Inspect contributing sessions '
               'and actual original-task progress. Optional proactive intake is already held; preserve '
               'active work, existing budgets and gates. Technical usage incidents stay internal; '
               'do not ask the owner for a routine token spike or unavailable telemetry.' if detector=='usage-guard' else ''))
    subprocess.run(['hermes', '--profile', 'default', 'kanban', '--board', board, 'create',
                    'Resolve changed ' + detector + ' finding', '--assignee', 'head-coordinator',
                    '--tenant', 'board-progress' if detector=='board-progress' else 'technical-recovery',
                    '--created-by', 'board-progress-monitor' if detector=='board-progress' else 'fleet-supervisor',
                    '--workspace', 'scratch', '--max-runtime', '360', '--max-retries', '1',
                    '--idempotency-key', 'fleet-monitor:' + detector + ':' + board + ':' + digest,
                    '--body', body], check=True, capture_output=True, text=True, timeout=30,
                   env=dict(os.environ, HERMES_HOME=str(root), HERMES_KANBAN_HOME=str(root)))


def deliver_wake(root, board, name, result, now):
    try:
        if name == 'technical-recovery':
            from recovery_wait import inspect as inspect_waits
            waits = inspect_waits(root)
            result['recovery_waits'] = waits
            refused = result.setdefault('recovery_wait_refusals', {})
            eligible = [(hashlib.sha256(json.dumps(wait, sort_keys=True).encode()).hexdigest(), wait)
                        for wait in waits['ready']]
            eligible = [(key, wait) for key, wait in eligible if key not in refused]
            for key, wait in eligible[:4]:
                path = root / 'kanban/boards' / wait['board'] / 'kanban.db'
                # The native transaction requalifies this exact schedule before
                # the supported resume. No second controller or SQL write here.
                try:
                    subprocess.run(['hermes', '--profile', 'default', 'kanban', '--board',
                        wait['board'], 'unblock', wait['task_id'], '--reason',
                        'Registered recovery wait satisfied by native event '
                        + str(wait['observed_event_id']) + '; reconcile the same owner once.'],
                        check=True, capture_output=True, text=True, timeout=15,
                        env=dict(os.environ, HERMES_HOME=str(root), HERMES_KANBAN_HOME=str(root)))
                except (OSError, subprocess.SubprocessError) as exc:
                    refused[key] = dict(board=wait['board'], task_id=wait['task_id'],
                                        schedule_event_id=wait['schedule_event_id'], error=type(exc).__name__)
                    raise
                with closing(sqlite3.connect(path.as_uri() + '?mode=ro', uri=True, timeout=1)) as db:
                    db.execute('PRAGMA query_only=ON')
                    if not db.execute("SELECT 1 FROM task_events WHERE task_id=? AND kind='unblocked' "
                                      'AND id>? LIMIT 1',
                                      (wait['task_id'], wait['schedule_event_id'])).fetchone():
                        raise ValueError('Recovery wait continuation missing native readback')
            result['wake_pending'] = False
            result.pop('wake_error', None)
            return
        if name == 'board-progress':
            for line in result['output'].splitlines():
                packet = json.loads(line)
                wake_coordinator(root, packet['board'], name, line)
            result['wake_pending'] = False
            result.pop('wake_error', None)
            return
        targets = re.findall(r'^IDLE ([A-Za-z0-9_-]+) ',result['output'],re.M) if name=='idle-state' else [board]
        for target in targets:
            wake_coordinator(root,target,name,result['output'])
        result['wake_pending']=False
        result.pop('wake_error',None)
    except (OSError,ValueError,sqlite3.Error,subprocess.SubprocessError) as exc:
        result['wake_attempts']=result.get('wake_attempts',0)+1
        result['wake_next_due']=now+300
        result['wake_error']=type(exc).__name__


def tick(root, *, now=None, runner=run_handler, dry_run=False, clock=None):
    clock=clock or (time.time if now is None else lambda:now)
    now = int(time.time()) if now is None else now
    directory = root / 'state/fleet'
    if root.is_symlink() or directory.is_symlink() or (root / 'state').is_symlink():
        raise ValueError('Supervisor state must not use symlinks')
    if dry_run:
        return 0
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd = os.open(directory / 'supervisor.lock', os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        path = directory / 'supervisor.json'
        if path.is_symlink():
            raise ValueError('Supervisor journal must be a regular owned file')
        state = json.loads(path.read_text()) if path.exists() else {}
        policy_path = directory / 'handlers.json'
        if policy_path.is_symlink():
            raise ValueError('Supervisor policy must not be a symlink')
        policy = json.loads(policy_path.read_text()) if policy_path.exists() else None
        boards = sorted(p.parent.name for p in (root / 'kanban/boards').glob('*/board.json')
                        if not p.parent.name.startswith(('_', '.')))
        if not boards:
            raise ValueError('No configured fleet boards')
        handlers = state.setdefault('handlers', {})
        # Conditions have their own cadence inside the existing supervisor.
        # A stopped/failed technical-recovery detector cannot suppress this scan.
        setting=(policy or {}).get('release-conditions', {})
        conditions=state.get('release_conditions', {})
        if setting.get('enabled') is True and now>=conditions.get('next_due',0):
            if setting.get('interval')!=300:
                raise ValueError('Release conditions require the reviewed five-minute cadence')
            from release_conditions import scan
            try:
                conditions=dict(scan(root,cursor=conditions.get('cursor',0)),last_run=now,next_due=now+300)
            except (OSError,ValueError,sqlite3.Error) as exc:
                conditions=dict(last_run=now,next_due=now+300,error=type(exc).__name__,cursor=conditions.get('cursor',0))
            state['release_conditions']=conditions
            atomic_write(path,json.dumps(state,sort_keys=True,indent=2)+'\n',mode=0o600)
        failed = False
        for name, interval, timeout, interpreter, filename, arguments in HANDLERS:
            if policy is not None:
                setting = policy.get(name, {})
                if setting.get('enabled') is not True:
                    continue
                interval = setting.get('interval')
                if type(interval) is not int or interval <= 0:
                    raise ValueError('Handler cadence must be a positive finite interval')
            if name=='proactive-intake' and intake_hold(read_usage_state(root/'state/agent-usage/guard.json'),clock()):
                # A transient or missing guard never authorizes fresh optional
                # work. Do not alter configured pauses, active cards or retries.
                continue
            targets = boards if name in {'retry-breaker','board-health','board-progress'} else [boards[0]]
            script = root / 'scripts' / filename
            identity = input_identity(root, script)
            for board in targets:
                key = name + (':' + board if name in {'retry-breaker','board-health','board-progress'} else '')
                previous = handlers.get(key, {})
                if (previous.get('wake_pending') and previous.get('wake_attempts',0)<3
                        and now>=previous.get('wake_next_due',0)):
                    deliver_wake(root,board,name,previous,now)
                    atomic_write(path,json.dumps(state,sort_keys=True,indent=2)+'\n',mode=0o600)
                failed |= bool(previous.get('wake_pending'))
                if previous.get('in_flight') or previous.get('interrupted'):
                    failed = True
                    continue
                changed = previous.get('identity') != identity
                if not changed and (now < previous.get('next_due', 0)
                                    or previous.get('failures', 0) >= MAX_FAILURES):
                    failed |= previous.get('failures', 0) > 0
                    continue
                command = [sys.executable if interpreter == 'python' else interpreter,
                           str(script), *arguments]
                handlers[key] = dict(previous, identity=identity, in_flight=True, started_at=now)
                atomic_write(path, json.dumps(state, sort_keys=True, indent=2) + '\n', mode=0o600)
                result = runner(command, root=root, board=board, timeout=timeout)
                failures = 0 if result['exit_code'] == 0 else (0 if changed else previous.get('failures', 0)) + 1
                failed |= bool(failures)
                handlers[key] = dict(identity=identity, last_run=now, exit_code=result['exit_code'],
                                     failures=failures, next_due=now + (interval if not failures else
                                                                      (300 if failures == 1 else 900)),
                                     interrupted=result['exit_code'] == 124,
                                     wake_pending=result['exit_code']==0 and name in {'board-health','idle-state','usage-guard','board-progress','technical-recovery'},
                                     output=result['output'])
                if name=='technical-recovery' and not changed:
                    handlers[key]['recovery_wait_refusals']=previous.get('recovery_wait_refusals',{})
                # Journal each natural exit so a later failed handler does not
                # repeat a successful mutating detector after a process crash.
                atomic_write(path, json.dumps(state, sort_keys=True, indent=2) + '\n', mode=0o600)
                if handlers[key]['wake_pending']:
                    deliver_wake(root,board,name,handlers[key],now)
                    failed |= bool(handlers[key].get('wake_pending'))
                    atomic_write(path,json.dumps(state,sort_keys=True,indent=2)+'\n',mode=0o600)
        report = dict(schema_version=1, generated_at=now, boards=boards, handlers=handlers,
                      release_conditions=state.get('release_conditions'),
                      outcomes=outcome_report(root,boards,now),
                      note='Generated local report; execution evidence and review acceptance remain separate.')
        atomic_write(directory / 'report.json', json.dumps(report, sort_keys=True, indent=2) + '\n', mode=0o600)
        return int(failed)
    finally:
        os.close(fd)


def requalify(root, handler, evidence, reason):
    """Rearm monitoring after measured repair; never reset any task/provider budget."""
    directory=root/'state/fleet'
    if not isinstance(reason,str) or not 10<=len(reason)<=1000:
        raise ValueError('Requalification needs a concrete repair/reconciliation reason')
    evidence=evidence.absolute()
    if (not evidence.is_relative_to(root/'state/fleet/evidence') or evidence.is_symlink()
            or not evidence.is_file() or evidence.stat().st_size>262144):
        raise ValueError('Use an actual bounded native-run evidence bundle')
    receipt=json.loads(evidence.read_text())
    if not isinstance(receipt,dict) or not {'schema_version','task_id','id','outcome'}<=receipt.keys():
        raise ValueError('Requalification evidence is not a captured native run')
    fd=os.open(directory/'supervisor.lock',os.O_CREAT|os.O_RDWR|os.O_NOFOLLOW,0o600)
    try:
        fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
        path=directory/'supervisor.json'
        state=json.loads(path.read_text())
        previous=state['handlers'].get(handler)
        if not previous or not any(previous.get(k) for k in ('failures','in_flight','interrupted','wake_pending')):
            raise ValueError('Handler has no stopped or failed attempt to requalify')
        digest=hashlib.sha256(evidence.read_bytes()).hexdigest()
        key=hashlib.sha256((handler+digest).encode()).hexdigest()
        record=directory/'requalifications'/f'{key}.json'
        if record.exists():
            raise ValueError('This exact evidence already requalified this handler')
        atomic_write(record,json.dumps(dict(handler=handler,evidence_sha256=digest,reason=reason,
                                           previous=previous,at=int(time.time())),sort_keys=True)+'\n',mode=0o600)
        state['handlers'][handler]={**previous,'failures':0,'in_flight':False,'interrupted':False,
                                    'wake_attempts':0,'next_due':0,'wake_next_due':0,
                                    'requalification_sha256':key}
        atomic_write(path,json.dumps(state,sort_keys=True,indent=2)+'\n',mode=0o600)
    finally:
        os.close(fd)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dry-run', action='store_true')
    parser.add_argument('--requalify')
    parser.add_argument('--evidence',type=Path)
    parser.add_argument('--reason')
    args = parser.parse_args()
    if any(os.environ.get(k) for k in ('HERMES_KANBAN_TASK', 'HERMES_KANBAN_RUN_ID',
                                      'HERMES_DELEGATED_CHILD_CONTEXT')):
        parser.error('Supervisor execution belongs to the local no-agent scheduler')
    try:
        root = Path(os.environ.get('HERMES_ROOT', str(Path.home() / '.hermes'))).absolute()
        if args.requalify:
            if args.dry_run or args.evidence is None:
                parser.error('Requalification needs --evidence and --reason, without --dry-run')
            requalify(root,args.requalify,args.evidence,args.reason)
            sys.exit(0)
        sys.exit(tick(root, dry_run=args.dry_run))
    except BlockingIOError:
        sys.exit(0)  # An existing tick retains ownership.
    except (OSError, ValueError) as exc:
        print('Fleet supervisor failed: ' + str(exc), file=sys.stderr)
        sys.exit(2)
