"""Explicit board for model-facing card creation.

A ``kanban_create`` that omits its board silently lands on whichever board the
resolution chain picks, and a dispatched worker's foreign board is silently
pinned back to its own board. Either way the model believes it wrote a card
somewhere it did not, and a later ``kanban_show`` on that board cannot find it.

Validate the caller's intent before any board file is opened, created or
written. This never widens cross-board writes: a worker may only create on the
board its card was claimed from.
"""
import os

_REQUIRED = ('board is required: name the board this card belongs on '
             "(for example board='nixhomeserver'). Nothing changed.")


def _pinned_board():
    """Board a dispatcher-owned worker was claimed from; ``None`` anywhere else."""
    if not (os.environ.get('HERMES_KANBAN_TASK') or '').strip():
        return None
    try:
        from agent.delegation_context import is_dispatcher_owned_worker_context
        if not is_dispatcher_owned_worker_context():
            return None
    except Exception:
        return None
    from hermes_cli import kanban_db as kb
    try:
        return kb._normalize_board_slug(os.environ.get('HERMES_KANBAN_BOARD') or None)
    except ValueError:
        return None


def _validate(board, *, normalize, exists, pinned):
    """Decision table; ``normalize``/``exists``/``pinned`` come from native state."""
    if not isinstance(board, str) or not board.strip():
        raise ValueError(_REQUIRED)
    try:
        slug = normalize(board)
    except ValueError:
        raise ValueError(f'board {board!r} is not a valid board slug: use 1-64 '
                         'lowercase letters, digits, hyphens or underscores. '
                         'Nothing changed.') from None
    if not slug:
        raise ValueError(_REQUIRED)
    if pinned is not None:
        if slug != pinned:
            raise ValueError(f'board {slug!r} is refused: this worker creates cards '
                             f'only on its own board {pinned!r}. Nothing changed.')
        return slug
    if not exists(slug):
        raise ValueError(f'board {slug!r} does not exist: name an existing board. '
                         'Nothing changed.')
    return slug


def require_explicit_board(board):
    """Normalized board slug for a create, or ``ValueError`` before any board I/O."""
    from hermes_cli import kanban_db as kb
    return _validate(board, normalize=kb._normalize_board_slug,
                     exists=kb.board_exists, pinned=_pinned_board())
