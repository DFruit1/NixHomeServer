#!/usr/bin/env python3
"""Install approved Hermes autonomy helpers without changing models or credentials."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

from autonomy_runtime_adapter import adapt, EDITS
from hermes_common import atomic_write, backup_file
from worker_origin import authenticated_current_origin

SOURCE = Path(__file__).resolve().parent


FIXTURE_SOURCE = 'scripts/hermes/fixture-runner.py'


def _native_review(board, task_id, *, root=None):
    root = Path(root) if root is not None else Path(os.environ.get('HERMES_ROOT', str(Path.home()/'.hermes')))
    native = (root/'hermes-agent').resolve()
    python = native/'.venv/bin/python'
    if not python.is_file():
        raise ValueError('Installed native Hermes interpreter is unavailable')
    # Neither PATH/HERMES_BIN nor Python path injection may fabricate review
    # evidence. Hermes identity variables stay unchanged for the native reader.
    bootstrap = """import importlib.util, pathlib, runpy, sys
native = pathlib.Path(sys.argv.pop(1)).resolve()
spec = importlib.util.find_spec('hermes_cli.main')
if spec is None or pathlib.Path(spec.origin).resolve() != native/'hermes_cli/main.py':
    raise SystemExit('Native Hermes module does not match the installed checkout')
