"""Native, authenticated amendments to parked technical work.

Python extends Hermes' existing SQLite lifecycle, not a new backend. This API
does not release work, change verdicts, reset counters or confer tool powers.
"""
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys

ALLOWED = {'body', 'priority', 'skills', 'max_runtime_seconds', 'block_kind'}
# A static workspace binding is its own closed amendment: it records the exact
# directory an existing capability hold will run in and never types, releases,
# re-queues or re-arms that hold. Its independent workspace-prep attestation
# stays a coordinator obligation; this seam only records what it verified.
REBIND_FIELDS = {'workspace_kind', 'workspace_path'}
INTAKE_FIELDS = {'tenant'}
WRITABLE = ALLOWED | REBIND_FIELDS | INTAKE_FIELDS
PARKED = {'todo', 'blocked', 'scheduled', 'triage'}
# Native lifecycle kinds that can supersede one terminal episode. The snapshot
# CAS binds the newest of these, so a consumed or superseded episode id can
# never be replayed against a newer release, completion or re-block.
EPISODE_KINDS = ('blocked', 'block_loop_detected', 'dependency_wait', 'unblocked',
                 'completed', 'block_reclassified', 'gave_up', 'scheduled')
SUPPLIER = re.compile(r'Input supplier:\s*(agent|model/provider)\b')
# Material evidence a containment may cite; prose alone never classifies a hold.
MATERIAL = re.compile(r'(?:^|\s)(?:Repair evidence|Authorized continuation): \S')

# Fixed inspection program: use only the installed dependency selection. Native
# activate_dependencies also recovers config/plugin publications, so it is
# deliberately NOT used for catalog inspection. A pending publication refuses.
CATALOG_PROGRAM = '''import json,sys,site
from pathlib import Path
native=Path(sys.argv[1])
sys.path.insert(0,str(native))
from pm.environments import owning_home_root, install_state_dir, committed_venv, site_packages, venv_python_version
from hermes_cli.runtime_state import runtime_lock, lease_generation
from hermes_constants import set_hermes_home_override, reset_hermes_home_override
owner=owning_home_root(native)
token=set_hermes_home_override(str(owner)) if owner else None
selected=None
try:
    with runtime_lock(native,timeout=2) as held:
        if not held or (install_state_dir(native)/'publication.json').exists():
            raise RuntimeError('Dependency publication requires its owning maintenance path')
        environment=committed_venv(native)
        if environment is not None:
            if venv_python_version(environment) not in (None,sys.version_info[:2]):
                raise RuntimeError('Installed dependency interpreter differs')
            release=lease_generation(environment)
            selected=site_packages(environment)
            if not selected.is_dir():
                raise RuntimeError('Installed dependency packages unavailable')
finally:
    if token is not None:
        reset_hermes_home_override(token)
if selected is not None:
    site.addsitedir(str(selected))
sys.path.insert(0,str(native))
import tools.skills_tool as skills
assert Path(skills.__file__).resolve().is_relative_to(native)
print(json.dumps([s['name'] for s in skills._find_all_skills()]))
'''


def _episode(conn, tid):
    return conn.execute('SELECT id,run_id,kind,payload,created_at FROM task_events WHERE task_id=? '
                        'AND kind IN (' + ','.join('?' * len(EPISODE_KINDS)) + ') '
                        'ORDER BY id DESC LIMIT 1', (tid, *EPISODE_KINDS)).fetchone()


def snapshot(conn, tid):
    task = conn.execute('SELECT * FROM tasks WHERE id=?', (tid,)).fetchone()
    if task is None:
        raise ValueError('Unknown amendment target')
    task = dict(task)
    links = [list(r) for r in conn.execute(
        'SELECT parent_id,child_id FROM task_links WHERE parent_id=? OR child_id=? '
        'ORDER BY parent_id,child_id', (tid, tid))]
    run = conn.execute('SELECT id,status,outcome,metadata FROM task_runs WHERE task_id=? '
                       'ORDER BY id DESC LIMIT 1', (tid,)).fetchone()
    event = _episode(conn, tid)
    # One version binds the row, its links, the newest run and the newest
    # terminal lifecycle event: an amendment cannot ride a superseded episode.
    value = {'task': task, 'links': links, 'run': dict(run) if run else None,
             'episode': dict(event) if event else None}
    version = hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
    return task, version


