#!/usr/bin/env python3
"""Install metadata-only native worker origin, preserving running imports.

The helper is installed first; a version-checked native session-creation seam is
then replaced atomically. Existing source bytes remain in private durable backups.
New workers load the change; this installer never starts or restarts a service.
"""
import argparse
import fcntl
import os
from pathlib import Path
import sys

from hermes_common import atomic_write, backup_file
from worker_origin_adapter import adapt, adapt_local

SOURCE = Path(__file__).resolve().parent


def _read(path):
    if path.is_symlink():
        raise ValueError('Refusing a symlink worker-origin target')
    return path.read_text() if path.exists() else None


def pending_files(root):
    """Qualify every source seam before the installer or fleet publishes bytes."""
    native = root / 'hermes-agent/run_agent.py'
    local = root / 'hermes-agent/tools/environments/local.py'
    local_before = _read(local)
    if local_before is None:
        raise ValueError('Native Hermes local terminal runtime is missing')
    helper = root / 'hermes-agent/hermes_cli/nixhomeserver_worker_origin.py'
    before = _read(native)
    if before is None:
        raise ValueError('Native Hermes run_agent.py is missing')
    code = (SOURCE / 'worker_origin.py').read_text()
    compile(code, str(helper), 'exec')
    shared = root / 'scripts/worker_origin.py'
    return [(helper, _read(helper), code), (shared, _read(shared), code),
            (native, before, adapt(before)), (local, local_before, adapt_local(local_before))]


def install(root, check=False):
    if not check and (root / 'state/fleet/current.json').exists():
        raise ValueError('Fleet-managed worker installation: use fleet-release.py apply')
    pending = pending_files(root)
    changes = [(path, old, new) for path, old, new in pending if old != new]
    if check:
        for path, _, _ in changes:
            print(f'drift: {path.relative_to(root)}')
        return int(bool(changes))
    if not changes:
        return 0
    locks = root / 'backups/worker-origin'
    locks.mkdir(parents=True, exist_ok=True, mode=0o700)
    with (locks / 'install.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        if any(_read(path) != old for path, old, _ in pending):
            raise ValueError('Worker-origin target changed during preflight')
        for path, old, new in changes:
            if _read(path) != old:
                raise ValueError('Worker-origin target changed before replacement')
            if old is not None:
                backup_file(root, 'worker-origin', path)
            atomic_write(path, new)
            if _read(path) != new:
                raise ValueError('Worker-origin installed readback differs')
            print(f'install: {path.relative_to(root)}')
    return 0


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    try:
        sys.exit(install(Path(os.environ.get('HERMES_ROOT', str(Path.home() / '.hermes'))), args.check))
    except (OSError, ValueError, TypeError):
        print('Worker-origin installation refused; no configuration values logged', file=sys.stderr)
        sys.exit(2)
