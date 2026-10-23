#!/usr/bin/env python3
"""Run a repository synthetic suite with no production state or credentials.

Python operations glue for existing shell/native Hermes tests. Bubblewrap
provides the confinement; there is deliberately no unsandboxed fallback.
"""
import argparse
import hashlib
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
SYSTEM_SUITE_PYTHON = Path('/usr/bin/python3')
YAML_SUITES = frozenset((
    'test-kanban-owner-alerts.sh', 'test-steward-readonly.sh',
    'test-steward-opportunity-scan.sh', 'test-kanban-retry-breaker.sh',
    'test-hermes-autonomy.sh', 'test-hermes-autonomy-runtime.sh',
    'test-hermes-worker-policy.sh',
))
NATIVE_IMPORT_SUITES = frozenset((
    'test-hermes-worker-origin.sh',
    'test-hermes-recovered-resume.sh', 'test-hermes-coordinator-repair.sh',
    'test-hermes-workspace-repair.sh',
))
FIXTURE_BOOTSTRAP = r'''import hashlib, json, os, subprocess, sys
kind, source = sys.argv[1:3]
source_sha256 = hashlib.sha256(open(source, 'rb').read()).hexdigest()
origin = open(os.environ['HERMES_FIXTURE_ORIGIN'], 'rb').read()
origin_sha256 = hashlib.sha256(origin).hexdigest()
if source_sha256 != os.environ['HERMES_FIXTURE_SOURCE_SHA256'] or origin_sha256 != os.environ['HERMES_FIXTURE_ORIGIN_SHA256']:
    print('Fixture source or origin binding changed', file=sys.stderr)
    raise SystemExit(125)
try:
    import yaml
    yaml_version, yaml_module = yaml.__version__, yaml.__file__
except ImportError:
    yaml_version = yaml_module = None
yaml_required = ('test-kanban-owner-alerts.sh', 'test-steward-readonly.sh',
                 'test-steward-opportunity-scan.sh', 'test-kanban-retry-breaker.sh',
                 'test-hermes-autonomy.sh', 'test-hermes-autonomy-runtime.sh',
                 'test-hermes-worker-policy.sh')
if kind == 'suite' and source.rsplit('/', 1)[-1] in yaml_required and yaml_version is None:
    print('Required suite Python lacks yaml', file=sys.stderr)
    raise SystemExit(125)
if kind == 'suite' and source.rsplit('/', 1)[-1] in ('test-kanban-retry-breaker.sh', 'test-hermes-autonomy.sh', 'test-hermes-autonomy-runtime.sh'):
    native = subprocess.run([os.environ['HERMES_FIXTURE_NATIVE_PYTHON'], '-B', '-c',
                              'import json, hermes_cli.main, hermes_yaml, sys; '
                              'probe=hermes_yaml.safe_load("fixture: true"); assert probe == {"fixture": True}; '
                              'print(json.dumps({"python":sys.executable,"version":sys.version.split()[0],'
                              '"yaml_module":hermes_yaml.__file__,"yaml_probe":probe,'
                              '"hermes_cli_module":hermes_cli.main.__file__}))'],
                             stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=15)
    if native.returncode:
        print('Declared native Hermes imports failed', file=sys.stderr)
        raise SystemExit(125)
    check = subprocess.run(['/run/hermes-fixture/bin/hermes', '--help'],
                           stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL, timeout=30)
    if check.returncode:
        print('Declared Hermes CLI readiness failed', file=sys.stderr)
        raise SystemExit(125)
else:
    native = subprocess.run([os.environ['HERMES_FIXTURE_NATIVE_PYTHON'], '-B', '-c',
                              'import json,sys; print(json.dumps({"python":sys.executable,"version":sys.version.split()[0]}))'],
                             stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=10)
if native.returncode:
    print(f'Native Hermes Python readiness failed ({native.returncode})', file=sys.stderr)
    raise SystemExit(125)
native_python = json.loads(native.stdout)
print('HERMES_FIXTURE_RECEIPT ' + json.dumps({
    'version': 1, 'event': 'readiness', 'kind': kind, 'source': source,
    'source_sha256': source_sha256,
    'helper_sha256': os.environ['HERMES_FIXTURE_HELPER_SHA256'],
    'origin_sha256': origin_sha256,
    'python': sys.executable, 'python_version': sys.version.split()[0],
    'yaml_version': yaml_version, 'yaml_module': yaml_module,
    'native_python': native_python,
    'hermes_help_exit': check.returncode if kind == 'suite' and source.rsplit('/', 1)[-1] in
        ('test-kanban-retry-breaker.sh', 'test-hermes-autonomy.sh', 'test-hermes-autonomy-runtime.sh') else None,
}), file=sys.stderr, flush=True)
raise SystemExit(subprocess.run(sys.argv[3:]).returncode)
'''