def _parked(conn, task):
    if (task['status'] not in PARKED or '[FEATURE TRACKER' in task['title'].upper()
            or task['block_kind'] == 'needs_input'
            or any(task.get(k) is not None for k in ('worker_pid', 'claim_lock', 'claim_expires'))):
        raise ValueError('Amendments require a parked technical non-tracker with no worker or lease')
    if conn.execute("SELECT 1 FROM task_runs WHERE task_id=? AND "
                    "(status IN ('running','pending','claimed','starting') OR "
                    "(ended_at IS NULL AND outcome IS NULL)) LIMIT 1", (task['id'],)).fetchone():
        raise ValueError('Amendment refuses active or pending native work')


def _bare_repository_root(path):
    """A Git repository root keeps HEAD plus object and ref storage at its root.

    The layout, not the HEAD text, decides. A repository detaches HEAD as a
    SHA-1 40-hex or a SHA-256 64-hex object name, or keeps it as a symbolic ref,
    so a detector keyed to one object format read a SHA-256 bare root as an
    ordinary static directory. Refusing every repository-shaped root keeps the
    PRIMARY refusal independent of the object format Git was initialised with.
    """
    head = os.path.join(path, 'HEAD')
    if not os.path.lexists(head) or os.path.isdir(head):
        return False
    return (os.path.isdir(os.path.join(path, 'objects'))
            and os.path.isdir(os.path.join(path, 'refs')))


def _rebind_versions(conn, tid):
    """The workspace-rebind versions this card has already spent.

    A snapshot version binds the row, its links, the newest run and the newest
    lifecycle episode, but not the rebind history: a valid directory round trip
    A -> B -> A restores an earlier version byte for byte, so a plain inequality
    against the current snapshot cannot tell that the version was already
    consumed. Every recorded rebind keeps the exact version it consumed in its
    own native payload, which makes the consumption durable in the board's event
    log and readable again after a restart. The native retention sweep (gc_events)
    only prunes events of done/archived cards, which can never pass the parked
    amendment precondition again, so a live token's record is never reclaimed.
    """
    spent = set()
    for payload, in conn.execute("SELECT payload FROM task_events WHERE task_id=? "
                                 "AND kind='coordinator_workspace_rebind'", (tid,)):
        try:
            recorded = json.loads(payload or '{}')
        except (TypeError, ValueError):
            continue
        if isinstance(recorded, dict) and isinstance(recorded.get('expected_version'), str):
            spent.add(recorded['expected_version'])
    return spent


