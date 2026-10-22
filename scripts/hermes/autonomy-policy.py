#!/usr/bin/env python3
"""Execute an exact owner-approved or independently reviewed delegated operation.

Python is integration glue for Hermes' SQLite records and native coordinator
decisions, matching deployment-receipt.py; no service or dependency is added.
Transport authentication remains the coordinator's responsibility. This is a
workflow boundary on a shared Unix account, not protection against that account.
Requests, declared inputs and command outputs must be credential-free.
"""
import argparse
from contextlib import contextmanager
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import selectors
import signal
import socket
import sqlite3
import subprocess
import sys
import time
import uuid

from hermes_common import atomic_write

IDENTITY_ENV = ('HERMES_PROFILE_NAME', 'HERMES_PROFILE', 'HERMES_HOME', 'HERMES_ROOT',
                'HERMES_KANBAN_HOME', 'HERMES_KANBAN_DB', 'HERMES_KANBAN_BOARD',
                'HERMES_KANBAN_TASK', 'HERMES_KANBAN_RUN_ID', 'HERMES_KANBAN_CLAIM_LOCK',
                'HERMES_DELEGATED_CHILD_CONTEXT')
CAPTURE_LIMIT = 4 * 1024 * 1024
RESERVED_RISKS = {'credentials', 'destructive-data', 'public-exposure',
                  'new-spending', 'owner-outcome', 'build-allocation'}


def _json(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), allow_nan=False)


def _content_identity(stat):
    """The stat fields that change only when a file's content changes.

    ``atime`` moves on every read (tmpfs honours it), so comparing the whole
    stat result made hashing a scratch fixture look like concurrent
    modification. Ownership and mode changes are not content changes either.
    """
    return (stat.st_dev, stat.st_ino, stat.st_size, stat.st_mtime_ns)


def _file(path):
    path = Path(path).resolve(strict=True)
    before = path.stat()
    if not path.is_file() or before.st_size > 512 * 1024 * 1024:
        raise ValueError('Declare a regular, bounded input file')
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
    if _content_identity(before) != _content_identity(path.stat()):
        raise ValueError('Input changed while hashing')
    return {'path': str(path), 'sha256': digest.hexdigest()}


def _directory(root, digest):
    if not re.fullmatch(r'[a-f0-9]{64}', digest):
        raise ValueError('Invalid request digest')
    base = Path(root).resolve() / 'kanban/approved-operations'
    path = base / digest
    if not path.resolve().is_relative_to(base):
        raise ValueError('Operation path leaves its durable directory')
    return path


def _board_path(root, board):
    if not re.fullmatch(r'[a-z0-9][a-z0-9_-]{0,63}', board):
        raise ValueError('Invalid board slug')
    root = Path(root).resolve()
    base = root if board == 'default' else root / 'kanban/boards'
    path = root / 'kanban.db' if board == 'default' else base / board / 'kanban.db'
    if not path.resolve().is_relative_to(base):
        raise ValueError('Board path leaves the board directory')
    return path.resolve()


@contextmanager
def _board(root, board):
    db = sqlite3.connect(_board_path(root, board).as_uri() + '?mode=ro', uri=True)
    db.row_factory = sqlite3.Row
    db.execute('PRAGMA query_only=ON')
    try:
        yield db
    finally:
        db.close()


