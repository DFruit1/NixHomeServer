#!/usr/bin/env python3
"""Install the OpenCode ACP provider into existing Hermes profiles.

Python follows the existing Hermes installer and provider interfaces. This only
copies plugin source; it does not change models, credentials or running jobs.
"""

import argparse
import os
from pathlib import Path

from hermes_common import atomic_write, backup_file

SOURCE = Path(__file__).resolve().parent / 'opencode-acp'
FILES = ('__init__.py', 'plugin.yaml', 'README.md')


def install(root, check=False):
    root = Path(root).expanduser().resolve()
    homes = [root] if (root / 'config.yaml').is_file() else []
    homes += sorted(p.parent for p in (root / 'profiles').glob('*/config.yaml'))
    if not homes:
        raise ValueError(f'No configured Hermes profiles under {root}')
    clean = True
    for home in homes:
        destination = home / 'plugins/model-providers/opencode-acp'
        for name in FILES:
            content = (SOURCE / name).read_text()
            target = destination / name
            if target.exists() and target.read_text() == content:
                continue
            clean = False
            print(('drift: ' if check else 'install: ') + str(target))
            if not check:
                backup_file(root, 'opencode-acp', target)
                atomic_write(target, content)
    return clean if check else True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path,
                        default=Path(os.environ.get('HERMES_ROOT', '~/.hermes')).expanduser())
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    return 0 if install(args.root, check=args.check) else 1


if __name__ == '__main__':
    raise SystemExit(main())
