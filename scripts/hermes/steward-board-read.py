#!/usr/bin/env python3
"""Read board evidence with SQLite query_only, without arbitrary shell/Python.

Existing Python/SQLite operations glue; no new backend or dependency.
"""
import argparse
from contextlib import closing
import json
import os
from pathlib import Path
import re
import sqlite3
import sys
import time


def query(root, board, sql):
    if not re.fullmatch(r'[A-Za-z0-9_-]+(?:/[A-Za-z0-9_-]+)*', board):
        raise ValueError('Invalid board slug')
    path = root / 'kanban/boards' / board / 'kanban.db'
    if not path.resolve().is_relative_to((root / 'kanban/boards').resolve()):
        raise ValueError('Board path leaves the board directory')
    with closing(sqlite3.connect(path.resolve().as_uri() + '?mode=ro', uri=True)) as db:
        db.row_factory = sqlite3.Row
        db.execute('PRAGMA query_only=ON')
        allowed = {sqlite3.SQLITE_SELECT, sqlite3.SQLITE_READ, sqlite3.SQLITE_RECURSIVE}
        def authorise(action, first, second, database, trigger):
            if action in allowed or (action == sqlite3.SQLITE_FUNCTION and second != 'load_extension'):
                return sqlite3.SQLITE_OK
            return sqlite3.SQLITE_DENY
        db.set_authorizer(authorise)
        deadline = time.monotonic() + 5
        db.set_progress_handler(lambda: int(time.monotonic() > deadline), 1000)
        rows = db.execute(sql).fetchmany(201)
        return {'rows': [dict(row) for row in rows[:200]], 'truncated': len(rows) > 200}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--boards', action='store_true', help='List existing active and archived board databases')
    parser.add_argument('--board')
    parser.add_argument('--query')
    args = parser.parse_args()
    try:
        root = Path(os.environ.get('HERMES_ROOT', str(Path.home() / '.hermes')))
        if args.boards:
            if args.board or args.query:
                parser.error('--boards cannot be combined with --board or --query')
            boards = root / 'kanban/boards'
            print(json.dumps({'boards': sorted(str(path.parent.relative_to(boards))
                                               for path in boards.rglob('kanban.db'))}))
        else:
            if not args.board or not args.query:
                parser.error('Supply --boards or both --board and --query')
            print(json.dumps(query(root, args.board, args.query)))
    except (ValueError, sqlite3.Error) as exc:
        print(f'steward board read: {exc}', file=sys.stderr)
        sys.exit(2)
