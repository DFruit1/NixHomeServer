#!/usr/bin/env python3
"""Install filesystem directory claims without changing cards or coordinator gates."""
import argparse
import json
import os
from pathlib import Path
import sys

from directory_claims_adapter import adapt
from hermes_common import atomic_write, backup_file

SOURCE = Path(__file__).resolve().parent
START, END = '<!-- hermes-directory-claims -->', '<!-- /hermes-directory-claims -->'


def instruction(text):
    content = START + '\n' + (SOURCE / 'instructions/directory-claims.md').read_text().rstrip() + '\n' + END + '\n'
    if START not in text and END not in text:
        return text.rstrip() + '\n\n' + content
    if text.count(START) != 1 or text.count(END) != 1 or text.index(END) < text.index(START):
        raise ValueError('Ambiguous directory-claim instruction markers')
    before, rest = text.split(START)
    _, after = rest.split(END)
    return before + content + after.lstrip('\n')


def changes(root, pending=None, *, runtime=True):
    pending = pending or {}
    result = {}
    def current(path):
        return result.get(path, pending.get(path, path.read_text() if path.exists() else ''))
    for home in [root, *sorted((root / 'profiles').glob('*'))]:
        soul = home / 'SOUL.md'
        if soul.exists() and home.name != 'board-steward':
            text = current(soul)
            if home.name == 'head-coordinator' and '<!-- hermes-coordinator-role -->' in text:
                start, end = '<!-- hermes-coordinator-role -->', '<!-- /hermes-coordinator-role -->'
                if text.count(start) != 1 or text.count(end) != 1 or text.index(end) < text.index(start):
                    raise ValueError('Ambiguous managed coordinator role')
                before, rest = text.split(start)
                _, after = rest.split(end)
                role = (SOURCE / 'taskforce/coordinator-role.md').read_text().rstrip()
                result[soul] = before + start + '\n' + role + '\n' + end + after
            else:
                result[soul] = instruction(text)
    result[root / 'scripts/hermes-directory-claims.md'] = (
        SOURCE.parents[1] / 'documentation/hermes-directory-claims.md').read_text()
    for name in ('directory_claims.py',):
        result[root / 'scripts' / name] = (SOURCE / name).read_text()
    if runtime:
        native = root / 'hermes-agent'
        for name in ('file_tools.py', 'terminal_tool.py'):
            path = native / 'tools' / name
            if not path.is_file():
                raise ValueError('Native writer tools must be present before installing directory claims: ' + name)
            result[path] = adapt(name, current(path))
        for name in ('directory_claims', 'directory_claims_runtime'):
            result[native / 'hermes_cli' / ('nixhomeserver_' + name + '.py')] = (
                SOURCE / (name + '.py')).read_text()
    return {p: t for p, t in result.items() if not p.exists() or p.read_text() != t
            or (p in pending and pending[p] != t)}


def install(root, *, check=False):
    pending = changes(root)
    current = root / 'state/fleet/current.json'
    if pending and not check and current.exists() and json.loads(current.read_text()).get('status') == 'active':
        raise ValueError('Active fleet release owns this runtime; install through fleet-release.py plan/apply')
    for path, content in pending.items():
        print(('drift: ' if check else 'install: ') + str(path))
        if not check:
            backup_file(root, 'directory-claims', path)
            atomic_write(path, content)
    return int(check and bool(pending))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    try:
        sys.exit(install(Path(os.environ.get('HERMES_ROOT', str(Path.home() / '.hermes'))), check=args.check))
    except (ValueError, OSError) as exc:
        print('directory-claim installer: ' + str(exc), file=sys.stderr)
        sys.exit(2)
