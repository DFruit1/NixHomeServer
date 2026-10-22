#!/usr/bin/env python3
"""Read-only preflight: delegated workspaces must carry full history their gate can read.

Fleet evidence (parent t_73c1155c). An owner-alert candidate (pcops t_6e3059e2)
stalled unmerged because its worktree was a SHALLOW clone: the boundary object
its gate needed was missing, so the flake fetch failed. Its gate then hit a
PermissionError outside its owned paths. Slice 1 removes that mechanical cause,
so before a workspace is handed to a worker it must be checked for both.

This helper only DETECTS. It is read-only: it never unshallows, fetches, repairs
or writes a repository, and it never writes a board database. For every
offending workspace it prints the reason and the exact remediation, then exits 1.

Candidates are the workspaces the fleet actually hands to a worker:
  * every board card's recorded workspace_path (a `worktree` card, or any
    recorded path that is itself a git worktree), and
  * every direct directory entry under <repo>/.worktrees/.

A candidate fails when any of these hold:
  * ``git rev-parse --is-shallow-repository`` reports true (no boundary history);
  * its git metadata is unreadable (git cannot resolve it as a worktree root);
  * an ancestor directory denies the worker search (no execute bit).

Usage:
    python3 scripts/hermes/kanban-workspace-preflight.py
    python3 scripts/hermes/kanban-workspace-preflight.py --repo <checkout> \
        --hermes-root <home> [--json]

HERMES_ROOT selects an isolated installation (default ~/.hermes). The exit code
is 0 when every delegated workspace is complete and readable, 1 when any hazard
is found, 2 on a usage or tooling error.
"""
import argparse
import json
import os
import shutil
import sqlite3
import subprocess
from contextlib import closing
from pathlib import Path


def _git_env(path):
    """Environment for a read-only git probe that must not leave the workspace."""
    env = dict(os.environ)
    env['LC_ALL'] = 'C'
    env['GIT_OPTIONAL_LOCKS'] = '0'
    env['GIT_TERMINAL_PROMPT'] = '0'
    # A worktree whose metadata is broken must not be rescued by discovering an
    # enclosing repository above it; the preflight judges the workspace itself.
    env['GIT_CEILING_DIRECTORIES'] = str(Path(path).parent)
    return env


def _git(path, *args):
    proc = subprocess.run(['git', '-C', str(path), *args], capture_output=True,
                          text=True, env=_git_env(path), timeout=60)
    return proc.returncode, proc.stdout, proc.stderr


def git_toplevel(path):
    """Resolved worktree root git reports for path, or None when unreadable."""
    code, out, _ = _git(path, 'rev-parse', '--show-toplevel')
    if code != 0 or not out.strip():
        return None
    return os.path.realpath(out.strip())


def is_worktree_root(path):
    top = git_toplevel(path)
    return top is not None and top == os.path.realpath(path)


def is_shallow(path):
    code, out, _ = _git(path, 'rev-parse', '--is-shallow-repository')
    return code == 0 and out.strip().lower() == 'true'


def main_worktree(path):
    """The repository's primary worktree, the one `fetch --unshallow` runs in.

    A linked worktree cannot be unshallowed directly, so the remediation names
    the main worktree git itself reports.
    """
    code, out, _ = _git(path, 'worktree', 'list', '--porcelain')
    if code == 0:
        for line in out.splitlines():
            if line.startswith('worktree '):
                return line[len('worktree '):].strip()
    return str(path)


def denied_ancestor(path):
    """First ancestor of path (excluding path) the worker cannot search, or None.

    Lexical, so a workspace known by exact card path is still judged even while
    an ancestor denies the traversal the rest of the checks would need.
    """
    absolute = os.path.abspath(path)
    ancestors = []
    current = absolute
    while True:
        current = os.path.dirname(current)
        if not current or current == os.path.dirname(current):
            break
        ancestors.append(current)
    for ancestor in reversed(ancestors):  # shallowest first: report the true wall
        if os.path.isdir(ancestor) and not os.access(ancestor, os.X_OK):
            return ancestor
    return None


def inspect(path):
    """Every hazard for one delegated workspace path, as report entries."""
    failures = []
    denied = denied_ancestor(path)
    if denied is not None:
        failures.append({'workspace': str(path), 'reason': 'unsearchable_ancestor',
                         'ancestor': denied, 'remediation': f'chmod u+x {denied}'})
    if not os.path.isdir(path):
        # Absent or unreachable: the git probes below need the tree. A missing
        # workspace is not a shallow or unreadable one, so it is not reported.
        return failures
    if not is_worktree_root(path):
        failures.append({'workspace': str(path), 'reason': 'unreadable_git_metadata',
                         'remediation': f'chmod -R u+rwX {path}'})
        return failures
    if is_shallow(path):
        repo = main_worktree(path)
        failures.append({'workspace': str(path), 'reason': 'shallow_history',
                         'repo': repo, 'remediation': f'git -C {repo} fetch --unshallow'})
    return failures


def _candidate_key(path):
    try:
        return os.path.realpath(path)
    except OSError:  # pragma: no cover - realpath does not raise on this platform
        return os.path.abspath(path)


