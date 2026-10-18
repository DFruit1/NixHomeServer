#!/usr/bin/env python3
"""Run a repository synthetic suite with no production state or credentials.

Python operations glue for existing shell/native Hermes tests. Bubblewrap
provides the confinement; there is deliberately no unsandboxed fallback.
"""
import argparse
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile

ORIGIN_KEYS = ('HERMES_KANBAN_TASK', 'HERMES_KANBAN_DB', 'HERMES_KANBAN_BOARD',
               'HERMES_KANBAN_RUN_ID', 'HERMES_KANBAN_CLAIM_LOCK',
               'HERMES_DELEGATED_CHILD_CONTEXT', 'HERMES_PROFILE_NAME', 'HERMES_PROFILE')
RUNTIME_DIRS = ('agent', 'hermes_cli', 'tools', 'gateway', 'cron', 'hermes_platform',
                'providers', 'plugins', 'skills', 'locales', 'assets', 'acp_adapter',
                'pm', 'hermes_agent.egg-info', '.venv')


def command(repo, suite, runtime, scratch):
    repo, suite, runtime = (Path(p).resolve(strict=True) for p in (repo, suite, runtime))
    if (not suite.is_relative_to(repo / 'scripts/tests') or suite.parent != repo / 'scripts/tests'
            or not re.fullmatch(r'test-[a-z0-9-]+\.sh', suite.name)):
        raise ValueError('Choose a checked-in synthetic shell suite under scripts/tests')
    tracked = subprocess.run(['git', '-C', str(repo), 'ls-files', '--error-unmatch', '--', str(suite)],
                             capture_output=True, text=True)
    if tracked.returncode:
        raise ValueError('Suite must be tracked before execution')
    bwrap = shutil.which('bwrap')
    if not bwrap:
        raise ValueError('bubblewrap is required; no unsandboxed fallback')
    python = runtime / '.venv/bin/python'
    if not python.is_file():
        raise ValueError('Installed native Hermes Python environment is required')
    home = scratch / 'home'
    (home / '.hermes').mkdir(parents=True)
    (home / '.hermes/config.yaml').write_text('model: {default: fixture}\n')
    (scratch / 'bin').mkdir()
    wrapper = scratch / 'bin/hermes'
    wrapper.write_text('#!/bin/sh\nexec ' + shlex.quote(str(python)) + ' -m hermes_cli.main "$@"\n')
    wrapper.chmod(0o700)
    origin = scratch / 'origin.json'
    origin.write_text(json.dumps({'origin': {k: os.environ[k] for k in ORIGIN_KEYS if k in os.environ},
                                 'suite': str(suite), 'provenance': 'confined-synthetic-test'}))
    args = [bwrap, '--unshare-all', '--die-with-parent', '--new-session', '--cap-drop', 'ALL']
    # No host root/home/state mount: readonly files can still expose credentials
    # and filesystem Unix sockets. Mount only the required runtime directories.
    for path in ('/usr', '/bin', '/lib', '/lib64', '/nix/store'):
        if Path(path).exists():
            args += ['--ro-bind', path, path]
    args += ['--dir', '/etc']
    for path in ('/etc/ld.so.cache', '/etc/nsswitch.conf'):
        if Path(path).is_file():
            args += ['--ro-bind', path, path]
    args += ['--proc', '/proc', '--dev', '/dev', '--tmpfs', '/tmp', '--tmpfs', '/run',
             '--dir', '/run/hermes-fixture', '--bind', str(home), '/run/hermes-fixture/home',
             '--ro-bind', str(scratch / 'bin'), '/run/hermes-fixture/bin',
             '--ro-bind', str(origin), '/run/hermes-fixture/origin.json',
             '--ro-bind', str(repo), str(repo)]
    for name in ('secrets/unencrypted', '.worktrees', '.tmp'):
        if (repo / name).is_dir():
            args += ['--tmpfs', str(repo / name)]
    # Mount code only, not the runtime checkout's ignored .env/.hermes/auth/logs.
    for name in RUNTIME_DIRS:
        path = runtime / name
        if path.is_dir():
            args += ['--ro-bind', str(path), str(path)]
    for path in sorted(runtime.glob('*.py')):
        args += ['--ro-bind', str(path), str(path)]
    # The venv points at the installed uv CPython distribution. Both its actual
    # path and pyvenv.cfg's alias are needed, without mounting the surrounding home.
    python_root = python.resolve().parent.parent
    args += ['--ro-bind', str(python_root), str(python_root)]
    for line in (runtime / '.venv/pyvenv.cfg').read_text().splitlines():
        if line.startswith('home = '):
            alias = Path(line.split(' = ', 1)[1]).parent
            args += ['--ro-bind', str(alias.resolve()), str(alias)]
    nix = shutil.which('nix')
    nix_bin = str(Path(nix).resolve().parent) + ':' if nix else ''
    tool_bins = {str(Path(shutil.which(name)).resolve().parent)
                 for name in ('bash', 'python3', 'true') if shutil.which(name)}
    env = dict(PATH='/run/hermes-fixture/bin:' + nix_bin + ':'.join(sorted(tool_bins)) + ':/usr/bin:/bin',
               HOME='/run/hermes-fixture/home', HERMES_HOME='/run/hermes-fixture/home/.hermes',
               HERMES_ROOT='/run/hermes-fixture/home/.hermes',
               HERMES_KANBAN_HOME='/run/hermes-fixture/home/.hermes',
               HERMES_FIXTURE_ORIGIN='/run/hermes-fixture/origin.json',
               HERMES_FIXTURE_ACTIVE='1', PYTHONDONTWRITEBYTECODE='1', LANG='C.UTF-8')
    bash = shutil.which('bash')
    if not bash:
        raise ValueError('Bash is required for shell fixtures')
    args += ['--chdir', str(repo), '--', str(Path(bash).resolve()), str(suite)]
    return args, env


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo', type=Path, required=True)
    parser.add_argument('--suite', type=Path, required=True)
    parser.add_argument('--timeout', type=int, default=300)
    args = parser.parse_args()
    if not 1 <= args.timeout <= 1800:
        parser.error('Timeout must be 1..1800 seconds')
    root = Path(os.environ.get('HERMES_ROOT', str(Path.home() / '.hermes')))
    try:
        with tempfile.TemporaryDirectory(prefix='hermes-fixture-', dir='/tmp') as directory:
            argv, env = command(args.repo, args.suite, root / 'hermes-agent', Path(directory))
            process = subprocess.Popen(argv, env=env, start_new_session=True)
            try:
                return process.wait(timeout=args.timeout)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
                print('Fixture timed out; no unsandboxed retry', file=sys.stderr)
                return 124
    except (OSError, ValueError) as exc:
        print(f'Fixture execution refused: {exc}', file=sys.stderr)
        return 126


if __name__ == '__main__':
    sys.exit(main())