def prepare(root, board, task_id, argv, cwd, effects, recovery, executor,
            timeout=300, inputs=(), environment=None, authority='owner', risk_classes=()):
    _authority(authority, list(risk_classes))
    if not re.fullmatch(r't_[a-z0-9_]{1,64}', task_id):
        raise ValueError('Invalid task id')
    if (not isinstance(argv, list) or not argv or len(argv) > 128
            or any(not isinstance(a, str) or '\0' in a or len(a) > 16384 for a in argv)
            or not Path(argv[0]).is_absolute()):
        raise ValueError('Use an explicit argv with an absolute executable')
    if type(timeout) is not int or not 1 <= timeout <= 3600:
        raise ValueError('Timeout must be an integer from 1 to 3600 seconds')
    if executor not in {'operator', 'head-coordinator', 'standard-implementer', 'local-implementer'}:
        raise ValueError('Choose an execution role, preserving independent review')
    if any(not isinstance(t, str) or not t.strip() or len(t) > 4000 for t in (effects, recovery)):
        raise ValueError('Describe expected effects and recovery')
    cwd = Path(cwd).resolve(strict=True)
    if not cwd.is_dir() or len(inputs) > 32:
        raise ValueError('Use an existing directory and at most 32 inputs')
    with _board(root, board) as db:
        if not db.execute('SELECT id FROM tasks WHERE id=?', (task_id,)).fetchone():
            raise ValueError('Operation gate does not exist')
    stat = cwd.stat()
    executable = _file(argv[0])
    controlled = {k: os.environ[k] for k in ('PATH', 'HOME', 'LANG', 'LC_ALL', 'TZ') if k in os.environ}
    for key, value in (environment or {}).items():
        if (not re.fullmatch(r'[A-Z][A-Z0-9_]{0,63}', key)
                or re.search(r'PASSWORD|PASSWD|SECRET|TOKEN|API_KEY|PRIVATE_KEY|AUTH_SOCK', key)
                or key in IDENTITY_ENV or key in {'PYTHONPATH', 'PYTHONHOME', 'BASH_ENV', 'ENV',
                                                 'LD_PRELOAD', 'LD_LIBRARY_PATH'}
                or not isinstance(value, str) or '\0' in value or len(value) > 4096):
            raise ValueError('Declare only non-secret, non-loader environment inputs')
        controlled[key] = value
    manifest = dict(schema_version=1, board=board, task_id=task_id,
                    nonce=uuid.uuid4().hex, hostname=socket.gethostname(),
                    argv=[executable['path'], *argv[1:]], executable=executable,
                    cwd=str(cwd), cwd_identity=[stat.st_dev, stat.st_ino],
                    effects=effects, recovery=recovery, executor=executor,
                    timeout=timeout, inputs=[_file(p) for p in inputs], environment=controlled)
    manifest.update(authority=authority, risk_classes=sorted(set(risk_classes)))
    digest = hashlib.sha256(_json(manifest).encode()).hexdigest()
    manifest['sha256'] = digest
    directory = _directory(root, digest)
    directory.mkdir(parents=True, exist_ok=False, mode=0o700)
    atomic_write(directory / 'request.json', _json(manifest) + '\n')
    return manifest


def _profile():
    name = os.environ.get('HERMES_PROFILE_NAME') or os.environ.get('HERMES_PROFILE')
    if name:
        return name
    home = Path(os.environ.get('HERMES_HOME', str(Path.home() / '.hermes')))
    return home.name if home.parent.name == 'profiles' else 'operator'


def _authority(authority, risks):
    if (authority not in {'owner', 'delegated'} or not isinstance(risks, list)
            or any(not isinstance(risk, str) or risk not in RESERVED_RISKS for risk in risks)):
        raise ValueError('Declare owner or delegated authority and recognized risk classes')
    if authority == 'delegated' and risks:
        raise ValueError('Reserved effects require exact owner approval, not fence widening')


def _accepted_review(db, review, executor):
    task = db.execute('SELECT status,assignee,tenant FROM tasks WHERE id=?', (review,)).fetchone()
    run = db.execute('SELECT profile,status,outcome,metadata FROM task_runs '
                     'WHERE task_id=? ORDER BY id DESC LIMIT 1', (review,)).fetchone()
    if (not task or task['status'] != 'done' or task['tenant'] != 'verification' or not run
            or run['profile'] not in {'feature-reviewer', 'project-auditor'}
            or task['assignee'] != run['profile']
            or run['profile'] == executor or run['status'] != 'done'
            or run['outcome'] != 'completed' or not isinstance(run['metadata'], str)
            or len(run['metadata']) > 65536):
        raise ValueError('Require the latest completed independent operation review')
    metadata = json.loads(run['metadata'])
    independence = metadata.get('independence') if isinstance(metadata, dict) else None
    if run['profile'] == 'project-auditor' and (
            not isinstance(independence, dict) or independence.get('plan_author') is not False
            or independence.get('implementer') is not False):
        raise ValueError('Auditor verification requires explicit independence from plan and implementation')
    if (not isinstance(metadata, dict) or metadata.get('verdict') != 'accept'
            or not isinstance(metadata.get('revision'), str) or not metadata['revision'].strip()):
        raise ValueError('Independent review has no current acceptance')
    checks = metadata.get('checks')
    if (not isinstance(checks, list) or not checks
            or any(not isinstance(item, dict) or not isinstance(item.get('command'), str)
                   or not item['command'].strip() or type(item.get('exit_code')) is not int
                   or item['exit_code'] != 0 for item in checks)):
        raise ValueError('Independent operation acceptance requires executed successful checks')
    return metadata


