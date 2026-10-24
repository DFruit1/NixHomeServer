"""Bound worker assignments using the native Kanban lifecycle.

Python is operations glue loaded by the small tracked native-runtime adapter.
No new service or dependency; callers retain their existing authority checks.
"""
import re
import json
from pathlib import Path
import subprocess
import sqlite3

EVIDENCE = re.compile(r'^Recovery mode: evidence-only\s*$', re.M)
FAILURES = {'failed', 'crashed', 'timed_out', 'spawn_failed', 'gave_up'}


def creation(assignee, body, cap, retries):
    evidence = bool(EVIDENCE.search(body or ''))
    if assignee == 'local-implementer' or evidence:
        if type(cap) is not int or cap <= 0:
            raise ValueError('Worker policy: a positive integer max_runtime_seconds is required')
    if evidence:
        if retries is not None and (type(retries) is not int or retries != 1):
            raise ValueError('Evidence recovery requires max_retries=1 (stop on first failure)')
        return 1
    return retries


def assignment_reason(assignee, body, cap, retries):
    try:
        expected = creation(assignee, body, cap, retries)
        if expected != retries:
            return 'Worker policy: evidence recovery must persist max_retries=1 before release'
    except ValueError as exc:
        return str(exc)
    return None



def execution_skills(db, task_id, assignee, skills):
    """Exclude producer-only procedures from a proven current independent review.

    The task's original pins remain stored for implementer rework. All other
    skills, and ambiguous or non-review executions, retain their requirements.
    """
    skills = list(skills or [])
    if (not {'kanban-orchestration','nixhomeserver-shutdown-guard'}.intersection(skills)
            or assignee not in {'feature-reviewer', 'project-auditor'}):
        return skills
    try:
        task = db.execute('SELECT assignee,status,current_run_id FROM tasks WHERE id=?',
                          (task_id,)).fetchone()
        event = db.execute("SELECT id,kind,run_id,payload,created_at FROM task_events WHERE task_id=? "
                           "AND kind IN ('review_requested','changes_requested','review_reopened',"
                           "'completed','assigned','reclaimed') ORDER BY id DESC LIMIT 1", (task_id,)).fetchone()
        if not task or task['assignee'] != assignee or not event or event['kind'] != 'review_requested':
            return skills
        handoff = json.loads(event['payload'] or '{}')
        if (not isinstance(handoff,dict) or handoff.get('reviewer') != assignee
                or handoff.get('implementer') not in {
                    'standard-implementer','local-implementer','head-coordinator'}):
            return skills
        producer = db.execute('SELECT task_id,profile,status,outcome,ended_at FROM task_runs WHERE id=?',
                              (event['run_id'],)).fetchone()
        if (not producer or producer['task_id'] != task_id or producer['profile'] != handoff['implementer']
                or producer['status'] not in {'review','review_requested'} or producer['outcome'] != 'review_requested'
                or type(producer['ended_at']) is not int or type(event['created_at']) is not int
                or not 0 <= producer['ended_at'] <= event['created_at']):
            return skills
        # A historical handoff cannot qualify a later run or an orphaned claim.
        latest = [row['id'] for row in db.execute(
            'SELECT id FROM task_runs WHERE task_id=? ORDER BY id DESC LIMIT 2', (task_id,))]
        active = [row['id'] for row in db.execute(
            "SELECT id FROM task_runs WHERE task_id=? AND (status='running' OR ended_at IS NULL)",
            (task_id,))]
        claim = db.execute("SELECT id,run_id,payload,created_at FROM task_events WHERE task_id=? "
                           "AND kind='claimed' ORDER BY id DESC LIMIT 1", (task_id,)).fetchone()
        if task['status'] == 'running':
            run = db.execute('SELECT task_id,profile,status,outcome,ended_at FROM task_runs WHERE id=?',
                             (task['current_run_id'],)).fetchone()
            payload = json.loads(claim['payload'] or '{}') if claim else {}
            if (latest != [task['current_run_id'],event['run_id']] or active != [task['current_run_id']]
                    or not run or run['task_id'] != task_id or run['profile'] != assignee
                    or run['status'] != 'running' or run['outcome'] is not None
                    or run['ended_at'] is not None or not claim or claim['run_id'] != task['current_run_id']
                    or claim['id'] <= event['id'] or type(claim['created_at']) is not int
                    or claim['created_at'] < event['created_at'] or not isinstance(payload,dict)
                    or payload.get('source_status') != 'review'):
                return skills
        elif (task['status'] != 'review' or task['current_run_id'] is not None or active
                or not latest or latest[0] != event['run_id']
                or (claim and (claim['id'] >= event['id']
                               or type(claim['created_at']) is not int
                               or claim['created_at'] > event['created_at']))):
            return skills
    except (sqlite3.Error,ValueError,TypeError,KeyError):
        return skills  # Missing or ambiguous provenance never drops a pin.
    excluded = {'nixhomeserver-shutdown-guard'}
    if handoff['implementer'] == 'head-coordinator':
        excluded.add('kanban-orchestration')
    return [skill for skill in skills if skill not in excluded]


