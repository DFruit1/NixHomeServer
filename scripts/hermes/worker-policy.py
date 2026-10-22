"""Bound worker assignments using the native Kanban lifecycle.

Python is operations glue loaded by the small tracked native-runtime adapter.
No new service or dependency; callers retain their existing authority checks.
"""
import re
import json
from pathlib import Path
import subprocess

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


def reason(db, task_id, assignee=None):
    task = db.execute('SELECT assignee,body,max_runtime_seconds,max_retries FROM tasks WHERE id=?',
                      (task_id,)).fetchone()
    if task is None:
        return None  # Native lifecycle owns the unknown-task result.
    problem = assignment_reason(assignee or task['assignee'], task['body'],
                                task['max_runtime_seconds'], task['max_retries'])
    if problem:
        return problem
    columns = {r[1] for r in db.execute('PRAGMA table_info(tasks)')}
    if {'skills','workspace_path'} <= columns:
        row = db.execute('SELECT skills,workspace_path FROM tasks WHERE id=?',(task_id,)).fetchone()
        skills = json.loads(row['skills'] or '[]')
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