def _delegated_review(db, manifest, decision):
    review = decision.get('review_task_id')
    if not isinstance(review, str) or not re.fullmatch(r't_[a-z0-9_]{1,64}', review):
        raise ValueError('Name the independent operation review card')
    parents = list(db.execute('SELECT l.parent_id,t.status,t.assignee,t.tenant FROM task_links l '
                              'LEFT JOIN tasks t ON t.id=l.parent_id WHERE l.child_id=?',
                              (manifest['task_id'],)))
    if review not in {parent['parent_id'] for parent in parents}:
        raise ValueError('Link the independent review as an operation prerequisite')
    if any(parent['status'] != 'done' for parent in parents):
        raise ValueError('Operation has unfinished or missing prerequisites')
    # A selected older accept cannot override another live review prerequisite.
    # Supersede rejected edges through the native reviewed replacement lifecycle.
    for parent in parents:
        if parent['tenant'] == 'verification' and parent['assignee'] in {'feature-reviewer', 'project-auditor'}:
            _accepted_review(db, parent['parent_id'], manifest['executor'])
    metadata = _accepted_review(db, review, manifest['executor'])
    scope = dict(request_sha256=manifest['sha256'], executor=manifest['executor'], risk_classes=[])
    if metadata['revision'] != manifest['sha256'] or metadata.get('operation_scope') != scope:
        raise ValueError('Independent acceptance must match the exact operation and reserved-effect classification')


def check(root, digest, profile=None):
    directory = _directory(root, digest)
    manifest = json.loads((directory / 'request.json').read_text())
    payload = {k: v for k, v in manifest.items() if k != 'sha256'}
    if (manifest.get('sha256') != digest or manifest.get('schema_version') != 1
            or hashlib.sha256(_json(payload).encode()).hexdigest() != digest):
        raise ValueError('Request identity changed; obtain a fresh approval')
    authority = manifest.get('authority', 'owner')  # Existing v1 owner requests remain valid.
    _authority(authority, manifest.get('risk_classes', []))
    if os.environ.get('HERMES_DELEGATED_CHILD_CONTEXT'):
        raise ValueError('Delegated children cannot execute owner-approved operations')
    worker = os.environ.get('HERMES_KANBAN_TASK')
    if worker and (worker != manifest['task_id'] or Path(os.environ.get('HERMES_KANBAN_DB', '')).resolve()
                   != _board_path(root, manifest['board'])):
        raise ValueError('Worker ownership does not match the approved operation gate')
    if (profile or _profile()) != manifest['executor']:
        raise ValueError('This is not the approved executor')
    if manifest['hostname'] != socket.gethostname():
        raise ValueError('Execution hostname changed')
    cwd = Path(manifest['cwd'])
    if not cwd.is_dir():
        raise ValueError('Working directory disappeared')
    stat = cwd.stat()
    if not cwd.is_dir() or [stat.st_dev, stat.st_ino] != manifest['cwd_identity']:
        raise ValueError('Working directory identity changed')
    for item in [manifest['executable'], *manifest['inputs']]:
        if _file(item['path']) != item:
            raise ValueError('Reviewed input or executable changed')
    if (directory / 'running.json').exists() or (directory / 'receipt.json').exists():
        raise ValueError('Operation already started; no automatic repeat')
    with _board(root, manifest['board']) as db:
        db.execute('BEGIN')
        task = db.execute('SELECT status FROM tasks WHERE id=?', (manifest['task_id'],)).fetchone()
        if task is None or task['status'] in {'done', 'archived'}:
            raise ValueError('Operation gate is no longer open')
        decision = None
        for comment in db.execute('SELECT author,body FROM task_comments WHERE task_id=? ORDER BY id',
                                  (manifest['task_id'],)):
            if comment['author'] in {'user', 'owner', 'desktop'}:
                decision = None  # Later owner feedback must be reconciled first.
            if comment['author'] != 'head-coordinator' or not any(
                    key in (comment['body'] or '') for key in
                    ('owner_execution_decision', 'delegated_execution_decision')):
                continue
            try:
                key = 'owner_execution_decision' if authority == 'owner' else 'delegated_execution_decision'
                decision = json.loads(comment['body'])[key]
            except (ValueError, KeyError, TypeError):
                decision = None
        if (not isinstance(decision, dict) or decision.get('approved') is not True
                or decision.get('request_sha256') != digest
                or decision.get('executor') != manifest['executor']):
            raise ValueError('No current coordinator-recorded exact ' + authority + ' approval')
        if authority == 'owner':
            if (not isinstance(decision.get('owner_reply'), str) or not re.search(
                    r'\bapprove\s+' + digest + r'\b', decision['owner_reply'], re.I)):
                raise ValueError('No current coordinator-recorded exact owner approval')
        else:
            _delegated_review(db, manifest, decision)
    return manifest