def _rebind_binding(conn, task, changes, rebind):
    """Validate a capability rebind or a missing initial source binding.

    The seam records only a binding it verified itself: the directory exists,
    is the canonical absolute path itself and is not a working-tree, worktree
    or bare repository root, so the primary checkout stays refused. It never
    types, releases or re-arms the hold; the coordinator's own workspace-prep
    receipt in the card thread and the versioned guarded resume remain the
    gates that follow. A request for the binding the card already holds is
    refused instead of recorded: it would append an event that changes no
    snapshot and would let one expected_version be replayed.
    """
    if not isinstance(rebind, dict) or set(rebind) != REBIND_FIELDS:
        raise ValueError('workspace_rebind must be a closed object of workspace_kind and workspace_path')
    if (not isinstance(changes, dict) or set(changes) != REBIND_FIELDS
            or any(changes[field] != rebind[field] for field in REBIND_FIELDS)):
        raise ValueError('A workspace rebind changes exactly its own two fields')
    initial = (task['status'] in {'todo','scheduled'} and task['block_kind'] is None
               and task['workspace_kind'] == 'scratch' and task['workspace_path'] is None
               and task.get('started_at') is None and task.get('current_run_id') is None
               and not (task.get('body') or '').lstrip().startswith('ASK:')
               and not conn.execute("SELECT 1 FROM task_runs WHERE task_id=? AND ("
                   "status IS NOT 'scheduled' OR outcome IS NOT 'scheduled' OR "
                   "worker_pid IS NOT NULL OR worker_started_at IS NOT NULL OR claim_lock IS NOT NULL OR "
                   "started_at IS NULL OR ended_at IS NULL OR started_at != ended_at) LIMIT 1",
                   (task['id'],)).fetchone()
               and not conn.execute("SELECT 1 FROM task_events WHERE task_id=? "
                   "AND kind IN ('claimed','spawned') LIMIT 1",(task['id'],)).fetchone())
    if task['block_kind'] != 'capability' and not initial:
        raise ValueError('Only a parked capability hold can adopt a static workspace')
    if rebind['workspace_kind'] != 'dir':
        raise ValueError('Only a static directory binding can be rebound')
    path = rebind['workspace_path']
    if (not isinstance(path, str) or not os.path.isabs(path) or os.path.normpath(path) != path
            or os.path.islink(path) or not os.path.isdir(path)):
        raise ValueError('A rebind needs one existing canonical absolute directory, never a link')
    if os.path.realpath(path) != path:
        # A symlinked ancestor is not the directory the handoff attested, so the
        # coordinator must pass the resolved path it actually verified.
        raise ValueError('A rebind needs one existing canonical absolute directory, never a link ancestor')
    if os.path.lexists(os.path.join(path, '.git')):
        raise ValueError('PRIMARY: a repository or worktree root cannot become a static workspace')
    if _bare_repository_root(path):
        raise ValueError('PRIMARY: a bare repository root cannot become a static workspace')
    stored = {'workspace_kind': task['workspace_kind'], 'workspace_path': task['workspace_path']}
    if stored == rebind:
        # Recording the stored binding again would append an event outside the
        # snapshot CAS, so the same expected_version could be replayed.
        raise ValueError('A rebind must change the stored binding; this card already holds that workspace')
    return {'workspace_kind': 'dir', 'workspace_path': path}


def _verification_intake(conn, task, changes, intake, reason):
    """Strengthen one untouched legacy verifier's classification, never release it."""
    if intake != 'standalone' or changes != {'tenant':'verification'}:
        raise ValueError('Verification intake changes exactly tenant to verification with standalone intent')
    if SUPPLIER.search(reason or '') is None or MATERIAL.search(reason or '') is None:
        raise ValueError('Verification intake needs agent/model supplier and material authorized-continuation evidence')
    if (task['status'] != 'todo' or task['assignee'] != 'feature-reviewer'
            or task['tenant'] != 'continuous-improvement' or task['block_kind'] is not None
            or task['consecutive_failures'] != 0
            or any(task.get(k) is not None for k in ('started_at','completed_at','current_run_id',
                'worker_started_at','last_heartbeat_at','last_failure_error'))
            or (task['body'] or '').lstrip().startswith('ASK:')):
        raise ValueError('Verification intake requires an untouched TODO feature-reviewer with inherited continuous-improvement tenant')
    if (task['workspace_kind'] != 'dir' or not task['workspace_path']
            or not os.path.isabs(task['workspace_path'])
            or os.path.realpath(task['workspace_path']) != task['workspace_path']
            or not os.path.isdir(task['workspace_path'])
            or type(task['max_runtime_seconds']) is not int or task['max_runtime_seconds'] <= 0):
        raise ValueError('Prepare the durable directory and finite runtime before verification intake')
    # session_id can be inherited from the creating coordinator; it is origin,
    # not proof of execution. Preserve it and require the actual run/event absence.
    if conn.execute('SELECT 1 FROM task_runs WHERE task_id=? LIMIT 1',(task['id'],)).fetchone():
        raise ValueError('Verification intake refuses every previously executed or scheduled run')
    if conn.execute("SELECT 1 FROM task_events WHERE task_id=? AND kind IN "
            "('claimed','spawned','review_requested','completed','blocked','scheduled','unblocked','gave_up') LIMIT 1",
            (task['id'],)).fetchone():
        raise ValueError('Verification intake refuses prior lifecycle provenance')
    creation=conn.execute("SELECT payload FROM task_events WHERE task_id=? AND kind='created' ORDER BY id LIMIT 1",
                          (task['id'],)).fetchone()
    if creation is None or len(creation['payload'] or '') > 65536:
        raise ValueError('Verification intake needs the original bounded creation record')
    created=json.loads(creation['payload'] or '{}')
    if (not isinstance(created,dict) or 'workflow' in created
            or re.search(r'(?m)^Workflow:\s*native-review-v1\s*$',task['body'] or '')
            or task.get('workflow_template_id') is not None or task.get('current_step_key') is not None):
        raise ValueError('Verification intake never rewrites a structured or native implementation workflow')