def reason(db, task_id, assignee=None):
    task = db.execute('SELECT assignee,body,max_runtime_seconds,max_retries FROM tasks WHERE id=?',
                      (task_id,)).fetchone()
    if task is None:
        return None  # Native lifecycle owns the unknown-task result.
    problem = assignment_reason(assignee or task['assignee'], task['body'],
                                task['max_runtime_seconds'], task['max_retries'])
    if problem:
        return problem
    iteration=db.execute("SELECT 1 FROM task_events WHERE task_id=? AND ("
        "json_type(payload,'$.iteration_continuation') IS NOT NULL OR "
        "json_extract(payload,'$.branch')='iteration-exhaustion-reaffirmation' OR "
        "(kind='gave_up' AND json_type(payload,'$.budget_max') IS NOT NULL)) LIMIT 1",(task_id,)).fetchone()
    # Claim admission applies to runnable/current executions. A parked task's
    # guarded recovery must first validate its NEW finite disposition; testing
    # the spent prior claim here would prevent issuing that release forever.
    if iteration and db.execute('SELECT status FROM tasks WHERE id=?',(task_id,)).fetchone()[0] in {'ready','review','running'}:
        try:
            from hermes_cli.nixhomeserver_resume_recovered import iteration_claim_authority
            iteration_claim_authority(db,task_id,allow_current=True)
        except (ImportError,ValueError) as exc:
            return 'Worker policy: '+str(exc)
    try:
        if __package__ == 'hermes_cli':
            from .nixhomeserver_fleet_contract import load as task_contract
        else:
            from fleet_contract import load as task_contract
        if task_contract(db, task_id) is not None:
            from hermes_cli.kanban_db_connect import _main_db_file
            from hermes_cli.nixhomeserver_execution_preflight import reason as execution_reason
            problem = execution_reason(db, task_id, Path(_main_db_file(db)).parents[3], assignee or task['assignee'])
            if problem:
                return problem
    except (ImportError, OSError, ValueError, TypeError, sqlite3.Error, subprocess.TimeoutExpired):
        return 'Worker policy: structured execution prerequisites unavailable; repair the installed contract/runtime. Input supplier: agent.'
    columns = {r[1] for r in db.execute('PRAGMA table_info(tasks)')}
    if {'skills','workspace_path'} <= columns:
        row = db.execute('SELECT skills,workspace_path FROM tasks WHERE id=?',(task_id,)).fetchone()
        skills = execution_skills(db, task_id, assignee or task['assignee'],
                                  json.loads(row['skills'] or '[]'))
        kind = (db.execute('SELECT workspace_kind FROM tasks WHERE id=?',(task_id,)).fetchone()[0]
                if 'workspace_kind' in columns else None)
        if skills and not (kind == 'worktree' and not row['workspace_path']):
            try:
                from hermes_cli.kanban_db_connect import _main_db_file
                from hermes_cli.nixhomeserver_coordinator_repair import available_skills
                path = Path(_main_db_file(db))
                root = path.parents[3]
                workspace = row['workspace_path']
                if not workspace:
                    workspace = json.loads(path.with_name('board.json').read_text()).get('default_workdir')
                missing = set(skills) - available_skills(root, assignee or task['assignee'], workspace)
                if missing:
                    return ('Worker policy: skill unavailable to assigned profile: '+', '.join(sorted(missing))+
                            '. Coordinator must amend the preload list or repair the scoped installation. Input supplier: agent.')
            except (ImportError,OSError,ValueError,TypeError,subprocess.TimeoutExpired):
                return 'Worker policy: assignee skill catalog unavailable; repair scoped catalog before launch. Input supplier: agent.'
    if not EVIDENCE.search(task['body'] or ''):
        return None
    run = db.execute('SELECT id,status,outcome,ended_at FROM task_runs WHERE task_id=? ORDER BY id DESC LIMIT 1',
                     (task_id,)).fetchone()
    if not run or not ({run['status'], run['outcome']} & FAILURES):
        return None
    # A receipt for an earlier run never grants another attempt. Read at most
    # 32 coordinator comments after this failure; no history or prompt export.
    comments = db.execute("SELECT body FROM task_comments WHERE task_id=? AND author='head-coordinator' "
                          'AND created_at>=? ORDER BY id DESC LIMIT 32',
                          (task_id, run['ended_at'] or 0))
    for comment in comments:
        body = comment['body'] or ''
        if (re.search(rf'^Recovery run: {run["id"]}\s*$', body, re.M)
                and re.search(r'^Recovery change: [^\s\n][^\n]*$', body, re.M)
                and re.search(r'^Recovery action: [^\s\n][^\n]*$', body, re.M)):
            return None
    return (f'Worker policy: record a new coordinator receipt with Recovery run: {run["id"]}, '
            'Recovery change: <changed input or narrowed scope>, and Recovery action: <bounded next step> '
            'on separate lines before retrying. Input supplier: agent.')


