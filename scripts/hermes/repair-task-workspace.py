#!/usr/bin/env python3
"""Prepare one parked task's recorded checkout without discarding prior work.

Python operations glue uses the existing native Hermes CLI and Git worktree
operations; it introduces no backend, dependency or board-state writer. A
source receipt never implies verified input transfer, acceptance or unblock.
"""
import argparse
from contextlib import contextmanager, nullcontext
import fcntl
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time
import uuid

sys.dont_write_bytecode = True
PARKED = {'blocked', 'scheduled'}
IDENTITY_FIELDS = ('id', 'status', 'workspace_kind', 'workspace_path', 'branch_name')
HASH = re.compile(r'(?:[0-9a-f]{40}|[0-9a-f]{64})')


class Refused(Exception):
    pass


class PartialRepair(Refused):
    def __init__(self, receipt, reason):
        self.receipt = {**receipt, 'status': 'partial', 'reason': str(reason)[:400]}
        super().__init__(str(reason))


class Runner:
    def __init__(self):
        self.deadline = time.monotonic() + 180

    def call(self, argv, *, env=None):
        remaining = self.deadline - time.monotonic()
        if remaining <= 0:
            raise Refused('REPAIR_DEADLINE 180 seconds')
        result = subprocess.run(argv, text=True, capture_output=True, stdin=subprocess.DEVNULL,
                                timeout=min(30, remaining), env=env)
        if result.returncode:
            raise Refused('COMMAND_FAILED ' + str(argv[0]) + ': ' + result.stderr.strip()[:300])
        return result.stdout


class NativeBoards:
    def __init__(self, runner):
        self.runner = runner
        self.binary = os.environ.get('HERMES_BIN', 'hermes')

    def read(self, args):
        return json.loads(self.runner.call([self.binary, 'kanban', *args]))

    def inventory(self):
        boards = self.read(['boards', 'list', '--json', '--all'])
        if not isinstance(boards, list) or len(boards) > 64:
            raise Refused('BOARD_INVENTORY_UNBOUNDED')
        tasks = []
        for board in boards:
            if not isinstance(board, dict):
                raise Refused('BOARD_ID_INVALID')
            slug = board.get('slug')
            if not isinstance(slug, str) or not re.fullmatch(r'[A-Za-z0-9_-]+', slug):
                raise Refused('BOARD_ID_INVALID')
            rows = self.read(['--board', slug, 'list', '--archived', '--json'])
            if not isinstance(rows, list) or len(rows) > 20000:
                raise Refused('TASK_INVENTORY_UNBOUNDED ' + slug)
            if any(not isinstance(task, dict) or not isinstance(task.get('id'), str)
                   or 'workspace_path' not in task or 'status' not in task for task in rows):
                raise Refused('NATIVE_TASK_INVENTORY_SCHEMA ' + slug)
            tasks.extend((slug, task) for task in rows)
        return tasks

    def details(self, board, task_id):
        return self.read(['--board', board, 'show', task_id, '--json'])


def git(path, *args, runner=None):
    env = dict(os.environ, GIT_CEILING_DIRECTORIES=str(Path(path).parent),
               GIT_TERMINAL_PROMPT='0')
    return (runner or Runner()).call(['git', '-C', str(path), *args], env=env).strip()


def exact_root(path, runner=None):
    """Require this directory's own Git root, never an enclosing repository."""
    if not Path(path).is_dir():
        return None
    try:
        root = git(path, 'rev-parse', '--show-toplevel', runner=runner)
    except Refused:
        return None
    return Path(root).resolve() if Path(root).resolve() == Path(path).resolve() else None


def common_dir(path, runner):
    directory = Path(git(path, 'rev-parse', '--git-common-dir', runner=runner))
    return (directory if directory.is_absolute() else path/directory).resolve()


@contextmanager
def repair_lock(repo, runner):
    with open(common_dir(repo, runner)/'hermes-workspace-repair.lock', 'a', encoding='utf-8') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise Refused('WORKSPACE_REPAIR_BUSY')
        yield