def _terminal_branch(conn, task, episode, reason):
    """Validate ONE closed terminal episode; name the branch it authorises.

    Both branches only APPEND one native classification/reaffirmation event.
    Neither creates a run, moves a counter, rewrites a lease or releases the
    card: the existing one-version reservation still governs the later release.
    Both branches also need the same supplier line and material repair or
    authorized-continuation evidence; the reaffirmation additionally needs the
    run's own native claim, reclaim and prior release chronology.
    """
    if (not isinstance(episode, dict) or set(episode) != {'run_id', 'event_id'}
            or any(type(episode[key]) is not int or episode[key] <= 0
                   for key in ('run_id', 'event_id'))):
        raise ValueError('terminal_episode must be a closed object of positive run_id and event_id')
    supplier = SUPPLIER.search(reason or '')
    if supplier is None:
        raise ValueError('A terminal episode requires an explicit agent/model input supplier')
    if MATERIAL.search(reason) is None:
        # Both branches cite material recovery evidence. Reaffirming a reclaim
        # trip without it would mint a fresh typed hold from a supplier line.
        raise ValueError('A terminal episode needs material repair or authorized continuation evidence')
    tid = task['id']
    event = conn.execute('SELECT id,run_id,kind,payload,created_at FROM task_events '
                         'WHERE id=? AND task_id=?', (episode['event_id'], tid)).fetchone()
    run = conn.execute('SELECT id,status,outcome,started_at,ended_at FROM task_runs '
                       'WHERE id=? AND task_id=?', (episode['run_id'], tid)).fetchone()
    latest_run = conn.execute('SELECT id FROM task_runs WHERE task_id=? ORDER BY id DESC LIMIT 1',
                              (tid,)).fetchone()
    latest = _episode(conn, tid)
    if event is None or run is None:
        raise ValueError('terminal_episode names no native run and event of this card')
    if latest_run is None or latest_run['id'] != run['id']:
        raise ValueError('terminal_episode is not the latest native run of this card')
    if latest is None or latest['id'] != event['id']:
        raise ValueError('A newer native lifecycle event supersedes this terminal episode')
    if run['ended_at'] is None or run['started_at'] is None or run['ended_at'] < run['started_at']:
        raise ValueError('terminal_episode names an unfinished or incoherent native run')
    if not isinstance(event['created_at'], int) or event['created_at'] < run['ended_at']:
        raise ValueError('The terminal event must follow its native run')
    try:
        payload = json.loads(event['payload'] or '{}')
    except (TypeError, ValueError):
        raise ValueError('Unsupported terminal episode payload') from None
    if not isinstance(payload, dict):
        raise ValueError('Unsupported terminal episode payload')
    if task['block_kind'] is None:
        # Branch A: the worker's own untyped terminal handoff, never every
        # blocked card and never a stale untyped event.
        if (event['kind'] != 'blocked' or payload.get('kind') is not None
                or event['run_id'] != run['id']
                or {run['status'], run['outcome']} != {'blocked'}):
            raise ValueError("Untyped containment needs this card's current untyped blocked handoff")
        return 'terminal-containment'
    if task['block_kind'] != 'capability':
        raise ValueError('Only an untyped containment or an existing capability episode can be typed')
    # Branch B: the breaker's trip sits on top of THIS run's own native claim
    # and reclaim, after the prior release, and its count/limit/timestamps
    # agree with the stored budget. Native gave_up trips are task-scoped
    # (run_id NULL), so the trip is bound by its own event id, not by a
    # fabricated run_id; the claimed and reclaimed records do carry run_id.
    if (event['kind'] != 'gave_up' or payload.get('trigger_outcome') != 'reclaimed'
            or {run['status'], run['outcome']} != {'reclaimed'}):
        raise ValueError('Capability reaffirmation needs the newest reclaimed gave_up episode')
    failures, limit = payload.get('failures'), payload.get('effective_limit')
    if (type(failures) is not int or type(limit) is not int or limit <= 0
            or failures != task['consecutive_failures'] or failures < limit):
        raise ValueError('Reaffirmation needs the coherent breaker count and limit of this episode')
    if payload.get('limit_source') == 'task' and limit != task['max_retries']:
        raise ValueError('Reaffirmation limit must match the stored retry budget')
    claim = conn.execute("SELECT id,created_at FROM task_events WHERE task_id=? AND kind='claimed' "
                         'AND run_id=? AND id<? ORDER BY id DESC LIMIT 1',
                         (tid, run['id'], event['id'])).fetchone()
    reclaim = conn.execute("SELECT id,created_at FROM task_events WHERE task_id=? AND kind='reclaimed' "
                           'AND run_id=? AND id<? ORDER BY id DESC LIMIT 1',
                           (tid, run['id'], event['id'])).fetchone()
    if claim is None or reclaim is None:
        raise ValueError("Reaffirmation needs this run's native claim and reclaim records")
    release = conn.execute("SELECT id,created_at FROM task_events WHERE task_id=? AND kind='unblocked' "
                           'AND id<? ORDER BY id DESC LIMIT 1', (tid, event['id'])).fetchone()
    if release is None:
        raise ValueError('Reaffirmation needs the prior release this reclaim trip followed')
    if release['id'] > claim['id']:
        # A release between this claim and the trip supersedes it: the trip did
        # not follow the newest release, so it is not this card's live episode.
        raise ValueError('Reaffirmation needs a claim after the latest prior release')
    stamps = (release['created_at'], claim['created_at'], reclaim['created_at'], event['created_at'])
    if any(type(stamp) is not int for stamp in stamps):
        raise ValueError('Reaffirmation needs bounded native event timestamps')
    if not release['id'] < claim['id'] < reclaim['id'] < event['id']:
        raise ValueError('Reaffirmation needs a claim, then reclaim, then gave_up event order')
    if not release['created_at'] <= claim['created_at'] <= reclaim['created_at'] <= event['created_at']:
        raise ValueError('Reaffirmation needs claim and reclaim timestamps after the prior release')
    if not run['started_at'] <= claim['created_at'] <= run['ended_at'] <= reclaim['created_at']:
        raise ValueError("Reaffirmation needs a claim and reclaim inside this run's own span")
    return 'reclaimed-reaffirmation'


