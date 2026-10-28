#!/usr/bin/env python3
"""Check owner-gate authorship before native Hermes writes, using existing hooks.

Standard-library operations glue; technical blockers and ordinary comments
remain available to their workers. The shared account is a workflow boundary.
"""
import importlib.util
from contextlib import closing
import json
import os
from pathlib import Path
import re
import sqlite3
import sys

PROFILE = 'head-coordinator'
COMMENT_LIMIT = 400
COMMENT_LINES = 8
CARD_COMMENT_LIMIT = 5


def comment_budget(args, root):
    """Count all existing comments read-only; a sixth needs human review."""
    try:
        board, task_id = args.get('board'), args.get('task_id')
        if (not isinstance(board, str) or not re.fullmatch(r'[A-Za-z0-9_-]+', board)
                or not isinstance(task_id, str) or not re.fullmatch(r't_[A-Za-z0-9_]+', task_id)):
            raise ValueError('Provide explicit board and task_id to check the five-comment limit')
        path = root / 'kanban/boards' / board / 'kanban.db'
        with closing(sqlite3.connect(path.resolve().as_uri() + '?mode=ro', uri=True)) as db:
            db.execute('PRAGMA query_only=ON')
            if not db.execute('SELECT 1 FROM tasks WHERE id=?', (task_id,)).fetchone():
                raise ValueError('Unknown task; comment budget cannot be checked')
            count = db.execute('SELECT COUNT(*) FROM task_comments WHERE task_id=?',
                               (task_id,)).fetchone()[0]
        if count >= CARD_COMMENT_LIMIT:
            return {'action': 'block', 'message':
                    f'Card {task_id} is churning: {count} comments already exist '
                    '(limit 5). Human review is required. Stop work and have '
                    'head-coordinator obtain human review. Do not add comments, '
                    'reset the count or create replacement cards to evade this limit.'}
        return {}
    except (ValueError, OSError, sqlite3.Error) as exc:
        return {'action': 'block', 'message': f'Comment budget check failed closed: {exc}'}


def comment_policy(body, profile):
    """Validate new agent prose without rewriting comments or native receipts."""
    if profile == PROFILE:
        # These contracts are consumed verbatim by their existing validators.
        if re.match(r'^Owner reply (?:via SimpleX D\d+:|received:)\s*\S', body):
            return {}
        if body.lstrip().startswith('{') and len(body) <= 32768:
            try:
                receipt = json.loads(body)
            except ValueError:
                receipt = None
            if (isinstance(receipt, dict) and len(receipt) == 1
                    and next(iter(receipt)) in {'deployment_decision',
                        'owner_execution_decision', 'delegated_execution_decision'}
                    and isinstance(next(iter(receipt.values())), dict)):
                return {}
    lines = body.splitlines()
    fields = [line.partition(':')[0] for line in lines
              if re.match(r'^(Update|Evidence|Next):', line)]
    nonempty = all(re.match(r'^(Update|Evidence|Next):[ \t]*\S', line)
                   for line in lines if re.match(r'^(Update|Evidence|Next):', line))
    if (len(body) <= COMMENT_LIMIT and 3 <= len(lines) <= COMMENT_LINES
            and fields == ['Update', 'Evidence', 'Next'] and nonempty
            and lines[0].startswith('Update:') and lines[-1].startswith('Next:')):
        return {}
    return {'action': 'block', 'message':
            'Comment not written. Use at most 400 characters (including whitespace) '
            'and 8 lines, in this order: Update: what changed; Evidence: the result '
            'or one reference; Next: one action or "None". Each field must be '
            'nonempty. Keep required receipt lines between Evidence and Next; '
            'put detailed logs in an artifact. Do not split one update across comments.'}


