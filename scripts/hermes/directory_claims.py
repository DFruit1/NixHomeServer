#!/usr/bin/env python3
"""Filesystem-owned feature directories for Hermes writers.

Python operations glue deliberately shares Hermes' runtime and standard library;
this is a filesystem/tool adapter, not a new backend service or dependency.
"""
import argparse
from contextlib import contextmanager, ExitStack
import fcntl
import json
import os
from pathlib import Path
import shutil
import shlex
import subprocess
import sys
import tempfile
import time
import uuid

ROOT_FILES = '@shared-files'
AGGREGATES = {'modules/Core_Modules', 'modules/Integrations', 'custom_apps/node',
              'custom_apps/rust', 'custom_apps/node/apps', 'custom_apps/rust/apps',
              '.agents/skills', '.agents/vendor'}


def git(root, *args):
    return subprocess.check_output(['git', '-C', str(root), *args], text=True,
                                   stderr=subprocess.PIPE).rstrip('\n')


def overlaps(left, right):
    return left == right or (ROOT_FILES not in (left, right) and
                            (left.startswith(right + '/') or right.startswith(left + '/')))


def changed_paths(root, *, staged=False):
    if staged:
        return [p for p in git(root, 'diff', '--cached', '--name-only', '-z', '--no-renames').split('\0') if p]
    records = iter(git(root, 'status', '--porcelain=v1', '-z', '--untracked-files=all').split('\0'))
    paths = []
    for entry in records:
        if entry:
            paths.append(entry[3:])
            if entry[0] in 'RC' or entry[1] in 'RC':
                paths.append(next(records))
    return paths


def process_start(pid):
    try:
        return Path('/proc/' + str(int(pid)) + '/stat').read_text().rsplit(')', 1)[1].split()[19]
    except FileNotFoundError:
        return None


