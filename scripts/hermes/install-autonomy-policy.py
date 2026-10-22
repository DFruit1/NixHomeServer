#!/usr/bin/env python3
"""Install approved Hermes autonomy helpers without changing models or credentials."""
import argparse
import os
from pathlib import Path
import sys

from autonomy_runtime_adapter import adapt, EDITS
from hermes_common import atomic_write, backup_file

SOURCE = Path(__file__).resolve().parent


def install(root, check=False):
    native = root / 'hermes-agent'
    # Install the safe dependency before adding its import sites, including on retry.
    pending = {native / 'hermes_cli/nixhomeserver_autonomy.py': (SOURCE / 'autonomy_runtime.py').read_text()}
    pending.update({native / name: adapt(name, (native / name).read_text()) for name in EDITS})
    for name in ('autonomy-policy.py', 'fixture-runner.py', 'hermes_common.py'):
        pending[root / 'scripts' / name] = (SOURCE / name).read_text()
    pending[root / 'scripts/hermes-autonomy.md'] = (SOURCE.parents[1] / 'documentation/hermes-autonomy.md').read_text()
    changes = []
    for path, text in pending.items():
        if path.is_symlink():
            raise ValueError('Refusing symlink install target')
        old = path.read_text() if path.exists() else None
        if old != text:
            changes.append((path, old, text))
    for path, old, text in changes:
        print(f'{"drift" if check else "install"}: {path.relative_to(root)}')
        if check:
            continue
        if old is not None:
            if path.read_text() != old:
                raise ValueError('Install target changed during preflight')
            backup_file(root, 'autonomy-policy', path)
        atomic_write(path, text)
    return int(check and bool(changes))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    if not args.check and any(os.environ.get(k) for k in (
            'HERMES_KANBAN_TASK', 'HERMES_DELEGATED_CHILD_CONTEXT', 'HERMES_KANBAN_RUN_ID')):
        parser.error('Autonomy installation requires the interactive operator')
    try:
        sys.exit(install(Path(os.environ.get('HERMES_ROOT', str(Path.home() / '.hermes'))), args.check))
    except (ValueError, OSError) as exc:
        print(f'Autonomy installation refused: {exc}', file=sys.stderr)
        sys.exit(2)