CAPABILITY_MISCLASS_PATTERNS = [
    # Waiting on another card's output, review, or findings is a dependency, not a capability gap.
    (re.compile(r'\bwaiting on\b.*\b(?:card|task|review|verdict|findings|output|producer|reviewer)\b', re.I),
     'Use kind="dependency" when waiting on another card, review, or upstream output; that is a prerequisite, not a capability gap.'),
    (re.compile(r'\b(?:waiting|blocked|pending|depends?|until|after|once)\b[^.\n]{0,80}\bt_\d{6,}\b', re.I),
     'A block reason that waits on a task ID is describing a dependency on that card; use kind="dependency" and link the prerequisite.'),
    (re.compile(r'\bt_\d{6,}\b[^.\n]{0,80}\b(?:review|verdict|producer|output|findings|completes?|arrives?|done)\b', re.I),
     'A block reason conditioned on another card completing is a dependency, not a capability gap.'),
    (re.compile(r'\b(?:after|once|when|until)\b.*\b(?:review|verdict|producer|reviewer|parent|upstream|findings)\b', re.I),
     'A block reason conditioned on another card completing is a dependency, not a capability gap.'),
    (re.compile(r'\b(?:blocked|waiting)\s+on\s+(?:another|other|upstream|parent)\b', re.I),
     'Waiting on another card is a dependency; link the prerequisite and use kind="dependency".'),
    (re.compile(r'\b(?:capability|tool|permission)\s+(?:gap|missing|not available|unavailable)\b', re.I),
     None),  # This is a legitimate capability block — do not flag.
]


def check_capability_classification(args, root):
    """Detect capability blocks that describe dependency patterns.

    Returns an error message string if the block should be reclassified, or None.
    """
    reason = str(args.get('reason') or '')
    if not reason:
        return None
    # Check for legitimate capability patterns first — if the reason clearly
    # describes a tool/permission gap, do not flag it.
    if re.search(r'\b(?:command|binary|executable|package|library|module|API|endpoint|token|credential)\s+(?:not found|missing|not available|unavailable|denied|exit \d+)\b', reason, re.I):
        return None
    if re.search(r'\b(?:permission denied|exit code \d+|command not found|no such file|not installed)\b', reason, re.I):
        return None
    # A lifecycle catch-22 (a completion guard that requires an edge only a
    # coordinator can retire) is agent-side sequencing, not a card dependency.
    if re.search(r'\b(?:lifecycle guard|sequencing|catch-?22)\b', reason, re.I):
        return None
    for pattern, message in CAPABILITY_MISCLASS_PATTERNS:
        if pattern.search(reason) and message:
            return message
    return None