def receipt(event, **fields):
    print('HERMES_FIXTURE_RECEIPT ' + json.dumps(
        {'version': 1, 'event': event, **fields}, sort_keys=True, separators=(',', ':')),
        file=sys.stderr, flush=True)


def suite_interpreter(suite_path):
    """Qualify existing toolchains without admitting the host's user site.

    Native workers put Hermes' managed Python first on PATH. Host user-site
    imports can hide its missing dependencies until the fixture changes HOME.
    Prefer PATH when qualified, then the installed distro toolchain; never
    install packages or mount a user's site-packages to satisfy this probe.
    """
    found = shutil.which('python3')
    if not found:
        raise ValueError('Declared suite Python python3 is required')
    primary = Path(found).resolve(strict=True)
    if suite_path is None or suite_path.name not in YAML_SUITES | NATIVE_IMPORT_SUITES:
        return primary
    imports = 'yaml, ruamel.yaml' if suite_path.name in NATIVE_IMPORT_SUITES else 'yaml'
    candidates = dict.fromkeys((primary, SYSTEM_SUITE_PYTHON.resolve()))
    for candidate in candidates:
        if not candidate.is_file():
            continue
        try:
            probe = subprocess.run(
                [str(candidate), '-I', '-B', '-c', 'import ' + imports],
                stdin=subprocess.DEVNULL, capture_output=True, timeout=10)
        except (OSError, subprocess.TimeoutExpired):
            continue
        if probe.returncode == 0:
            return candidate
    raise ValueError('No installed suite Python imports ' + imports + ' in isolation; '
                     'provision the test toolchain, not the host user site')