def _add(candidates, path, source):
    key = _candidate_key(path)
    entry = candidates.setdefault(key, {'path': str(path), 'sources': []})
    if source not in entry['sources']:
        entry['sources'].append(source)


def board_candidates(candidates, hermes_root, warnings):
    """Add the worktree workspaces recorded on every board to candidates."""
    boards = sorted((Path(hermes_root) / 'kanban' / 'boards').glob('*/kanban.db'))
    for db_path in boards:
        slug = db_path.parent.name
        if slug.startswith(('_', '.')):
            continue
        rows = []
        try:
            uri = db_path.resolve().as_uri() + '?mode=ro'
            with closing(sqlite3.connect(uri, uri=True, timeout=5)) as db:
                db.execute('PRAGMA query_only=ON')
                rows = db.execute('SELECT workspace_kind, workspace_path FROM tasks').fetchall()
        except (sqlite3.Error, OSError):
            warnings.append({'board': slug, 'reason': 'unreadable_board_database'})
            continue
        for kind, path in rows:
            if not path:
                continue
            # Only git-check workspaces meant to be git: a `worktree` card, or a
            # recorded path that is itself a git worktree. Plain `dir`/`scratch`
            # workspaces such as /tmp or a non-repo checkout are not worktrees.
            if kind == 'worktree' or os.path.lexists(os.path.join(path, '.git')):
                _add(candidates, path, f'board:{slug}')


def worktree_candidates(candidates, repo, warnings):
    """Add every direct directory entry under <repo>/.worktrees/ to candidates."""
    fleet = Path(repo) / '.worktrees'
    try:
        if not fleet.is_dir():
            return
        entries = sorted(fleet.iterdir(), key=lambda p: p.name)
    except OSError:
        warnings.append({'repo': str(repo), 'reason': 'unreadable_worktrees_directory'})
        return
    for entry in entries:
        if entry.name.startswith('.'):
            continue
        try:
            if not entry.is_dir():
                continue
        except OSError:
            continue
        _add(candidates, str(entry), f'worktrees:{repo}')


def preflight(hermes_root, repo):
    """Read-only scan of every delegated workspace under one installation."""
    warnings = []
    candidates = {}
    board_candidates(candidates, hermes_root, warnings)
    worktree_candidates(candidates, repo, warnings)
    failures = []
    for key in sorted(candidates):
        entry = candidates[key]
        for failure in inspect(entry['path']):
            failure['sources'] = list(entry['sources'])
            failures.append(failure)
    return {'schema_version': 1, 'hermes_root': str(hermes_root), 'repo': str(repo),
            'workspaces': [candidates[k]['path'] for k in sorted(candidates)],
            'failures': failures, 'warnings': warnings}


def render(data):
    lines = ['DELEGATED WORKSPACE PREFLIGHT (read-only; nothing is repaired)',
             f"scanned {len(data['workspaces'])} workspace(s) across "
             f"{data['hermes_root']}/kanban/boards and {data['repo']}/.worktrees"]
    failures = data['failures']
    if failures:
        lines.append('')
        for failure in failures:
            sources = ', '.join(failure['sources']) or 'unknown'
            lines.append(f"❌ {failure['reason']} {failure['workspace']} [{sources}]")
            lines.append(f"   fix: {failure['remediation']}")
        lines.append('')
        lines.append(f"{len(failures)} delegated workspace hazard(s); fix the rows above.")
    else:
        lines.append('')
        lines.append(f"✅ {len(data['workspaces'])} delegated workspace(s) carry full, "
                     'readable history.')
    if data['warnings']:
        lines.append(f"Coverage warnings: {len(data['warnings'])}; inspect --json.")
    return '\n'.join(lines)


def default_repo():
    """Primary worktree of the checkout this is invoked from."""
    proc = subprocess.run(['git', '-C', os.getcwd(), 'worktree', 'list', '--porcelain'],
                          capture_output=True, text=True, timeout=60)
    if proc.returncode == 0:
        for line in proc.stdout.splitlines():
            if line.startswith('worktree '):
                return Path(line[len('worktree '):].strip())
    return Path(os.getcwd())


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--repo',
                        help='checkout whose .worktrees/ fleet is scanned '
                             '(default: the primary worktree of the current repository)')
    parser.add_argument('--hermes-root',
                        help='installation holding kanban/boards '
                             '(default: $HERMES_ROOT or ~/.hermes)')
    parser.add_argument('--json', action='store_true')
    args = parser.parse_args(argv)
    if not shutil.which('git'):
        parser.error('git is required')
    hermes_root = Path(args.hermes_root or os.environ.get('HERMES_ROOT',
                                                          str(Path.home() / '.hermes')))
    repo = Path(args.repo).resolve() if args.repo else default_repo()
    data = preflight(hermes_root, repo)
    if args.json:
        print(json.dumps(data, sort_keys=True))
    else:
        print(render(data))
    return 1 if data['failures'] else 0


if __name__ == '__main__':
    raise SystemExit(main())