def binding(native, board, task_id, target):
    matches = []
    for slug, task in native.inventory():
        path = task.get('workspace_path')
        if slug == board and task.get('id') == task_id:
            matches.append(task)
            continue
        if path:
            alias = Path(path).expanduser().resolve()
            if alias == target or target in alias.parents:
                raise Refused('SHARED_WORKSPACE ' + slug + '/' + str(task.get('id')))
    if len(matches) != 1:
        raise Refused('TASK_NOT_UNIQUE ' + board + '/' + task_id)
    details = native.details(board, task_id)
    if not isinstance(details, dict):
        raise Refused('NATIVE_TASK_SCHEMA_INVALID')
    task = details.get('task')
    if not isinstance(task, dict) or any(task.get(k) != matches[0].get(k) for k in IDENTITY_FIELDS):
        raise Refused('TASK_BINDING_CHANGED')
    if task.get('status') not in PARKED:
        raise Refused('OWNER_NOT_PARKED ' + str(task.get('status')))
    runs = details.get('runs', [])
    if not isinstance(runs, list) or any(not isinstance(run, dict) or type(run.get('id')) is not int for run in runs):
        raise Refused('RUN_INVENTORY_UNKNOWN')
    if any(run.get('status') == 'running' for run in runs):
        raise Refused('OWNER_RUN_ACTIVE')
    if runs and max(runs, key=lambda run: run['id']).get('worker_pid'):
        raise Refused('OWNER_PROCESS_NOT_CLEARED')
    return {**{key: task.get(key) for key in IDENTITY_FIELDS},
            'latest_run_id': max((run['id'] for run in runs), default=None)}


def registered_paths(repo, runner):
    rows = git(repo, 'worktree', 'list', '--porcelain', '-z', runner=runner)
    return {Path(field.removeprefix('worktree ')).resolve()
            for field in rows.split('\0') if field.startswith('worktree ')}


def preserve_workspace(repo, target, preserved, runner):
    if exact_root(target, runner):
        git(repo, 'worktree', 'move', str(target), str(preserved), runner=runner)
    else:
        target.rename(preserved)


def create_workspace(repo, target, revision, runner):
    git(repo, 'worktree', 'add', '--detach', str(target), revision, runner=runner)


