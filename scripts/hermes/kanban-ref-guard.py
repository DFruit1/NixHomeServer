#!/usr/bin/env python3
"""Refuse a kanban_complete whose handoff cites a task id no board knows.

Standard-library operations glue over read-only board databases; it adds no
service, dependency or board write. A bare ``t_<hash>`` and a qualified
``<board>/t_<hash>`` both resolve against every readable board, so a legitimate
cross-board or archived card passes while a fabricated id cannot be laundered
into the durable handoff. An unreadable board database is reported on stderr and
skipped: only ids absent from every readable board are refused, and a run that
could read no board at all cannot verify the citation, so it fails closed.
"""
from contextlib import closing
import json
import os
from pathlib import Path
import re
import sqlite3
import sys

# Handoff prose names a card as ``t_<hash>``, optionally qualified by its board.
# The lookarounds stop a longer word or path segment from being sliced into a
# bogus id, and the qualifier is documentation only: resolution is global.
REFERENCE = re.compile(r'(?<![A-Za-z0-9_-])t_[A-Za-z0-9_]+(?![A-Za-z0-9_])')


def references(value, found=None):
    """Every task id named anywhere in the handoff text (nested dict/list aware)."""
    found = set() if found is None else found
    if isinstance(value, str):
        found.update(match.group(0) for match in REFERENCE.finditer(value))
    elif isinstance(value, dict):
        for key, item in value.items():
            references(key, found)
            references(item, found)
    elif isinstance(value, (list, tuple)):
        for item in value:
            references(item, found)
    return found


def known(root, warn):
    """All task ids on readable boards, plus how many board databases opened."""
    ids, readable = set(), 0
    boards = root / 'kanban/boards'
    for path in sorted(boards.rglob('kanban.db')) if boards.is_dir() else []:
        try:
            # Hermes leaves a zero-byte kanban.db in a board that was never used
            # (e.g. the archive board); it holds no ids, so it is not a warning.
            if path.stat().st_size:
                with closing(sqlite3.connect(path.resolve().as_uri() + '?mode=ro', uri=True, timeout=5)) as db:
                    db.execute('PRAGMA query_only=ON')
                    db.execute('BEGIN')
                    ids.update(row[0] for row in db.execute('SELECT id FROM tasks'))
            readable += 1
        except (OSError, sqlite3.Error) as exc:
            warn(f'kanban-ref-guard: board database {path} is unreadable; its ids cannot be '
                 f'verified: {exc}')
    return ids, readable


def guard(payload, root, warn):
    if payload.get('tool_name') != 'kanban_complete':
        return {}
    args = payload.get('tool_input') or {}
    cited = sorted(references([args.get('summary'), args.get('result'), args.get('metadata')]))
    if not cited:
        return {}
    ids, readable = known(root, warn)
    unknown = [task for task in cited if task not in ids]
    if not unknown:
        return {}
    listing = ', '.join(unknown)
    if not readable:
        return {'action': 'block', 'message':
                f'Completion refused: no board database could be read, so the cited task id(s) '
                f'{listing} cannot be verified. Restore the board databases, then cite only ids '
                'that resolve; do not bypass this guard with the CLI.'}
    return {'action': 'block', 'message':
            f'Completion refused: unknown task id(s) {listing}. Cite only ids that resolve '
            'somewhere on a board, or drop the reference; never invent a task id in a durable '
            'handoff.'}


if __name__ == '__main__':
    try:
        root = Path(os.environ.get('HERMES_ROOT', str(Path.home() / '.hermes'))).resolve()
        print(json.dumps(guard(json.load(sys.stdin), root, lambda message: print(message, file=sys.stderr))))
    except (ValueError, TypeError, AttributeError, OSError) as exc:
        print(json.dumps({'action': 'block', 'message': f'Task-id reference check failed closed: {exc}'}))