def available_skills(root, profile, workspace):
    """Resolve the actual worker catalog in an isolated inspection process.

    Profile configuration/skill caches are process global upstream. A separate
    interpreter avoids changing the coordinator's config, cwd or credentials.
    All delegation pins survive. Passive dependency selection leases its
    installed generation; pending publication refuses without recovery.
    Project scans may refresh
    their cache. The fixed program never executes a skill or invokes board writes.
    """
    if not isinstance(profile, str) or not re.fullmatch(r'[a-z][a-z0-9-]{0,63}', profile):
        raise ValueError('Invalid assignee for skill lookup')
    home = root / 'profiles' / profile
    if not home.is_dir() or home.is_symlink():
        raise ValueError('Assignee profile is not installed')
    work = Path(workspace or root)
    if not work.is_dir():
        raise ValueError('Repair the missing workspace before validating skills')
    native=(root/'hermes-agent').resolve()
    env = dict(os.environ, HERMES_HOME=str(home), TERMINAL_CWD=str(work), PYTHONDONTWRITEBYTECODE='1')
    completed = subprocess.run([sys.executable, '-I', '-B', '-c', CATALOG_PROGRAM, str(native)],
                               cwd=work, env=env, capture_output=True, text=True, timeout=20)
    if completed.returncode or len(completed.stdout) > 1000000:
        raise ValueError('Assignee skill catalog unavailable; repair installed skills first')
    names = json.loads(completed.stdout)
    if not isinstance(names, list) or any(not isinstance(n, str) for n in names):
        raise ValueError('Invalid assignee skill catalog')
    return set(names)


