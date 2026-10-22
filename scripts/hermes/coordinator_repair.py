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
PARKED = {'todo', 'blocked', 'scheduled', 'triage'}

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
    value = {'task': task, 'links': links, 'run': dict(run) if run else None}
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


def amend(kb, conn, tid, *, expected_version=None, changes=None, reason=None, runtime_evidence=None):
    from hermes_cli.nixhomeserver_resume_recovered import coordinator_origin, require_actor_board
    actor = coordinator_origin()
    root, board = require_actor_board(conn, actor)
    if not isinstance(tid, str) or not re.fullmatch(r't_[a-z0-9_]{1,64}', tid):
        raise ValueError('Exact task ID required')
    if changes is None:
        task, version = snapshot(conn, tid)
        return {'task_id': tid, 'version': version, 'status': task['status'],
                'fields': {k: task[k] for k in sorted(ALLOWED)}}
    if (not isinstance(changes, dict) or not changes or set(changes) - ALLOWED
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
        if 'block_kind' in changes:
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
            # Field names come exclusively from ALLOWED, never SQL input.
            conn.execute('UPDATE tasks SET '+field+'=? WHERE id=?',
                         (json.dumps(value) if field == 'skills' else value, tid))
        kb._append_event(conn, tid, 'coordinator_amended', evidence)
        after, new_version = snapshot(conn, tid)
        for field, value in changes.items():
            if (json.loads(after[field] or '[]') if field == 'skills' else after[field]) != value:
                raise ValueError('Native amendment readback differs')
    kb.notify_task_updated(conn, tid, list(changes), board=board)
    return {'task_id':tid, 'version':new_version, 'applied':True, 'fields':changes}