def guard(payload, root, alerts):
    spec = importlib.util.spec_from_file_location(
        'card_dependencies', Path(__file__).with_name('card-dependency-guard.py'))
    dependencies = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(dependencies)
    decision = dependencies.guard(payload)
    if decision:
        return decision
    tool = payload.get('tool_name')
    args = payload.get('tool_input') or {}
    body = str(args.get('body') or '')
    if tool == 'kanban_comment':
        budget = comment_budget(args, root)
        if budget:
            return budget

    # Classification correctness check: catch capability blocks that are
    # actually dependencies before they reach the board.
    if tool == 'kanban_block' and args.get('kind') == 'capability':
        misclass = check_capability_classification(args, root)
        if misclass:
            return {'action': 'block', 'message': f'Capability block misclassified: {misclass}'}

    # A capability/transient block must carry a reason: it is the machine-auditable
    # claim that a tool or provider is unavailable, and stale-block detection reads
    # it. Owner gates carry their ask in Blocking:/Why owner:/Unblock: instead, and
    # dependency blocks are validated by the linked-prerequisite check below.
    if tool == 'kanban_block' and args.get('kind') in ('capability', 'transient'):
        reason = str(args.get('reason') or '').strip()
        if not reason:
            return {'action': 'block', 'message':
                    'Every capability/transient block must carry a reason. Record '
                    'the concrete evidence: what is blocked, why, and the recovery route.'}

    if tool == 'kanban_block' and args.get('kind') == 'dependency':
        # Hermes turns a dependency block with no open parent into needs_input.
        # Do not let that fallback manufacture an owner question from evidence
        # missing at the coordinator. A real prerequisite must be linked first.
        board = args.get('board') or os.environ.get('HERMES_KANBAN_BOARD')
        task_id = args.get('task_id') or os.environ.get('HERMES_KANBAN_TASK')
        try:
            if not isinstance(board, str) or not re.fullmatch(r'[A-Za-z0-9_-]+', board) or not task_id:
                raise ValueError('Provide explicit board/task identifiers for the dependency check')
            path = root / 'kanban/boards' / board / 'kanban.db'
            with closing(sqlite3.connect(path.resolve().as_uri() + '?mode=ro', uri=True)) as db:
                db.execute('PRAGMA query_only=ON')
                parent = db.execute("SELECT 1 FROM task_links l JOIN tasks p ON p.id=l.parent_id "
                                    "WHERE l.child_id=? AND p.status NOT IN ('done','archived') LIMIT 1",
                                    (task_id,)).fetchone()
            if not parent:
                raise ValueError('No open prerequisite is linked; Hermes would turn this into needs_input')
        except (ValueError, OSError, sqlite3.Error) as exc:
            return {'action': 'block', 'message':
                    f'Dependency block was not written: {exc}. Record the evidence gap '
                    'and ask the coordinator to link its actual prerequisite; do not ask the owner.'}
    fields = bool(re.search(r'^Blocking:', body, re.M)
                  and re.search(r'^(?:Why owner|Unblock):', body, re.M))
    owner_create = tool == 'kanban_create' and (fields or bool(re.search(r'^\s*ASK:|^Hard Blocker\b', body, re.M | re.I)))
    owner_block = tool == 'kanban_block' and args.get('kind') == 'needs_input'
    owner_comment = tool == 'kanban_comment' and fields
    if tool == 'kanban_comment' and not owner_comment:
        return comment_policy(body, payload.get('profile'))
    if not (owner_create or owner_block or owner_comment):
        return {}
    if payload.get('profile') != PROFILE:
        return {'action': 'block', 'message':
                'Only head-coordinator authors owner-facing blockers. Report technical '
                'evidence to the coordinator and use a technical block or a linked '
                'prerequisite. Do not turn missing evidence into an owner decision.'}
    try:
        board = args.get('board')
        if not isinstance(board, str) or not re.fullmatch(r'[A-Za-z0-9_-]+', board):
            raise ValueError('Provide the explicit board for an owner-facing write')
        if owner_create:
            gate_ok = True
            try:
                if len(body) > alerts.OWNER_GATE_LIMIT or len(body.splitlines()) > alerts.OWNER_GATE_LINES:
                    raise ValueError('Owner gate body is too long; keep the ask and summary concise')
            finally:
                alerts.note_limit_check(root, len(body) <= alerts.OWNER_GATE_LIMIT
                                        and len(body.splitlines()) <= alerts.OWNER_GATE_LINES, 'gate_body')
            task = {'title': args.get('title') or 'Owner gate', 'body': body,
                    'created_by': PROFILE, 'comment': '', 'reason': ''}
        elif owner_comment:
            check_ok = True
            try:
                alerts.check_summary(body)
            except Exception:
                check_ok = False
                raise
            finally:
                # Count even a rejecting check: a kept counter is what tells us
                # whether the 500/1600 caps are tight or rarely engaged.
                alerts.note_limit_check(root, check_ok, 'summary')
            task = {'title': 'Owner gate', 'body': '', 'comment': body, 'reason': ''}
        else:
            task_id = args.get('task_id')
            if not isinstance(task_id, str) or not re.fullmatch(r't_[A-Za-z0-9_]+', task_id):
                raise ValueError('Provide the exact task_id for an owner block')
            tasks = alerts.snapshot(root / 'kanban/boards' / board / 'board.json', task_id)
            if not tasks:
                raise ValueError('Unknown owner-gate task')
            task = {**tasks[0], 'reason': str(args.get('reason') or '')}
        shown, complete = alerts.decision_text('preview', board, task)
        if not complete:
            raise ValueError(shown.splitlines()[-1])
        return {}
    except (ValueError, OSError, sqlite3.Error) as exc:
        return {'action': 'block', 'message':
                f'Owner blocker was not published: {exc}. Write checked Blocking:, '
                'Why owner: and Unblock: lines: the concrete problem naming the specific '
                'function, feature or capability at issue, and the specific owner-only '
                'wall, then the exact recommended action '
                '(prose, or inline A)/B) only for a real either/or).'}


if __name__ == '__main__':
    try:
        spec = importlib.util.spec_from_file_location('owner_alerts', Path(__file__).with_name('kanban-owner-alerts.py'))
        alerts = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(alerts)
        root = Path(os.environ.get('HERMES_ROOT', str(Path.home() / '.hermes')))
        print(json.dumps(guard(json.load(sys.stdin), root, alerts)))
    except (ValueError, TypeError, AttributeError, OSError) as exc:
        print(json.dumps({'action': 'block', 'message': f'Owner authoring check failed closed: {exc}'}))