def amend(kb, conn, tid, *, expected_version=None, changes=None, reason=None, runtime_evidence=None,
          terminal_episode=None, workspace_rebind=None, verification_intake=None):
    from hermes_cli.nixhomeserver_resume_recovered import coordinator_origin, require_actor_board
    actor = coordinator_origin()
    root, board = require_actor_board(conn, actor)
    if not isinstance(tid, str) or not re.fullmatch(r't_[a-z0-9_]{1,64}', tid):
        raise ValueError('Exact task ID required')
    if verification_intake is not None and (terminal_episode is not None or workspace_rebind is not None):
        raise ValueError('Verification intake is separate from terminal episodes and workspace binding')
    if verification_intake is None and isinstance(changes,dict) and set(changes) & INTAKE_FIELDS:
        raise ValueError('Tenant changes require the closed standalone verification intake')
    if terminal_episode is not None and (not isinstance(changes, dict) or set(changes) != {'block_kind'}):
        raise ValueError('A terminal episode is valid only with exactly the block_kind capability change')
    if terminal_episode is not None and workspace_rebind is not None:
        raise ValueError('A terminal episode and a workspace rebind are separate amendments')
    if workspace_rebind is None and isinstance(changes, dict) and set(changes) & REBIND_FIELDS:
        raise ValueError('A workspace binding changes only with its own closed rebind evidence')
    if changes is None:
        if terminal_episode is not None or workspace_rebind is not None or verification_intake is not None:
            raise ValueError('Inspection takes no amendment evidence')
        task, version = snapshot(conn, tid)
        return {'task_id': tid, 'version': version, 'status': task['status'],
                'fields': {k: task[k] for k in sorted(ALLOWED)}}
    if (not isinstance(changes, dict) or not changes or set(changes) - WRITABLE
            or not isinstance(reason, str) or not reason.strip() or len(reason) > 4000
            or not isinstance(expected_version, str) or not re.fullmatch(r'[0-9a-f]{64}', expected_version)):
        raise ValueError('Require exact version, allowlisted changes and bounded supersession evidence')
    # Native write_txn rechecks the actor and exact snapshot under the board lock.
    with kb.write_txn(conn):
        require_actor_board(conn, actor)
        task, version = snapshot(conn, tid)
        _parked(conn, task)
        if version != expected_version:
            raise ValueError('Card changed; inspect again before amending')
        if workspace_rebind is not None and version in _rebind_versions(conn, tid):
            # A valid A -> B -> A round trip restores a spent version byte for
            # byte, so the current-snapshot inequality above cannot see it. The
            # recorded consumption, not the restored snapshot, decides.
            raise ValueError('This version already consumed a workspace rebind; '
                             'inspect again before amending')
        branch = None
        binding = None
        resume_status = None
        if verification_intake is not None:
            _verification_intake(conn,task,changes,verification_intake,reason)
        if workspace_rebind is not None:
            binding = _rebind_binding(conn, task, changes, workspace_rebind)
        if 'block_kind' in changes:
            if terminal_episode is not None:
                # One closed terminal episode, one branch, one appended event.
                if (changes['block_kind'] != 'capability' or task['status'] != 'blocked'
                        or (task['body'] or '').lstrip().startswith('ASK:')):
                    raise ValueError('A terminal episode only types one blocked technical hold')
                branch = _terminal_branch(conn, task, terminal_episode, reason)
                resume_status = kb._resume_status_from_events(conn, tid)
            else:
                if (changes['block_kind'] != 'capability' or task['block_kind'] is not None
                        or task['status'] != 'blocked' or (task['body'] or '').lstrip().startswith('ASK:')
                        or not re.search(r'Input supplier:\s*(agent|model/provider)\b',reason)):
                    raise ValueError('Classify only an untyped parked failure as agent/model capability; never reclassify a gate')
                failure=conn.execute('SELECT status,outcome FROM task_runs WHERE task_id=? ORDER BY id DESC LIMIT 1',(tid,)).fetchone()
                if not failure or not ({failure['status'],failure['outcome']} & {'failed','crashed','timed_out','spawn_failed','gave_up'}):
                    raise ValueError('Capability classification requires the latest real failed run')
                # Native breaker's untyped parked episode needs a classification,
                # not a fresh failure or retry. Retain counters, errors and runs.
                conn.execute('UPDATE tasks SET block_recurrences=MAX(block_recurrences,1) WHERE id=?',(tid,))
                kb._append_event(conn,tid,'blocked',{'kind':'capability','reason':reason.strip(),
                                 'resume_status':kb._resume_status_from_events(conn,tid),
                                 'classified_in_place':True,'actor_task':actor['task_id'],'actor_run':actor['run_id']})
        if 'body' in changes:
            body = changes['body']
            if not isinstance(body, str) or not body.strip() or len(body) > 32000:
                raise ValueError('Body must be nonempty and bounded')
            from hermes_cli import nixhomeserver_worker_policy as policy
            if bool(policy.EVIDENCE.search(body)) != bool(policy.EVIDENCE.search(task['body'] or '')):
                raise ValueError('Amendment cannot add or remove the evidence-recovery fence')
        if 'priority' in changes and (type(changes['priority']) is not int or not -100 <= changes['priority'] <= 100):
            raise ValueError('Priority must be an integer within -100..100')
        if 'skills' in changes:
            skills = changes['skills']
            if (not isinstance(skills, list) or len(skills) > 8
                    or any(not isinstance(s, str) or not s.strip() for s in skills)
                    or len(set(skills)) != len(skills)):
                raise ValueError('Skills must be at most eight unique names')
            missing = (set(skills) - available_skills(root, task['assignee'], task['workspace_path'])) if skills else set()
            if missing:
                raise ValueError('Skills unavailable to assigned profile: ' + ', '.join(sorted(missing)))
        if 'max_runtime_seconds' in changes:
            cap = changes['max_runtime_seconds']
            old = task['max_runtime_seconds']
            if type(cap) is not int or not 1 <= cap <= 3600:
                raise ValueError('Runtime must be finite, positive and at most 3600 seconds')
            if old is not None and cap > old:
                if conn.execute("SELECT 1 FROM task_events WHERE task_id=? AND kind='coordinator_runtime_revision' LIMIT 1", (tid,)).fetchone():
                    raise ValueError('Only one measured runtime increase per card; narrow or split remaining work')
                if (not isinstance(runtime_evidence, dict)
                        or set(runtime_evidence) != {'run_id', 'remaining_work', 'expected_completion', 'stop_condition'}
                        or type(runtime_evidence['run_id']) is not int
                        or any(not isinstance(runtime_evidence[k], str) or not runtime_evidence[k].strip()
                               or len(runtime_evidence[k]) > 1000 for k in ('remaining_work','expected_completion','stop_condition'))):
                    raise ValueError('Runtime increase requires measured run, remaining work, expected completion and stop condition')
                run = conn.execute('SELECT * FROM task_runs WHERE id=? AND task_id=?', (runtime_evidence['run_id'],tid)).fetchone()
                latest = conn.execute('SELECT id FROM task_runs WHERE task_id=? ORDER BY id DESC LIMIT 1',(tid,)).fetchone()
                if (not run or not latest or latest[0] != run['id']
                        or 'timed_out' not in {run['status'],run['outcome']}
                        or not run['ended_at'] or not run['started_at'] or run['ended_at']-run['started_at'] < old):
                    raise ValueError('Runtime increase needs the latest actual timed-out run at the old cap')
                kb._append_event(conn, tid, 'coordinator_runtime_revision',
                                 {'old':old, 'new':cap, 'evidence':runtime_evidence, 'actor_run':actor['run_id']})
        evidence = {'board':board, 'actor_task':actor['task_id'], 'actor_run':actor['run_id'],
                    'expected_version':version, 'reason':reason.strip(),
                    'before':{k:task[k] for k in changes}, 'after':changes}
        for field, value in changes.items():
            if branch is not None and field == 'block_kind' and task['block_kind'] is not None:
                continue  # a reaffirmation keeps the stored kind byte-identical
            # Field names come exclusively from ALLOWED|REBIND_FIELDS (validated
            # closed sets above), never SQL input.
            conn.execute('UPDATE tasks SET '+field+'=? WHERE id=?',
                         (json.dumps(value) if field == 'skills' else value, tid))
        if verification_intake is not None:
            kb._append_event(conn,tid,'coordinator_verification_intake',evidence)
        elif binding is not None:
            # ONE honest native event for the recorded binding: the preimage it
            # replaced, the verified target, the native actor and its CAS. The
            # sealed hold, its counters and every run are untouched; the
            # workspace-prep attestation stays with the coordinator.
            kb._append_event(conn, tid, 'coordinator_workspace_rebind', {
                'branch':'static-directory-rebind',
                'before':{k:task[k] for k in sorted(REBIND_FIELDS)}, 'after':dict(binding),
                'expected_version':version, 'reason':reason.strip(),
                'actor_task':actor['task_id'], 'actor_run':actor['run_id'], 'board':board,
                'attestation_required':'independent workspace-prep receipt in the card thread before release'})
        elif terminal_episode is not None:
            # ONE honest native event: the branch, its source run/event, the
            # native actor, the supplier evidence and the resume phase. The
            # generic amendment audit is folded in rather than duplicated.
            kb._append_event(conn, tid, 'blocked', {
                'kind':'capability', 'reason':reason.strip(), 'resume_status':resume_status,
                'branch':branch, 'source_run':terminal_episode['run_id'],
                'source_event':terminal_episode['event_id'],
                'actor_task':actor['task_id'], 'actor_run':actor['run_id'], 'board':board,
                'supplier':SUPPLIER.search(reason).group(1), 'expected_version':version,
                'classified_in_place':branch == 'terminal-containment',
                'reaffirmed':branch == 'reclaimed-reaffirmation'})
        else:
            kb._append_event(conn, tid, 'coordinator_amended', evidence)
        after, new_version = snapshot(conn, tid)
        if binding is not None and new_version == version:
            # A recorded binding must be inside the consumed snapshot; an event
            # that changes no version would stay replayable forever.
            raise ValueError('A rebind must consume its exact version')
        for field, value in changes.items():
            if (json.loads(after[field] or '[]') if field == 'skills' else after[field]) != value:
                raise ValueError('Native amendment readback differs')
    kb.notify_task_updated(conn, tid, list(changes), board=board)
    return {'task_id':tid, 'version':new_version, 'applied':True, 'fields':changes}