def require_release(db, task_id):
    problem = reason(db, task_id)
    if problem:
        raise ValueError(problem)


def park_assignment(kb, db, task_id, problem):
    """Park consumed finite authority without synthesizing an execution run."""
    prefix='Worker policy: Finite iteration continuation requires '
    if not problem.startswith(prefix):
        return kb.block_task(db,task_id,reason=problem,kind='capability')
    with kb.write_txn(db):
        task=db.execute('SELECT status,current_run_id,worker_pid,claim_lock,claim_expires '
                        'FROM tasks WHERE id=?',(task_id,)).fetchone()
        if (not task or task['status'] not in {'ready','review'}
                or any(task[key] is not None for key in ('current_run_id','worker_pid','claim_lock','claim_expires'))):
            raise ValueError('Finite continuation containment requires a parked, unleased task')
        if reason(db,task_id)!=problem:
            raise ValueError('Finite continuation containment evidence changed')
        run=db.execute('SELECT id,ended_at FROM task_runs WHERE task_id=? ORDER BY id DESC LIMIT 1',
                       (task_id,)).fetchone()
        event=db.execute("SELECT id,kind FROM task_events WHERE task_id=? AND run_id=? AND kind IN "
            "('gave_up','blocked','block_loop_detected','protocol_violation','rate_limited','spawn_failed','changes_requested','stale','crashed','timed_out','reclaimed','reconciled') "
            'ORDER BY id DESC LIMIT 1',(task_id,run['id'])).fetchone() if run else None
        if not run or run['ended_at'] is None or not event:
            raise ValueError('Finite continuation containment needs the actual ended native episode')
        phase=(kb._retry_status_for_run(db,task_id,run['id'])
               if event['kind']=='reconciled' else task['status'])
        db.execute("UPDATE tasks SET status='blocked',block_kind='capability' WHERE id=?",(task_id,))
        kb._append_event(db,task_id,'blocked',dict(kind='capability',reason=problem,
            branch='iteration-continuation-consumed',source_run=run['id'],source_event=event['id'],
            resume_status=phase))
    return True