class Project:
    def __init__(self, workspace):
        try:
            self.root = Path(git(workspace, 'rev-parse', '--show-toplevel')).resolve()
            self.is_git = True
        except subprocess.CalledProcessError:
            self.root = Path(workspace).resolve(strict=True)
            if not self.root.is_dir():
                raise ValueError('Assigned workspace must be an existing directory')
            self.is_git = False
        self.common = (Path(git(self.root, 'rev-parse', '--path-format=absolute', '--git-common-dir')).resolve()
                       if self.is_git else self.root)
        self.directory = self.common / ('directory-claims' if self.is_git else '.directory-claims')

    def scope(self, value):
        if value == ROOT_FILES:
            return value
        path = Path(value)
        if (path.is_absolute() or '..' in path.parts or len(path.parts) < 2
                or path.parts[0] in ('.git', '.directory-claims') or path.as_posix() in AGGREGATES):
            raise ValueError('Claim a feature directory, not a repository or aggregate: ' + value)
        current = self.root
        for part in path.parts:
            current /= part
            if current.is_symlink():
                raise ValueError('Symlink directories cannot be claimed: ' + value)
        if current.exists() and not current.is_dir():
            raise ValueError('Claims cover directories, not individual files: ' + value)
        return path.as_posix()

    @contextmanager
    def transaction(self):
        if self.directory.is_symlink():
            raise ValueError('Claim state directory must not be a symlink')
        self.directory.mkdir(mode=0o700, exist_ok=True)
        with os.fdopen(os.open(self.directory / 'mutex',
                              os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600), 'r+') as mutex:
            fcntl.flock(mutex, fcntl.LOCK_EX)
            path = self.directory / 'state.json'
            if path.is_symlink():
                raise ValueError('Claim state must not be a symlink')
            state = json.loads(path.read_text()) if path.exists() else {
                'version': 1, 'claims': [], 'requests': []}
            if (not isinstance(state, dict) or state.get('version') != 1
                    or not isinstance(state.get('claims'), list)
                    or not isinstance(state.get('requests'), list)):
                raise ValueError('Malformed directory claim state; preserve it for recovery')
            for claim in state['claims']:
                if (not isinstance(claim, dict) or not all(isinstance(claim.get(k), str)
                        and claim[k] for k in ('owner', 'workspace', 'generation'))
                        or not isinstance(claim.get('paths'), list) or not claim['paths']
                        or not all(isinstance(p, str) and self.scope(p) == p for p in claim['paths'])
                        or not all(c in '0123456789abcdef' for c in claim['generation'])
                        or len(claim['generation']) != 32):
                    raise ValueError('Malformed directory ownership record')
            yield state

    def save(self, state):
        # The permanent mutex is never renamed. Replace only the data file.
        path = self.directory / 'state.new'
        fd = os.open(path, os.O_CREAT | os.O_TRUNC | os.O_WRONLY | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, 'w') as stream:
            json.dump(state, stream, sort_keys=True, indent=2)
            stream.write('\n')
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(path, self.directory / 'state.json')
        fd = os.open(self.directory, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)

    def status(self):
        with self.transaction() as state:
            return {**state, 'state_path': str(self.directory / 'state.json')}

    def own(self, state, owner):
        found = [c for c in state['claims'] if c['owner'] == owner]
        if not found or found[0]['workspace'] != str(self.root):
            raise ValueError('This writer has no claim in this checkout')
        return found[0]

    def operation_lock(self, stack, claim):
        path = self.directory / (claim['generation'] + '.lock')
        stream = stack.enter_context(os.fdopen(os.open(path,
            os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600), 'r+'))
        for attempt in range(6):
            try:
                fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if attempt == 5:
                    raise ValueError('Writer still has an operation running; ownership is unchanged') from None
                time.sleep(0.02)  # Allow the sandbox's final reaper to close its descriptor.
        return stream

    def claim(self, owner, paths, *, writer_pid=None):
        if not isinstance(owner, str) or not owner.strip() or len(owner) > 300:
            raise ValueError('Name the writer session')
        paths = sorted(set(self.scope(p) for p in paths))
        if not paths:
            raise ValueError('Name at least one feature directory')
        with ExitStack() as stack:
            state = stack.enter_context(self.transaction())
            same = next((c for c in state['claims'] if c['owner'] == owner), None)
            if self.is_git and any(c['workspace'] == str(self.root) and c['owner'] != owner for c in state['claims']):
                raise ValueError('Each writer needs its own assigned Git worktree')
            if same:
                self.own(state, owner)
                self.operation_lock(stack, same)
                paths = sorted(set(paths + same['paths']))
            conflicts = [c for c in state['claims'] if c['owner'] != owner
                         and any(overlaps(a, b) for a in paths for b in c['paths'])]
            if conflicts:
                raise ValueError('Directory held by ' + ', '.join(c['owner'] for c in conflicts)
                                 + '; request it from the holder or continue disjoint work')
            # Materialise only after all claims pass; the parent remains unowned.
            for path in paths:
                if path != ROOT_FILES:
                    (self.root / path).mkdir(parents=True, exist_ok=True)
            record = same or {'owner': owner, 'workspace': str(self.root),
                             'generation': uuid.uuid4().hex, 'created_at': int(time.time())}
            record['paths'] = paths
            if writer_pid is not None:
                start = process_start(writer_pid)
                if not start:
                    raise ValueError('Writer process must exist when acquiring ownership')
                record.update(writer_pid=writer_pid, writer_start=start)
            if not same:
                state['claims'].append(record)
            self.save(state)
            return record

    def recover(self, owner, generation):
        """A stopped writer's bytes remain in its original durable checkout."""
        with ExitStack() as stack:
            state = stack.enter_context(self.transaction())
            claim = next((c for c in state['claims'] if c['generation'] == generation), None)
            if not claim or not claim.get('writer_pid') or not claim.get('writer_start'):
                raise ValueError('Recovery needs the exact claim generation and recorded writer process')
            if process_start(claim['writer_pid']) == claim['writer_start']:
                raise ValueError('Recorded writer process is still alive; request its holder directly')
            self.operation_lock(stack, claim)
            preserved = Project(claim['workspace'])
            if preserved.common != self.common:
                raise ValueError('Original checkout must remain in this repository for recovery')
            receipt = {**claim, 'recovered_by': owner,
                       'preserved_head': git(preserved.root, 'rev-parse', 'HEAD') if preserved.is_git else None,
                       'preserved_changes': changed_paths(preserved.root) if preserved.is_git else None,
                       'recovered_at': int(time.time())}
            state.setdefault('recoveries', []).append(receipt)
            state['claims'].remove(claim)
            state['requests'] = [r for r in state['requests'] if generation not in r['holders']]
            self.save(state)
            return receipt

    def release(self, owner, paths=()):
        """Release clean, exactly held scopes without abandoning other work."""
        requested = sorted(set(self.scope(p) for p in paths))
        with ExitStack() as stack:
            state = stack.enter_context(self.transaction())
            claim = self.own(state, owner)
            self.operation_lock(stack, claim)
            released = requested or list(claim['paths'])
            if any(path not in claim['paths'] for path in released):
                raise ValueError('Release only exact scopes held by this writer')
            released_claim = {**claim, 'paths': released}
            if self.is_git and any(self.covers(released_claim, p) for p in changed_paths(self.root)):
                raise ValueError('Commit owned source before releasing; unfinished files are preserved')
            remaining = [p for p in claim['paths'] if p not in released]
            if remaining:
                claim['paths'] = remaining
            else:
                state['claims'].remove(claim)
            requests = []
            for request in state['requests']:
                still_blocks = any(overlaps(a, b) for a in remaining for b in request['paths'])
                request['holders'] = [g for g in request['holders']
                                      if g != claim['generation'] or still_blocks]
                if request['holders']:
                    requests.append(request)
            state['requests'] = requests
            self.save(state)
            return {**released_claim, 'remainingPaths': remaining}

    def request(self, owner, paths, reason):
        paths = sorted(set(self.scope(p) for p in paths))
        if not paths or not isinstance(reason, str) or not reason.strip() or len(reason) > 1000:
            raise ValueError('Name the requested directories and a short non-sensitive reason')
        with self.transaction() as state:
            holders = sorted(c['generation'] for c in state['claims'] if c['owner'] != owner
                             and any(overlaps(a, b) for a in paths for b in c['paths']))
            if not holders:
                raise ValueError('No other holder owns those directories; claim them directly')
            record = {'requester': owner, 'paths': paths, 'reason': reason, 'holders': holders}
            if record not in state['requests']:
                state['requests'].append(record)
                self.save(state)
            return record

    @staticmethod
    def covers(claim, relative):
        shared = len(Path(relative).parts) <= 2 or str(Path(relative).parent) in AGGREGATES
        return any((scope == ROOT_FILES and shared)
                   or (scope != ROOT_FILES and relative.startswith(scope + '/'))
                   for scope in claim['paths'])

    def relative_file(self, path):
        path = Path(os.path.abspath(path))
        try:
            relative = path.relative_to(self.root)
        except ValueError:
            raise ValueError('Write target is outside the assigned checkout') from None
        current = self.root
        for part in relative.parts:
            current /= part
            if current.is_symlink() or (current.is_file() and current.stat().st_nlink > 1):
                raise ValueError('Claimed writes cannot traverse symlinks or hardlinks')
        if not relative.parts or relative.parts[0] in ('.git', '.directory-claims'):
            raise ValueError('Git metadata is not a source directory')
        return relative.as_posix()

    @contextmanager
    def writing(self, owner, paths=()):
        with ExitStack() as stack:
            with self.transaction() as state:
                claim = self.own(state, owner)
                stream = self.operation_lock(stack, claim)
                for path in paths:
                    relative = self.relative_file(path)
                    if not self.covers(claim, relative):
                        raise ValueError('Write needs directory ownership: ' + relative)
            yield {**claim, '_operation_fd': stream.fileno()}


