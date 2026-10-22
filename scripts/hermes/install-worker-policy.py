#!/usr/bin/env python3
"""Install bounded worker policy and derived titles, preserving unrelated state.

Python glue reuses Hermes' runtime language and YAML dependency. Backups are
private and durable; config bytes never enter temporary files or diagnostics.
"""
import argparse
import copy
import fcntl
import os
from pathlib import Path
import sys

import yaml

from hermes_common import backup_file, remove_block
from hermes_config import document
from worker_runtime_adapter import adapt

SOURCE = Path(__file__).resolve().parent
WORKERS = ('head-coordinator', 'feature-reviewer', 'project-auditor',
           'standard-implementer', 'local-implementer')
# Commissioning and recovering worker cards is lane work. The retired default
# profile only routes, so it carries no budget block; an older copy is removed.
BUDGETED_SOULS = ('profiles/head-coordinator/SOUL.md',
                  'profiles/project-auditor/SOUL.md')
START, END = '<!-- hermes-worker-budgets -->', '<!-- /hermes-worker-budgets -->'


def derived_titles(text):
    before = document(text)
    expected = copy.deepcopy(before)
    expected.setdefault('auxiliary', {}).setdefault('title_generation', {})['model_upgrade_enabled'] = False
    node = yaml.compose(text)
    for depth, key in enumerate(('auxiliary', 'title_generation', 'model_upgrade_enabled')):
        if not isinstance(node, yaml.MappingNode) or node.flow_style:
            raise ValueError('Title settings require block mappings; preserve and reconcile inline YAML')
        matches = [value for name, value in node.value if name.value == key]
        if matches:
            node = matches[0]
            if depth == 2:
                updated = text[:node.start_mark.index] + 'false' + text[node.end_mark.index:]
        else:
            addition = False
            for nested in reversed(('auxiliary', 'title_generation', 'model_upgrade_enabled')[depth:]):
                addition = {nested: addition}
            indent = node.start_mark.column
            rendered = ''.join(' ' * indent + line + '\n' for line in yaml.safe_dump(addition, sort_keys=False).splitlines())
            index = sum(len(line) for line in text.splitlines(keepends=True)[:node.end_mark.line])
            updated = text[:index].rstrip('\n') + '\n' + rendered + text[index:]
            break
    if document(updated) != expected:
        raise ValueError('Title edit would change unrelated settings')
    return updated


def instruction(text):
    content = (START + '\nBefore commissioning or recovering worker cards, read '
               '~/.hermes/scripts/hermes-worker-budgets.md. Local assignments need '
               'an explicit positive runtime cap. Mark bounded receipt/evidence recovery '
               'with `Recovery mode: evidence-only`; it stops on its first failure. '
               'A retry needs a new coordinator receipt for that exact failed run.\n' + END)
    if START not in text and END not in text:
        return text.rstrip() + '\n\n' + content + '\n'
    if text.count(START) != 1 or text.count(END) != 1 or text.index(END) < text.index(START):
        raise ValueError('Ambiguous worker instruction markers')
    first, tail = text.split(START)
    _, last = tail.split(END)
    return first + content + last


def install(root, check=False):
    pending = {}
    for profile in WORKERS:
        path = root / 'profiles' / profile / 'config.yaml'
        if path.exists():
            pending[path] = derived_titles(path.read_text())
    for relative in BUDGETED_SOULS:
        path = root / relative
        if path.exists():
            pending[path] = instruction(path.read_text())
    default = root / 'SOUL.md'
    if default.exists():
        pending[default] = remove_block(default.read_text(), START, END, 'worker instruction')
    pending[root / 'scripts/hermes-worker-budgets.md'] = (SOURCE / 'instructions/worker-budgets.md').read_text()
    native = root / 'hermes-agent/hermes_cli'
    pending[native / 'nixhomeserver_worker_policy.py'] = (SOURCE / 'worker-policy.py').read_text()
    for name in ('kanban_db.py', 'kanban_db_dispatch.py'):
        path = native / name
        pending[path] = adapt(name, path.read_text())
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
        path.parent.mkdir(parents=True, exist_ok=True)
        fd = os.open(path, os.O_RDWR | os.O_NOFOLLOW | (os.O_CREAT | os.O_EXCL if old is None else 0), 0o600)
        with os.fdopen(fd, 'r+') as stream:
            fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
            if stream.read() != (old or ''):
                raise ValueError('Install target changed during preflight')
            if old is not None:
                backup_file(root, 'worker-policy', path)
            stream.seek(0); stream.write(text); stream.truncate(); stream.flush(); os.fsync(stream.fileno())
    return int(check and bool(changes))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    try:
        sys.exit(install(Path(os.environ.get('HERMES_ROOT', str(Path.home() / '.hermes'))), args.check))
    except (OSError, ValueError, TypeError) as exc:
        print(f'Worker policy installation failed ({type(exc).__name__}); no configuration values logged', file=sys.stderr)
        sys.exit(2)
