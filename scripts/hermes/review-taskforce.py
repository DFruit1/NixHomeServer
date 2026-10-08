#!/usr/bin/env python3
"""Hermes operations glue; stdlib Python matches the host's Hermes runtime.

No service/backend or new dependency is introduced. Board writes use the Hermes
CLI; locked, atomic file writes protect the reviewer's persisted documents.
"""
import argparse
from contextlib import closing, contextmanager
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import sqlite3
import subprocess
import sys
import tempfile
import time

TENANT = 'continuous-improvement'
OPPORTUNITY_TITLE = 'Review: choose a focused improvement audit'
CADENCES = {'off': 0, 'daily': 24, 'weekly': 168}
IMPLEMENTERS = {'standard-implementer', 'local-implementer'}


def review_dir(root, board):
    if not re.fullmatch(r'[a-zA-Z0-9][a-zA-Z0-9_-]*', board):
        raise ValueError('Invalid board slug')
    path = root / 'kanban/boards' / board
    if not (path / 'board.json').is_file():
        raise ValueError(f'Unknown board: {board}')
    return path / 'review-taskforce'


@contextmanager
def locked(path):
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    with (path / '.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        yield


def atomic_write(path, content):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, name = tempfile.mkstemp(prefix='.write-', dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as stream:
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def configure(root, board, cadence, interval_hours=None):
    if cadence not in {*CADENCES, 'custom'}:
        raise ValueError('Cadence must be off, daily, weekly or custom')
    hours = CADENCES.get(cadence, interval_hours)
    if not isinstance(hours, int) or isinstance(hours, bool) or hours < 0 or (cadence == 'custom' and hours < 1):
        raise ValueError('Custom interval_hours must be a positive integer')
    directory = review_dir(root, board)
    with locked(directory):
        atomic_write(directory / 'config.json', json.dumps({'cadence': cadence, 'interval_hours': hours}, indent=2) + '\n')
        if not (directory / 'FINDINGS.md').exists():
            atomic_write(directory / 'FINDINGS.md',
                         f'# {board} continuous improvement findings\n\n'
                         'Owner: `project-auditor`. Other profiles submit reports on their cards.\n\n'
                         'No findings assessed yet. Preserve accepted, deferred, rejected and verified outcomes.\n')


def hermes(board, *args):
    command = ['hermes', '--profile', 'default', 'kanban', '--board', board, *args, '--json']
    env = os.environ.copy()
    if env.get('HERMES_ROOT'):
        env['HERMES_HOME'] = env['HERMES_ROOT']
    result = subprocess.run(command, check=True, capture_output=True, text=True, timeout=60, env=env)
    return json.loads(result.stdout)


def board_tasks(root, board):
    """Read durable task state without CLI initialization or readiness promotion.

    Hermes CLI reads may enter a write transaction, which delegated terminal
    subprocesses correctly reject. A SQLite mode=ro connection preserves that
    write fence and reads the requested board regardless of inherited DB pins.
    Missing databases fail closed; never create or migrate them here.
    """
    database = review_dir(root, board).parent / 'kanban.db'
    with closing(sqlite3.connect(database.resolve().as_uri() + '?mode=ro', uri=True,
                                   timeout=10)) as connection:
        connection.row_factory = sqlite3.Row
        connection.execute('PRAGMA query_only = ON')
        return [dict(row) for row in connection.execute(
            'SELECT id, title, body, assignee, status, tenant, created_by FROM tasks')]


def tick(root, now=None):
    now = int(time.time()) if now is None else now
    errors = []
    for board_file in sorted((root / 'kanban/boards').glob('*/board.json')):
        try:
            tick_board(root, board_file, now)
        except (ValueError, OSError, RuntimeError, sqlite3.Error, subprocess.SubprocessError) as exc:
            errors.append(f'{board_file.parent.name}: {exc}')
    if errors:
        raise RuntimeError('; '.join(errors))


def tick_board(root, board_file, now):
    board = board_file.parent.name
    if board.startswith('_'):
        return
    directory = review_dir(root, board)
    config_file = directory / 'config.json'
    if not config_file.exists():
        return
    with locked(directory):
        config = json.loads(config_file.read_text())
        hours = config['interval_hours']
        if not isinstance(hours, int) or isinstance(hours, bool) or hours < 0:
            raise ValueError(f'Invalid cadence for {board}')
        if not hours:
            return
        state_file = directory / 'schedule.json'
        state = json.loads(state_file.read_text()) if state_file.exists() else {}
        if now - state.get('last_created_at', 0) < hours * 3600:
            return
        tasks = board_tasks(root, board)
        if any(t.get('tenant') == TENANT and (t.get('title') == OPPORTUNITY_TITLE
               or t.get('created_by') == 'review-taskforce-scheduler')
               and t['status'] not in {'done', 'archived'} for t in tasks):
            return
        board_info = json.loads(board_file.read_text())
        workdir = Path(board_info.get('default_workdir') or '')
        if not workdir.is_absolute() or not workdir.is_dir():
            raise ValueError(f'Board {board} needs an existing absolute default_workdir')
        is_git = subprocess.run(['git', '-C', str(workdir), 'rev-parse', '--git-dir'],
                                capture_output=True).returncode == 0
        body = '\n'.join([
            'Goal: Choose one worthwhile question about an existing, idle feature.',
            'Change: review-taskforce/FINDINGS.md:1 — assess coverage and pending findings.',
            'Verify: python3 ~/.hermes/scripts/review-taskforce.py status — report real exit.',
            'Constraints:',
            '- Follow the Continuous improvement taskforce policy in your SOUL.md.',
            '- Commission at most one focused audit, or close with a reason to do nothing.',
            '- Assess urgency; forward any already-approved worthwhile batch.',
            '- Preserve findings; do not implement or deploy.',
        ])
        # Hermes deduplicates retries even if creation succeeded but our state write failed.
        key = f'taskforce-opportunity:{board}:{now // (hours * 3600)}'
        created = hermes(board, 'create', OPPORTUNITY_TITLE, '--assignee', 'project-auditor',
                         '--tenant', TENANT, '--created-by', 'review-taskforce-scheduler',
                         '--priority', '-10', '--workspace', 'worktree' if is_git else f'dir:{workdir}',
                         '--idempotency-key', key, '--body', body)
        task_id = created['id']
        atomic_write(state_file, json.dumps({'last_created_at': now, 'task_id': task_id}) + '\n')
        print(f'{board}: opportunity check {task_id}')


def scope_conflicts(root, board, paths):
    if not paths or any(Path(p).is_absolute() or '..' in Path(p).parts or p in {'', '.'} for p in paths):
        raise ValueError('Name explicit project-relative paths to audit')
    paths = [Path(p).as_posix() for p in paths]
    own = json.loads((review_dir(root, board).parent / 'board.json').read_text())
    project = own.get('default_workdir')
    conflicts = []
    # Cross-board cards sharing the same checkout are also protected.
    for board_file in sorted((root / 'kanban/boards').glob('*/board.json')):
        other = board_file.parent.name
        if other.startswith('_'):
            continue
        info = json.loads(board_file.read_text())
        if other != board and (not project or info.get('default_workdir') != project):
            continue
        for task in board_tasks(root, other):
            if task['status'] != 'running' or task.get('assignee') not in IMPLEMENTERS:
                continue
            text = task.get('body') or ''
            change = re.search(r'^Change:\s*(.*)$', text, re.M)
            owned = re.findall(r'(?<![\w/])(?:[\w.-]+/)+[\w.*-]*', change.group(1)) if change else []
            # An unscoped running card protects the entire project; do not guess.
            overlaps = not owned or any(a.rstrip('/').startswith(b.rstrip('/') + '/')
                or b.rstrip('/').startswith(a.rstrip('/') + '/') or a.rstrip('/') == b.rstrip('/')
                for a in paths for b in owned)
            if overlaps:
                conflicts.append({'board': other, 'task_id': task['id'], 'assignee': task['assignee']})
    return conflicts


def write_document(root, board, name, content, expected):
    if os.environ.get('HERMES_PROFILE') != 'project-auditor':
        raise PermissionError('Only project-auditor may publish taskforce documents')
    if name != 'FINDINGS.md' and not re.fullmatch(r'plans/[a-zA-Z0-9][a-zA-Z0-9_-]*\.md', name):
        raise ValueError('Use FINDINGS.md or plans/<batch-name>.md')
    if not content.strip():
        raise ValueError('Document must not be empty')
    directory = review_dir(root, board)
    with locked(directory):
        path = directory / name
        if name == 'FINDINGS.md':
            actual = digest(path) if path.exists() else 'missing'
            if not expected or actual != expected:
                raise ValueError('Findings changed; reread and merge before publishing')
        elif path.exists():
            if path.read_text() == content:
                return path
            raise ValueError('Plans are immutable; publish a new revision')
        atomic_write(path, content)
        return path


def board_status(root, board):
    directory = review_dir(root, board)
    config = directory / 'config.json'
    findings = directory / 'FINDINGS.md'
    return {'board': board, 'directory': str(directory),
            'config': json.loads(config.read_text()) if config.exists() else
                      {'cadence': 'off', 'interval_hours': 0},
            'findings_sha256': digest(findings) if findings.exists() else 'missing',
            'tasks': [{key: task.get(key) for key in ('id', 'title', 'status', 'assignee', 'tenant')}
                      for task in board_tasks(root, board) if task['status'] not in {'done', 'archived'}]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--board', default=os.environ.get('HERMES_KANBAN_BOARD'))
    commands = parser.add_subparsers(dest='command', required=True)
    configure_parser = commands.add_parser('configure')
    configure_parser.add_argument('--cadence', choices=[*CADENCES, 'custom'], required=True)
    configure_parser.add_argument('--interval-hours', type=int)
    commands.add_parser('tick')
    commands.add_parser('status')
    scope = commands.add_parser('check-scope')
    scope.add_argument('paths', nargs='+')
    write = commands.add_parser('write')
    write.add_argument('--source', type=Path, required=True)
    write.add_argument('--name', default='FINDINGS.md')
    write.add_argument('--expected-sha256')
    args = parser.parse_args()
    root = Path(os.environ.get('HERMES_ROOT', str(Path.home() / '.hermes')))
    if args.command == 'tick':
        tick(root)
        return 0
    review_dir(root, args.board or '')
    if args.command == 'configure':
        configure(root, args.board, args.cadence, args.interval_hours)
    elif args.command == 'status':
        print(json.dumps(board_status(root, args.board), indent=2))
    elif args.command == 'check-scope':
        conflicts = scope_conflicts(root, args.board, args.paths)
        print(json.dumps({'safe_to_audit': not conflicts, 'conflicts': conflicts}, indent=2))
        return 1 if conflicts else 0
    elif args.command == 'write':
        print(write_document(root, args.board, args.name, args.source.read_text(), args.expected_sha256))
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (ValueError, PermissionError, OSError, RuntimeError, sqlite3.Error, subprocess.SubprocessError) as exc:
        print(f'taskforce: {exc}', file=sys.stderr)
        sys.exit(2)
