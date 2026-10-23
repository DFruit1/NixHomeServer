#!/usr/bin/env python3
"""Install reviewed native recovery API and two exact tool/schema seams.

No service restart or running worker interruption. Python is installer glue for
Hermes' Python tool boundary. Every replaced native source has a private backup.
"""
import argparse
import fcntl
import os
from pathlib import Path
import stat
import sys

from hermes_common import atomic_write, backup_file
from recovered_resume_adapter import adapt
from coordinator_repair_adapter import adapt as amend_adapt
from resume_recovered import validate_native_source

SOURCE = Path(__file__).resolve().parent


def _read(path):
    if path.is_symlink():
        raise ValueError('Refusing a symlink recovered-resume target')
    return path.read_text() if path.exists() else None


def install(root, check=False):
    root = Path(root)
    if root.is_symlink():
        raise ValueError('Refusing a symlink recovery install root')
    root = root.resolve()
    native = root / 'hermes-agent'
    phase = native / 'hermes_cli/kanban_db.py'
    phase_source = _read(phase)
    if phase_source is None:
        raise ValueError('Native Kanban API is missing')
    validate_native_source(phase_source)
    pending = []
    for source, relative in (
            ('resume_recovered.py', 'hermes_cli/nixhomeserver_resume_recovered.py'),
            ('coordinator_repair.py', 'hermes_cli/nixhomeserver_coordinator_repair.py')):
        code = (SOURCE / source).read_text()
        compile(code, source, 'exec')
        target = native / relative
        pending.append((target, _read(target), code))
    # The actor proof is installed by the separate, independently reviewed
    # worker-origin installer; do not substitute caller-selected role evidence.
    origin = native / 'hermes_cli/nixhomeserver_worker_origin.py'
    origin_source = (SOURCE / 'worker_origin.py').read_text()
    if _read(origin) != origin_source:
        raise ValueError('Install the matching reviewed native worker-origin helper first')
    monitor = native / 'cron/nixhomeserver_capability_recovery.py'
    monitor_source = (SOURCE / 'capability_recovery.py').read_text()
    if _read(monitor) != monitor_source:
        raise ValueError('Install the matching canonical capability monitor first')
    for name in ('tools/kanban_tools.py', 'tools/kanban_tools_schemas.py'):
        target = native / name
        before = _read(target)
        if before is None:
            raise ValueError('Native recovered-resume tool source is missing')
        pending.append((target, before, amend_adapt(name, adapt(name, before))))
    # Keep the guarded database adapter last: phase_source is a preflight
    # dependency for every earlier replacement, and its phase APIs are unchanged.
    pending.append((phase, phase_source, adapt('hermes_cli/kanban_db.py', phase_source)))
    changes = [(path, before, after) for path, before, after in pending if before != after]
    if check:
        for path, _, _ in changes:
            print(f'drift: {path.relative_to(root)}')
        return int(bool(changes))
    if not changes:
        return 0
    backups = root / 'backups'
    backups.mkdir(exist_ok=True, mode=0o700)
    info = backups.lstat()
    if (not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid()
            or info.st_mode & 0o077):
        raise ValueError('Installer backups must be a private directory')
    journal = backups / 'recovered-resume'
    journal.mkdir(exist_ok=True, mode=0o700)
    for directory in (journal,):
        info = directory.lstat()
        if (not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid()
                or info.st_mode & 0o077):
            raise ValueError('Installer backups must be private directories')
    fd = os.open(journal / 'install.lock', os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        info = os.fstat(fd)
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
                or info.st_mode & 0o077 or info.st_nlink != 1):
            raise ValueError('Installer lock must be a private regular file')
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        guards = [(phase, phase_source), (origin, origin_source), (monitor, monitor_source)]
        if (any(_read(path) != before for path, before in guards)
                or any(_read(path) != before for path, before, _ in pending)):
            raise ValueError('Native source changed during recovery installer preflight')
        for path, before, after in changes:
            if (_read(path) != before
                    or any(_read(dependency) != expected for dependency, expected in guards)):
                raise ValueError('Recovery installer target or dependency changed before replacement')
            if before is not None:
                backup_file(root, 'recovered-resume', path)
            atomic_write(path, after)
            if _read(path) != after:
                raise ValueError('Recovery installed readback differs')
            print(f'install: {path.relative_to(root)}')
    finally:
        os.close(fd)
    return 0


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    if not args.check and any(os.environ.get(key) for key in (
            'HERMES_KANBAN_TASK', 'HERMES_KANBAN_RUN_ID', 'HERMES_DELEGATED_CHILD_CONTEXT')):
        parser.error('Native recovery installation requires the interactive operator')
    try:
        sys.exit(install(Path(os.environ.get('HERMES_ROOT', str(Path.home() / '.hermes'))), args.check))
    except (OSError, ValueError, TypeError):
        print('Recovered-resume installation refused; no configuration values logged', file=sys.stderr)
        sys.exit(2)