def sandbox(project, owner, cwd, command, *, bwrap=None, git_write=False, claim=None, inputs=()):
    """Mount source read-only and keep operation locks alive in the sandbox host.

    The read-only host also covers absolute paths, future worktrees and Git
    metadata. A private PID namespace dies with bubblewrap, including descendants.
    There is deliberately no raw-shell fallback.
    """
    bwrap = bwrap or shutil.which('bwrap')
    if not bwrap:
        raise ValueError('bubblewrap is required for writer terminals; no unsandboxed fallback')
    with ExitStack() as stack:
        if claim is None:
            current = project.status()
            claimed = next((c for c in current['claims'] if c['owner'] == owner), None)
            claim = stack.enter_context(project.writing(owner)) if claimed else None
        scratch = Path(stack.enter_context(tempfile.TemporaryDirectory(prefix='hermes-directory-claims-run-')))
        args = [bwrap, '--ro-bind', '/', '/', '--unshare-pid', '--die-with-parent',
                '--new-session', '--cap-drop', 'ALL', '--proc', '/proc', '--dev', '/dev',
                '--tmpfs', '/tmp']
        # Writable caches are outside source and rebound before source mounts.
        for relative in ('.cache', '.cargo', '.npm', '.local/share/pnpm/store'):
            path = Path.home() / relative
            if path.is_dir() and not path.is_symlink():
                args += ['--bind', str(path), str(path)]
        worktrees = (git(project.root, 'worktree', 'list', '--porcelain', '-z').split('\0')
                     if project.is_git else ['worktree ' + str(project.root)])
        for line in worktrees:
            if line.startswith('worktree '):
                path = line[9:]
                if Path(path).is_dir():
                    args += ['--ro-bind', path, path]
        args += ['--ro-bind', str(project.common), str(project.common)]
        if git_write:
            # Only checked `git add`/`git commit` reach this branch. Arbitrary
            # shells never receive a writable index, refs or configuration.
            args += ['--bind', str(project.common), str(project.common)]
            for entry in worktrees:
                if (entry.startswith('worktree ') and Path(entry[9:]).is_dir()
                        and Path(entry[9:]).is_relative_to(project.common)):
                    args += ['--ro-bind', entry[9:], entry[9:]]
            args += ['--ro-bind', str(project.directory), str(project.directory)]
        if claim:
            for scope in claim['paths']:
                if scope != ROOT_FILES:
                    path = project.root / scope
                    project.scope(scope)  # Recheck aliases under the operation lock.
                    for directory, _, files in os.walk(path, followlinks=False):
                        for name in files:
                            candidate = Path(directory) / name
                            if not candidate.is_symlink() and candidate.stat().st_nlink > 1:
                                raise ValueError('Writable directory contains a shared hardlink: ' + str(candidate))
                    args += ['--bind', str(path), str(path)]
            args += ['--sync-fd', str(claim['_operation_fd'])]
        args += ['--bind', str(scratch), str(scratch), '--setenv', 'TMPDIR', str(scratch),
                 '--setenv', 'GIT_OPTIONAL_LOCKS', '0']
        for path in inputs:
            args += ['--ro-bind', str(path), str(path)]
        args += ['--chdir', str(cwd), '--', *command]
        return subprocess.run(args, pass_fds=((claim['_operation_fd'],) if claim else ())).returncode