def execute(root, digest, profile=None):
    directory = _directory(root, digest)
    with (directory / 'execution.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        manifest = check(root, digest, profile)
        started = dict(request_sha256=digest, executor=manifest['executor'],
                       hostname=socket.gethostname(), started_at=int(time.time()))
        atomic_write(directory / 'running.json', _json(started) + '\n')
        fd = os.open(directory, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)
        # Durable start precedes spawning. Crash/timeout/nonzero never replenish approval.
        # Outputs are durable evidence, not scratch. The reviewed command contract must
        # exclude credential values, just as deployment logs and declared inputs do.
        status = None
        env = {**manifest['environment'], **{k: os.environ[k] for k in IDENTITY_ENV if k in os.environ}}
        with (directory / 'stdout.txt').open('xb') as out, (directory / 'stderr.txt').open('xb') as err:
            process = subprocess.Popen(manifest['argv'], cwd=manifest['cwd'], stdout=subprocess.PIPE,
                                       stderr=subprocess.PIPE, start_new_session=True, env=env)
            total = 0
            deadline = time.monotonic() + manifest['timeout']
            drain_until = None
            def stop_group():
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
            try:
                with selectors.DefaultSelector() as selector:
                    selector.register(process.stdout, selectors.EVENT_READ, out)
                    selector.register(process.stderr, selectors.EVENT_READ, err)
                    while selector.get_map():
                        if drain_until is not None and time.monotonic() >= drain_until:
                            break  # Detached descendants may retain inherited pipe FDs.
                        if status is None and time.monotonic() >= deadline:
                            status = 'timed_out'
                            stop_group()
                            drain_until = time.monotonic() + .2
                        for key, _ in selector.select(.1):
                            chunk = os.read(key.fd, 65536)
                            if not chunk:
                                selector.unregister(key.fileobj)
                                continue
                            allowed = max(0, min(len(chunk), CAPTURE_LIMIT - total))
                            key.data.write(chunk[:allowed]); total += allowed
                            if allowed < len(chunk) and status is None:
                                status = 'output_limit'
                                stop_group()
                                drain_until = time.monotonic() + .2
                try:
                    process.wait(timeout=max(.1, deadline - time.monotonic()))
                except subprocess.TimeoutExpired:
                    status = 'timed_out'
                    stop_group()
                    process.wait()
            except BaseException:
                if process.poll() is None:
                    stop_group()
                process.wait()
                raise
            finally:
                process.stdout.close(); process.stderr.close()
        def preview(name):
            with (directory / name).open('rb') as stream:
                return stream.read(65536).decode('utf-8', 'replace')
        receipt = dict(started, finished_at=int(time.time()),
                       status=status or ('succeeded' if process.returncode == 0 else 'failed'),
                       exit_code=process.returncode,
                       stdout=preview('stdout.txt'), stderr=preview('stderr.txt'),
                       output_sha256={p: _file(directory / p)['sha256'] for p in ('stdout.txt', 'stderr.txt')},
                       execution_provenance=('bot-after-delegated-approval' if manifest.get('authority') == 'delegated'
                                             else 'bot-after-owner-approval'))
        atomic_write(directory / 'receipt.json', _json(receipt) + '\n')
        return receipt


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    actions = parser.add_subparsers(dest='action', required=True)
    prepare_parser = actions.add_parser('prepare')
    for name in ('board', 'task', 'cwd', 'effects', 'recovery', 'executor'):
        prepare_parser.add_argument('--' + name, required=True)
    prepare_parser.add_argument('--timeout', type=int, default=300)
    prepare_parser.add_argument('--input', action='append', default=[])
    prepare_parser.add_argument('--env', action='append', default=[], metavar='NAME=VALUE')
    prepare_parser.add_argument('--authority', choices=('owner', 'delegated'), default='owner')
    prepare_parser.add_argument('--risk-class', action='append', choices=sorted(RESERVED_RISKS), default=[])
    prepare_parser.add_argument('argv', nargs=argparse.REMAINDER)
    for name in ('check', 'execute'):
        actions.add_parser(name).add_argument('sha256')
    args = parser.parse_args()
    root = Path(os.environ.get('HERMES_ROOT', str(Path.home() / '.hermes')))
    try:
        if args.action == 'prepare':
            argv = args.argv[1:] if args.argv[:1] == ['--'] else args.argv
            result = prepare(root, args.board, args.task, argv, Path(args.cwd), args.effects,
                             args.recovery, args.executor, args.timeout, [Path(p) for p in args.input],
                             dict(item.split('=', 1) for item in args.env), args.authority, args.risk_class)
        else:
            result = (check if args.action == 'check' else execute)(root, args.sha256)
        print(json.dumps(result, indent=2))
        if args.action == 'execute' and result['status'] != 'succeeded':
            return result['exit_code'] if 0 < result['exit_code'] < 126 else 1
        return 0
    except (OSError, ValueError, sqlite3.Error) as exc:
        print(f'Approved operation refused: {exc}', file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())
