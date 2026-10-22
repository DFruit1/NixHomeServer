"""Small native Hermes adapters for approved fallbacks and read-only evidence.

Python is Hermes integration glue. Mutating connections and worker ownership
continue to use the upstream native path; this module never changes env pins.
"""
from contextlib import contextmanager
import os
from pathlib import Path
import re
import sqlite3


def allowed_fallbacks(chain, profile):
    """Only configured routes are approved; credential-handling contexts stay local."""
    return [] if profile == 'local-implementer' else chain


@contextmanager
def evidence_board(original, board, profile):
    if not board or profile != 'head-coordinator' or os.environ.get('HERMES_DELEGATED_CHILD_CONTEXT'):
        with original(board) as pair:
            yield pair
        return
    from hermes_cli import kanban_db as kb
    if not re.fullmatch(r'[a-z0-9][a-z0-9_-]{0,63}', board):
        raise ValueError('Invalid evidence board slug')
    root = kb.kanban_home().resolve()
    base = root / 'kanban/boards'
    path = root / 'kanban.db' if board == 'default' else base / board / 'kanban.db'
    if not path.resolve().is_relative_to(root if board == 'default' else base):
        raise ValueError('Evidence board leaves the board directory')
    db = sqlite3.connect(path.resolve().as_uri() + '?mode=ro', uri=True, timeout=5)
    db.row_factory = sqlite3.Row
    try:
        db.execute('PRAGMA query_only=ON')
        allowed = {sqlite3.SQLITE_SELECT, sqlite3.SQLITE_READ, sqlite3.SQLITE_RECURSIVE}
        db.set_authorizer(lambda action, first, second, database, trigger:
                         sqlite3.SQLITE_OK if action in allowed or (
                             action == sqlite3.SQLITE_FUNCTION and second != 'load_extension')
                         else sqlite3.SQLITE_DENY)
        yield kb, db
    finally:
        db.close()