def git_mutation(project, owner, command):
    """Keep Git's existing hooks; refuse unrelated staged files and broad options."""
    if not project.is_git or not command or command[0] not in ('add', 'commit'):
        raise ValueError('Only explicit git add and git commit are writer Git mutations')
    with project.writing(owner) as claim:
        staged = changed_paths(project.root, staged=True)
        if any(not project.covers(claim, p) for p in staged):
            raise ValueError('Index includes another scope; preserve it and use an exclusive worktree')
        inputs = []
        if command[0] == 'add':
            paths = command[2:] if command[1:2] == ['--'] else command[1:]
            if not paths or any(p.startswith('-') for p in paths):
                raise ValueError('Stage explicit owned files, without Git option overrides')
            for path in paths:
                absolute = project.root / path
                relative = project.relative_file(absolute)
                if not project.covers(claim, relative) or absolute.is_dir():
                    raise ValueError('Stage explicit files inside your claimed directories')
        else:
            options = command[1:]
            if (not staged or not options or len(options) % 2
                    or any(option not in ('-m', '--message', '-F', '--file') for option in options[::2])):
                raise ValueError('Commit staged owned files with -m MESSAGE or --file PATH; hooks remain enabled')
            for option, value in zip(options[::2], options[1::2]):
                if option in ('-F', '--file'):
                    path = (project.root / value).resolve(strict=True)
                    if not path.is_file():
                        raise ValueError('Commit message input must be a regular file')
                    inputs.append(path)
        # Per-checkout metadata mutex also covers a caller whose previous
        # claims were released. No other index transaction can interleave.
        with os.fdopen(os.open(project.directory / 'git-mutex',
                               os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600), 'r+') as stream:
            fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
            with tempfile.TemporaryDirectory(prefix='hermes-directory-claims-git-') as temporary:
                hooks = Path(temporary) / 'hooks'
                hooks.mkdir()
                original = Path(git(project.root, 'rev-parse', '--path-format=absolute', '--git-path', 'hooks'))
                if original.is_dir():
                    for entry in original.iterdir():
                        if entry.name != 'reference-transaction':
                            (hooks / entry.name).symlink_to(entry)
                guard = hooks / 'reference-transaction'
                guard.write_text(reference_guard(project, claim, original / 'reference-transaction'))
                guard.chmod(0o700)
                index = Path(git(project.root, 'rev-parse', '--path-format=absolute', '--git-path', 'index'))
                before = index.read_bytes() if index.exists() else None
                result = sandbox(project, owner, project.root,
                    ['git', '-C', str(project.root), '-c', 'core.hooksPath=' + str(hooks), *command],
                    git_write=True, claim=claim, inputs=[*inputs, hooks, Path(__file__).resolve()])
                unsafe_index = any(not project.covers(claim, p) for p in changed_paths(project.root, staged=True))
                if result or unsafe_index:
                    if before is not None:
                        fd = os.open(str(index) + '.lock', os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
                        with os.fdopen(fd, 'wb') as output:
                            output.write(before)
                            output.flush()
                            os.fsync(output.fileno())
                        os.replace(str(index) + '.lock', index)
                    if unsafe_index and not result:
                        print('Directory claims: restored staging changed by a hook outside the owned scope.', file=sys.stderr)
                return result


def reference_guard(project, claim, original):
    """Chain the real hook, then check the actual commit before Git publishes it."""
    return f'''#!{sys.executable}
import os, runpy, subprocess, sys
data = sys.stdin.buffer.read()
original = {str(original)!r}
if os.path.isfile(original) and os.access(original, os.X_OK):
    result = subprocess.run([original, *sys.argv[1:]], input=data).returncode
    if result:
        sys.exit(result)
if sys.argv[1:] == ['prepared']:
    covers = runpy.run_path({str(Path(__file__).resolve())!r})['Project'].covers
    claim = {{'paths': {claim['paths']!r}}}
    for record in data.decode().splitlines():
        old, new, ref = record.split()
        if set(new) == {{'0'}}:
            if ref == 'AUTO_MERGE':
                continue  # Git clears this per-worktree pseudoref after commit.
            sys.exit('Directory claims: commit cannot delete references')
        paths = subprocess.check_output(['git', 'diff-tree', '--no-commit-id', '--no-renames',
            '--name-only', '-r', '-z', old, new], text=True).split('\\0')
        if any(path and not covers(claim, path) for path in paths):
            sys.exit('Directory claims: hook would publish a commit outside the owned scope')
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo', type=Path, default=Path.cwd())
    parser.add_argument('--owner', default=os.environ.get('HERMES_DIRECTORY_CLAIM_OWNER'))
    parser.add_argument('--writer-pid', type=int)
    sub = parser.add_subparsers(dest='command', required=True)
    for name in ('claim', 'request'):
        command = sub.add_parser(name)
        command.add_argument('paths', nargs='+')
        if name == 'request':
            command.add_argument('--reason', required=True)
    sub.add_parser('list')
    release = sub.add_parser('release')
    release.add_argument('paths', nargs='*', help='Exact held scopes; omit to release all')
    recover = sub.add_parser('recover')
    recover.add_argument('generation')
    run = sub.add_parser('run')
    run.add_argument('--cwd', type=Path, required=True)
    run.add_argument('argv', nargs=argparse.REMAINDER)
    git_command = sub.add_parser('git')
    git_command.add_argument('argv', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    project = Project(args.repo)
    if args.command == 'list':
        result = project.status()
    else:
        if not args.owner:
            parser.error('Provide --owner outside a runtime-bound writer session')
        if args.command == 'claim':
            result = project.claim(args.owner, args.paths, writer_pid=args.writer_pid)
        elif args.command == 'request':
            result = project.request(args.owner, args.paths, args.reason)
        elif args.command == 'release':
            result = project.release(args.owner, args.paths)
        elif args.command == 'recover':
            result = project.recover(args.owner, args.generation)
        elif args.command == 'run':
            command = args.argv[1:] if args.argv[:1] == ['--'] else args.argv
            if not command:
                parser.error('run requires a command after --')
            return sandbox(project, args.owner, args.cwd, command)
        else:
            return git_mutation(project, args.owner, args.argv)
    print(json.dumps(result, indent=2))
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (ValueError, OSError, subprocess.SubprocessError) as exc:
        print('directory claims: ' + str(exc), file=sys.stderr)
        sys.exit(2)