def command(repo, suite, runtime, scratch, subject=None):
    repo, runtime = (Path(p).resolve(strict=True) for p in (repo, runtime))
    suite_path = None
    subject_path = None
    if suite is not None:
        suite_path = Path(suite).resolve(strict=True)
        if (not suite_path.is_relative_to(repo / 'scripts/tests') or suite_path.parent != repo / 'scripts/tests'
                or not re.fullmatch(r'test-[a-z0-9-]+\.sh', suite_path.name)):
            raise ValueError('Choose a checked-in synthetic shell suite under scripts/tests')
        relative = str(suite_path.relative_to(repo))
    else:
        if subject != 'learning-trials-list':
            raise ValueError('Choose a declared synthetic subject')
        subject_path = repo / 'scripts/hermes/background-learning-trials.py'
        resolved = subject_path.resolve(strict=True)
        if not resolved.is_relative_to(repo) or subject_path.is_symlink():
            raise ValueError('Synthetic subject must remain inside the readonly repository')
        subject_path = resolved
        relative = 'scripts/hermes/background-learning-trials.py'
    tracked = subprocess.run(['git', '-C', str(repo), 'ls-files', '--error-unmatch', '--', relative],
                             capture_output=True, text=True)
    if tracked.returncode:
        raise ValueError('Suite or subject must be tracked before execution')
    bwrap = shutil.which('bwrap')
    if not bwrap:
        raise ValueError('bubblewrap is required; no unsandboxed fallback')
    python = runtime / '.venv/bin/python'
    if not python.is_file():
        raise ValueError('Declared native Hermes Python environment is required')
    suite_python = suite_interpreter(suite_path)
    home = scratch / 'home'
    (home / '.hermes').mkdir(parents=True)
    (home / '.hermes/config.yaml').write_text('model: {default: fixture}\n')
    (scratch / 'bin').mkdir()
    python_wrapper = scratch / 'bin/python3'
    python_wrapper.write_text('#!/bin/sh\nexec ' + shlex.quote(str(suite_python)) + ' "$@"\n')
    python_wrapper.chmod(0o700)
    wrapper = scratch / 'bin/hermes'
    if suite_path is not None:
        wrapper.write_text('#!/bin/sh\nexec ' + shlex.quote(str(python)) + ' -m hermes_cli.main "$@"\n')
        wrapper.chmod(0o700)
    origin = scratch / 'origin.json'
    origin.write_text(json.dumps({'origin': {k: os.environ[k] for k in ORIGIN_KEYS if k in os.environ},
                                 'suite': str(suite_path) if suite_path else None,
                                 'subject': subject, 'provenance': 'confined-synthetic-test'}))
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
    suite_python_root = suite_python.parent.parent
    mounted_roots = (Path('/usr'), Path('/bin'), Path('/lib'), Path('/lib64'),
                     Path('/nix/store'), repo, runtime, python_root)
    if not any(suite_python_root == root or suite_python_root.is_relative_to(root)
               for root in mounted_roots):
        args += ['--ro-bind', str(suite_python_root), str(suite_python_root)]
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
               HERMES_FIXTURE_NATIVE_PYTHON=str(python),
               HERMES_FIXTURE_ACTIVE='1', PYTHONDONTWRITEBYTECODE='1', LANG='C.UTF-8')
    bash = shutil.which('bash')
    if not bash:
        raise ValueError('Bash is required for shell fixtures')
    if suite_path is not None:
        launch = [str(Path(bash).resolve()), str(suite_path)]
        kind, source = 'suite', str(suite_path)
    else:
        launch = ['/run/hermes-fixture/bin/python3', '-B', str(subject_path)]
        kind, source = 'subject', str(subject_path)
    env.update(HERMES_FIXTURE_SOURCE_SHA256=hashlib.sha256(Path(source).read_bytes()).hexdigest(),
               HERMES_FIXTURE_HELPER_SHA256=hashlib.sha256(Path(__file__).resolve().read_bytes()).hexdigest(),
               HERMES_FIXTURE_ORIGIN_SHA256=hashlib.sha256(origin.read_bytes()).hexdigest())
    args += ['--chdir', str(repo), '--', str(suite_python), '-B', '-c', FIXTURE_BOOTSTRAP,
             kind, source, *launch]
    return args, env


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo', type=Path, required=True)
    selection = parser.add_mutually_exclusive_group(required=True)
    selection.add_argument('--suite', type=Path)
    selection.add_argument('--subject', choices=('learning-trials-list',))
    parser.add_argument('--timeout', type=int, default=300)
    args = parser.parse_args()
    if not 1 <= args.timeout <= 1800:
        parser.error('Timeout must be 1..1800 seconds')
    root = Path(os.environ.get('HERMES_ROOT', str(Path.home() / '.hermes')))
    try:
        with tempfile.TemporaryDirectory(prefix='hermes-fixture-', dir='/tmp') as directory:
            argv, env = command(args.repo, args.suite, root / 'hermes-agent', Path(directory), args.subject)
            source = (Path(args.suite) if args.suite is not None else
                      args.repo / 'scripts/hermes/background-learning-trials.py').resolve()
            origin_bytes = (Path(directory) / 'origin.json').read_bytes()
            pins = {key: ('present' if key in os.environ else 'absent') for key in ORIGIN_KEYS}
            safe_ids = {key: os.environ[key] for key in
                        ('HERMES_KANBAN_TASK', 'HERMES_KANBAN_BOARD', 'HERMES_KANBAN_RUN_ID')
                        if os.environ.get(key)}
            launch_context = {
                'kind': 'suite' if args.suite is not None else 'subject',
                'source': str(source.resolve()),
                'source_sha256': hashlib.sha256(Path(source).read_bytes()).hexdigest(),
                'helper_sha256': hashlib.sha256(Path(__file__).resolve().read_bytes()).hexdigest(),
                'origin_sha256': hashlib.sha256(origin_bytes).hexdigest(),
            }
            receipt('launch', repo=str(args.repo.resolve()), pins=pins, safe_ids=safe_ids,
                    **launch_context)
            try:
                process = subprocess.Popen(argv, env=env, start_new_session=True)
            except OSError as exc:
                receipt('terminal', returncode=126, timed_out=False, start_failed=True,
                        **launch_context)
                print(f'Fixture process could not start ({type(exc).__name__})', file=sys.stderr)
                return 126
            try:
                code = process.wait(timeout=args.timeout)
                receipt('terminal', returncode=code, timed_out=False, **launch_context)
                return code
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                process.wait()
                receipt('terminal', returncode=124, timed_out=True, **launch_context)
                print('Fixture timed out; no unsandboxed retry', file=sys.stderr)
                return 124
    except (OSError, ValueError) as exc:
        print(f'Fixture execution refused: {exc}', file=sys.stderr)
        return 126


if __name__ == '__main__':
    sys.exit(main())