def repair_workspace(repo, board, task_id, revision, tree, native, *, apply=False):
    for variable in ('GIT_DIR', 'GIT_WORK_TREE', 'GIT_COMMON_DIR', 'GIT_INDEX_FILE',
                     'GIT_OBJECT_DIRECTORY', 'GIT_ALTERNATE_OBJECT_DIRECTORIES'):
        if os.environ.get(variable):
            raise Refused('GIT_CONTEXT_OVERRIDE ' + variable)
    role = os.environ.get('HERMES_PROFILE_NAME') or os.environ.get('HERMES_PROFILE')
    if apply and (role or os.environ.get('HERMES_KANBAN_TASK')) and role != 'head-coordinator':
        raise Refused('COORDINATOR_REPAIR_REQUIRED; preserve current worker pins and tool fences')
    if not HASH.fullmatch(revision) or not HASH.fullmatch(tree):
        raise Refused('FULL_SOURCE_IDENTITY_REQUIRED')
    if not re.fullmatch(r'[A-Za-z0-9_-]+', board) or not re.fullmatch(r't_[A-Za-z0-9_]+', task_id):
        raise Refused('TASK_IDENTITY_INVALID')
    runner = Runner()
    repo = Path(repo).absolute()
    if exact_root(repo, runner) != repo.resolve():
        raise Refused('REPOSITORY_ROOT_REQUIRED')
    repo = repo.resolve()
    if git(repo, 'rev-parse', '--verify', revision+'^{commit}', runner=runner) != revision \
            or git(repo, 'rev-parse', revision+'^{tree}', runner=runner) != tree:
        raise Refused('APPROVED_SOURCE_MISMATCH')
    details = native.details(board, task_id)
    if not isinstance(details, dict) or not isinstance(details.get('task'), dict):
        raise Refused('NATIVE_TASK_SCHEMA_INVALID')
    task = details['task']
    raw_path = task.get('workspace_path')
    if not isinstance(raw_path, str) or not Path(raw_path).is_absolute():
        raise Refused('ABSOLUTE_RECORDED_PATH_REQUIRED')
    target = Path(raw_path)
    if target != target.resolve() or target == repo/'.worktrees' or repo/'.worktrees' not in target.parents:
        raise Refused('EXCLUSIVE_WORKTREE_PATH_REQUIRED')
    if task.get('workspace_kind') not in {'dir', 'worktree'}:
        raise Refused('PREPARED_WORKSPACE_KIND_REQUIRED')
    # Native worktree resolution redirects noncanonical detached paths to the
    # task's own branch. Static dir bindings and canonical worktree paths are
    # honored without altering native board rows or branch ownership.
    if task['workspace_kind'] == 'worktree' and target != repo/'.worktrees'/task_id:
        raise Refused('NONCANONICAL_WORKTREE_BINDING; native prepared-dir assignment required')
    receipt = {'schema_version': 1, 'board': board, 'task_id': task_id, 'workspace': str(target),
               'revision': revision, 'tree': tree, 'preserved_path': None,
               'inputs_verified': False, 'unblocked': False}
    with repair_lock(repo, runner) if apply else nullcontext():
        identity = binding(native, board, task_id, target)
        receipt['owner_run_id'] = identity['latest_run_id']
        if any(identity.get(key) != task.get(key) for key in IDENTITY_FIELDS):
            raise Refused('TASK_BINDING_CHANGED')
        if target.exists() and not target.is_dir():
            raise Refused('WORKSPACE_NOT_DIRECTORY')
        root = exact_root(target, runner)
        registered = registered_paths(repo, runner)
        if root:
            if common_dir(target, runner) != common_dir(repo, runner) or target not in registered:
                raise Refused('FOREIGN_REPOSITORY')
            head = git(target, 'rev-parse', 'HEAD', runner=runner)
            source_tree = git(target, 'rev-parse', 'HEAD^{tree}', runner=runner)
            clean = not git(target, 'status', '--porcelain', '--untracked-files=no', runner=runner)
            if head == revision and source_tree == tree and clean:
                return {**receipt, 'status': 'already_prepared'}
            receipt.update(previous_revision=head, previous_tree=source_tree)
        elif os.path.lexists(target/'.git'):
            raise Refused('BROKEN_GIT_METADATA; preserve and qualify native metadata repair')
        if target in registered and not root:
            raise Refused('STALE_WORKTREE_REGISTRATION; qualify exact native metadata repair')
        if any(target in path.parents for path in registered):
            raise Refused('NESTED_WORKTREE_OWNER')
        if not apply:
            return {**receipt, 'status': 'repair_needed'}
        if binding(native, board, task_id, target) != identity:
            raise Refused('TASK_BINDING_CHANGED')
        try:
            if target.exists():
                preserved = target.with_name(target.name+'.preserved-'+uuid.uuid4().hex)
                if preserved.exists():
                    raise Refused('PRESERVATION_PATH_OCCUPIED')
                preserve_workspace(repo, target, preserved, runner)
                receipt['preserved_path'] = str(preserved)
            if binding(native, board, task_id, target) != identity:
                raise Refused('TASK_BINDING_CHANGED')
            create_workspace(repo, target, revision, runner)
            if exact_root(target, runner) != target or git(target, 'rev-parse', 'HEAD', runner=runner) != revision \
                    or git(target, 'rev-parse', 'HEAD^{tree}', runner=runner) != tree \
                    or git(target, 'status', '--porcelain', runner=runner):
                raise Refused('PREPARED_SOURCE_READBACK_FAILED')
            if binding(native, board, task_id, target) != identity:
                raise Refused('TASK_BINDING_CHANGED_AFTER_PREPARATION')
        except (Refused, OSError, ValueError, subprocess.SubprocessError) as exc:
            raise PartialRepair(receipt, exc) from exc
        return {**receipt, 'status': 'prepared'}


def main():
    parser = argparse.ArgumentParser(description=__doc__, allow_abbrev=False)
    parser.add_argument('--repo', required=True)
    parser.add_argument('--board', required=True)
    parser.add_argument('--task', required=True)
    parser.add_argument('--revision', required=True)
    parser.add_argument('--tree', required=True)
    parser.add_argument('--apply', action='store_true', help='prepare source; never unblock or accept')
    args = parser.parse_args()
    try:
        result = repair_workspace(args.repo, args.board, args.task, args.revision, args.tree,
                                  NativeBoards(Runner()), apply=args.apply)
        print(json.dumps(result, sort_keys=True))
        return 0
    except PartialRepair as exc:
        print(json.dumps(exc.receipt, sort_keys=True))
        return 3
    except (Refused, OSError, ValueError, subprocess.SubprocessError) as exc:
        print(json.dumps({'status': 'refused', 'reason': str(exc)[:400]}, sort_keys=True))
        return 2


if __name__ == '__main__':
    sys.exit(main())
