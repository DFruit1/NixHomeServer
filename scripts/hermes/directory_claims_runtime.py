"""Narrow native tool seams for filesystem directory claims."""
from contextlib import contextmanager
import os
from pathlib import Path
import shlex
import subprocess
import sys

try:
    from hermes_cli import nixhomeserver_directory_claims as claims
except ImportError:
    import directory_claims as claims

# Cache only the assigned workspace, never ownership. A `cd /tmp` cannot drop
# source protection; every operation reads current claims from the filesystem.
BOUND = {}


def identity(task_id, session_id, profile=None):
    if profile is None:
        from hermes_cli.profiles import get_active_profile_name
        profile = get_active_profile_name()
    session = session_id or task_id
    if not session or session == 'default':
        raise ValueError('Source writes require a runtime-established writer session')
    return str(profile) + ':' + str(session)


def project_for(owner, cwd, task_id):
    if owner in BOUND:
        return claims.Project(BOUND[owner])
    try:
        from tools.terminal_tool import resolve_task_overrides
        assigned = resolve_task_overrides(task_id).get('cwd') or cwd
    except ImportError:
        assigned = cwd
    project = claims.Project(assigned)
    BOUND[owner] = str(project.root)
    return project


def terminal_command(command, *, cwd, task_id, session_id, workdir=None,
                     env_type='local', profile=None):
    owner = identity(task_id, session_id, profile)
    if env_type != 'local':
        raise ValueError('Directory claims require the local shared filesystem; no unsandboxed remote fallback')
    project = project_for(owner, cwd, task_id)
    prefix = [sys.executable, '-B', str(Path(claims.__file__).resolve()),
              '--repo', str(project.root), '--writer-pid', str(os.getpid()), '--owner', owner]
    try:
        words = shlex.split(command)
    except ValueError:
        words = []  # Let the confined shell report its original syntax error.
    # This is a literal argv management path, never a raw-shell exemption.
    scripts = {Path(claims.__file__).resolve(),
               Path(__file__).resolve().parents[2] / 'scripts/directory_claims.py'}
    if len(words) >= 3 and Path(words[0]).name in ('python', 'python3'):
        index = 2 if words[1] == '-B' else 1
        if (len(words) > index + 1 and Path(os.path.expanduser(words[index])).resolve() in scripts
                and words[index + 1] in ('claim', 'request', 'list', 'release', 'recover')
                and not any(c in command for c in (';', '\n', '`', '$', '|', '&', '<', '>'))):
            return shlex.join(prefix + words[index + 1:])
    if words[:2] in (['git', 'add'], ['git', 'commit']) and not any(
            c in command for c in (';', '\n', '`', '$', '|', '&', '<', '>')):
        return shlex.join(prefix + ['git', *words[1:]])
    actual = Path(workdir or cwd)
    if not actual.is_absolute():
        actual = Path(cwd) / actual
    return shlex.join(prefix + ['run', '--cwd', str(actual), '--', '/bin/bash', '-c', command])


@contextmanager
def file_write(paths, *, task_id, session_id):
    from tools.file_tools import _resolve_or_none
    from tools.terminal_tool import _get_env_config, resolve_task_overrides
    config = _get_env_config()
    if config['env_type'] != 'local':
        raise ValueError('Claimed source writes require the local shared filesystem')
    owner = identity(task_id, session_id)
    cwd = resolve_task_overrides(task_id).get('cwd') or config['cwd']
    project = project_for(owner, cwd, task_id)
    resolved = [_resolve_or_none(path, task_id, entry=entry) for path in paths for entry in (False, True)]
    if not resolved or not all(resolved):
        raise ValueError('All write and move paths must resolve before checking directory ownership')
    with project.writing(owner, resolved):
        yield