runpy.run_module('hermes_cli.main', run_name='__main__', alter_sys=True)
"""
    result = subprocess.run([str(python), '-I', '-B', '-c', bootstrap, str(native),
                             'kanban', '--board', board, 'show', task_id, '--json'],
                            stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=30)
    if result.returncode:
        raise ValueError('Native installation review is unavailable: ' + result.stderr.strip()[:200])
    return json.loads(result.stdout)


def _source_git(repo, *args):
    result = subprocess.run(['git', '-C', str(repo), *args], stdin=subprocess.DEVNULL,
                            capture_output=True, timeout=30)
    if result.returncode:
        raise ValueError('Committed installation source could not be read')
    return result.stdout


def _reviewed_fixture_source(root, review_card):
    actor = authenticated_current_origin(root, expected_profile='head-coordinator')
    if (not isinstance(actor, dict) or actor.get('profile') != 'head-coordinator'
            or not isinstance(actor.get('board'), str)
            or not re.fullmatch(r'[A-Za-z0-9_-]+', actor['board'])
            or not isinstance(actor.get('task_id'), str)
            or not re.fullmatch(r't_[A-Za-z0-9_]+', actor['task_id'])
            or type(actor.get('run_id')) is not int):
        raise ValueError('Authenticated native coordinator origin is required')
    if not re.fullmatch(r't_[A-Za-z0-9_]+', review_card) or review_card == actor['task_id']:
        raise ValueError('Name an independent installation review card')
    repo = SOURCE.resolve().parents[1]
    if Path(_source_git(repo, 'rev-parse', '--show-toplevel').decode().strip()).resolve() != repo:
        raise ValueError('Installation source must be an exact repository checkout')
    if _source_git(repo, 'status', '--porcelain', '--untracked-files=all'):
        raise ValueError('Installation source must be clean and committed')
    revision = _source_git(repo, 'rev-parse', 'HEAD').decode().strip()
    if not re.fullmatch(r'[0-9a-f]{40}|[0-9a-f]{64}', revision):
        raise ValueError('Installation source needs a full committed revision')
    reviewed = _native_review(actor['board'], review_card, root=root)
    task = reviewed.get('task') if isinstance(reviewed, dict) else None
    runs = reviewed.get('runs') if isinstance(reviewed, dict) else None
    if (not isinstance(task, dict) or task.get('id') != review_card or task.get('status') != 'done'
            or task.get('assignee') not in {'feature-reviewer', 'project-auditor'}
            or not isinstance(runs, list) or not runs
            or any(not isinstance(run, dict) or type(run.get('id')) is not int for run in runs)):
        raise ValueError('A completed independent installation review is required')
    latest = max(runs, key=lambda run: run['id'])
    profile = latest.get('profile')
    metadata = latest.get('metadata')
    if (profile != task['assignee'] or latest.get('status') != 'done'
            or latest.get('outcome') != 'completed' or not isinstance(metadata, dict)
            or metadata.get('verdict') != 'accept' or metadata.get('revision') != revision
            or metadata.get('installation_scope') != [FIXTURE_SOURCE]):
        raise ValueError('Latest installation acceptance must bind only the exact fixture helper source')
    checks = metadata.get('checks')
    if (not isinstance(checks, list) or not checks
            or any(not isinstance(check, dict) or not isinstance(check.get('command'), str)
                   or not check['command'].strip() or type(check.get('exit_code')) is not int
                   or check['exit_code'] != 0 for check in checks)):
        raise ValueError('Installation acceptance needs successful executed checks with integer exits')
    if profile == 'project-auditor':
        independence = metadata.get('independence')
        if (not isinstance(independence, dict) or set(independence) != {'plan_author', 'implementer'}
                or independence['plan_author'] is not False or independence['implementer'] is not False):
            raise ValueError('Auditor installation acceptance requires explicit independence')
    content = _source_git(repo, 'show', 'HEAD:' + FIXTURE_SOURCE)
    source = repo/FIXTURE_SOURCE
    if source.is_symlink() or source.read_bytes() != content \
            or _source_git(repo, 'rev-parse', 'HEAD').decode().strip() != revision \
            or _source_git(repo, 'status', '--porcelain', '--untracked-files=all'):
        raise ValueError('Reviewed installation source changed')
    # Consume committed bytes rather than rereading a mutable working file.
    return content


def _fixture_state(path, root):
    path = Path(path)
    if path.parent.is_symlink() or path.parent.parent.is_symlink():
        raise ValueError('Refusing symlink install target')
    if path.is_symlink():
        raise ValueError('Refusing symlink install target')
    if not path.exists():
        return None
    if not path.is_file():
        raise ValueError('Refusing non-file install target')
    stat = path.stat()
    return (stat.st_dev, stat.st_ino, stat.st_mode & 0o777, path.read_bytes())


def _fixture_backup_mode(root, backup, mode):
    if backup is not None:
        atomic_write(Path(str(backup) + '.mode'), f'{mode:04o}\n', mode=0o600)


def _fixture_atomic_replace(path, content, state, root):
    path = Path(path)
    if _fixture_state(path, root) != state:
        raise ValueError('Install target changed before replacement')
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(dir=str(path.parent), prefix=f'.{path.name}.')
    os.close(fd)
    try:
        atomic_write(Path(temporary), content.decode(), mode=state[2] if state else 0o600)
        if _fixture_state(path, root) != state:
            raise ValueError('Install target changed before replacement')
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def install(root, check=False, fixture_runner_only=False, review_card=None):
    root = Path(root)
    if review_card is not None and not fixture_runner_only:
        raise ValueError('Reviewed bot installation is limited to --fixture-runner-only')
    reviewed_content = (_reviewed_fixture_source(root, review_card)
                        if review_card is not None and not check else None)
    if fixture_runner_only:
        if root.is_symlink():
            raise ValueError('Refusing symlink install root')
        pending = {root / 'scripts/fixture-runner.py': reviewed_content if reviewed_content is not None
                   else (SOURCE / 'fixture-runner.py').read_bytes()}
    else:
        native = root / 'hermes-agent'
        # Install the safe dependency before adding its import sites, including on retry.
        pending = {native / 'hermes_cli/nixhomeserver_autonomy.py': (SOURCE / 'autonomy_runtime.py').read_text()}
        pending.update({native / name: adapt(name, (native / name).read_text()) for name in EDITS})
        for name in ('autonomy-policy.py', 'fixture-runner.py', 'hermes_common.py'):
            pending[root / 'scripts' / name] = (SOURCE / name).read_text()
        pending[root / 'scripts/hermes-autonomy.md'] = (SOURCE.parents[1] / 'documentation/hermes-autonomy.md').read_text()
    changes = []
    for path, content in pending.items():
        if fixture_runner_only:
            state = _fixture_state(path, root)
            old = state[3] if state else None
            new = content
        else:
            if path.is_symlink():
                raise ValueError('Refusing symlink install target')
            old = path.read_text() if path.exists() else None
            new = content
            state = None
        if old != new:
            changes.append((path, old, new, state))
    for path, old, content, state in changes:
        print(f'{"drift" if check else "install"}: {path.relative_to(root)}')
        if check:
            continue
        if fixture_runner_only:
            if _fixture_state(path, root) != state:
                raise ValueError('Install target changed during preflight')
            backup = backup_file(root, 'autonomy-policy', path) if old is not None else None
            if backup is not None:
                _fixture_backup_mode(root, backup, state[2])
            if _fixture_state(path, root) != state:
                raise ValueError('Install target changed after backup')
            _fixture_atomic_replace(path, content, state, root)
            installed = _fixture_state(path, root)
            expected_mode = state[2] if state else 0o600
            if installed is None or installed[2] != expected_mode or installed[3] != content:
                raise ValueError('Installed helper failed postcondition')
        else:
            if old is not None:
                if path.read_text() != old:
                    raise ValueError('Install target changed during preflight')
                backup_file(root, 'autonomy-policy', path)
            atomic_write(path, content)
    return int(check and bool(changes))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    parser.add_argument('--fixture-runner-only', action='store_true')
    parser.add_argument('--review-card', metavar='TASK',
                        help='authenticated coordinator: accepted exact source-only installation review')
    args = parser.parse_args()
    if args.review_card is not None and not args.fixture_runner_only:
        parser.error('--review-card requires --fixture-runner-only')
    if not args.check and args.review_card is None and any(os.environ.get(k) for k in (
            'HERMES_KANBAN_TASK', 'HERMES_DELEGATED_CHILD_CONTEXT', 'HERMES_KANBAN_RUN_ID')):
        parser.error('Autonomy installation requires the interactive operator')
    try:
        sys.exit(install(Path(os.environ.get('HERMES_ROOT', str(Path.home() / '.hermes'))),
                         args.check, args.fixture_runner_only, args.review_card))
    except (ValueError, OSError, subprocess.SubprocessError) as exc:
        print(f'Autonomy installation refused: {exc}', file=sys.stderr)
        sys.exit(2)
