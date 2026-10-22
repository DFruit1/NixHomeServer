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
                raise ValueError('Recovery hold version changed; observe fresh evidence')
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
            reservation = dict(evidence, applied=False, journal_state='reserved-before-transition')
            reservation['intended_status'] = reservation.pop('status')
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
