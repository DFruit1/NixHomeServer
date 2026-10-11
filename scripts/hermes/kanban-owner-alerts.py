#!/usr/bin/env python3
"""Read-only board polling and owner delivery using Hermes' existing Python/CLI.

This is operations glue, not a new backend or dependency. No board mutation,
approval, subscription or unblock is performed by the unattended job.

The delivery contract is deliberately narrow. The owner's phone receives one
class of message unprompted: a Hard Blocker. A blocked card is a Hard Blocker
when the owner's action is the only way forward -- a card blocked with
`needs_input`, or a card an agent marks with a standalone `Hard Blocker` line
for an owner-only secret, a physical action, or a hard-stuck card with no
agent-side recovery. Both are decisions and cannot clear themselves without the
owner. Every other blocked card (missing evidence, worker/model failures,
dependency waits, routine operator cleanups) is board-local, is never pushed and
is read on demand with `--details blockers`, `--resolve` or the board. An urgent
security or availability regression is not an owner alert: fix it, or roll the
system back, without paging the owner.
"""
import argparse
from contextlib import closing, nullcontext
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shlex
import sqlite3
import subprocess
import sys
import tempfile

PROFILE = 'head-coordinator'
JOB = 'kanban owner blocker alerts'
MARKER = '<!-- kanban-owner-alerts -->'
END_MARKER = '<!-- /kanban-owner-alerts -->'
AUTHOR_MARKER = '<!-- kanban-owner-blocker-author -->'
AUTHOR_END_MARKER = '<!-- /kanban-owner-blocker-author -->'
MESSAGE_LIMIT = 1600
# Bump when the decision message shape changes so the live set is re-sent once in
# the new format (a stale delivered flag would otherwise keep an old stub on the
# phone). Technical messages carry their own format key.
DECISION_FORMAT = 3
# A standalone line an agent adds to mark a card it did not block as a decision.
# Case-insensitive and its own line; prose mentioning it does not count. A card
# carrying it is a Hard Blocker and belongs to the decision (D) category.
HARD_BLOCKER = re.compile(r'^Hard Blocker\b[^\n]*$', re.M | re.I)


def is_hard_blocker(task):
    return task['block_kind'] == 'needs_input' or bool(HARD_BLOCKER.search(task['body'] or ''))


def target_config(root):
    values = {}
    for line in (root / 'profiles' / PROFILE / '.env').read_text().splitlines():
        match = re.fullmatch(r'\s*(SIMPLEX_[A-Z_]+)\s*=\s*(.*?)\s*', line)
        if match:
            values[match[1]] = match[2].strip('"\'')
    home = values.get('SIMPLEX_HOME_CHANNEL', '')
    allowed = values.get('SIMPLEX_ALLOWED_USERS', '').split(',')
    if not re.fullmatch(r'[0-9]+', home) or home not in allowed or not all(re.fullmatch(r'[0-9]+', v) for v in allowed):
        raise ValueError('Owner home channel must be a numeric allowlisted contact')
    if values.get('SIMPLEX_ALLOW_ALL_USERS') or values.get('SIMPLEX_GROUP_ALLOWED'):
        raise ValueError('Owner delivery requires allow-all and group settings absent')
    if not re.fullmatch(r'ws://127\.0\.0\.1:[0-9]+', values.get('SIMPLEX_WS_URL', '')):
        raise ValueError('Use the existing loopback SimpleX daemon')
    return f'simplex:{home}'


def snapshot(board_file, task_id=None):
    with closing(sqlite3.connect((board_file.parent / 'kanban.db').resolve().as_uri() + '?mode=ro', uri=True)) as db:
        db.row_factory = sqlite3.Row
        db.execute('PRAGMA query_only=ON')
        columns = [r[1] for r in db.execute('PRAGMA table_info(tasks)')]
        failure_column = 'last_failure_error' if 'last_failure_error' in columns else 'NULL'
        creator_column = 'created_by' if 'created_by' in columns else 'NULL'
        query = f'SELECT id,title,body,block_kind,status,{failure_column} AS failure,{creator_column} AS created_by FROM tasks WHERE '
        tasks = [dict(r) for r in db.execute(query + ('id=?' if task_id else "status='blocked' ORDER BY id"), (task_id,) if task_id else ())]
        for task in tasks:
            event = db.execute("SELECT id,payload FROM task_events WHERE task_id=? AND (kind='blocked' OR (kind='status' AND json_extract(payload,'$.status')='blocked')) ORDER BY id DESC LIMIT 1", (task['id'],)).fetchone()
            task['event_id'] = event['id'] if event else 0
            task['reason'] = (json.loads(event['payload'] or '{}').get('reason') or '') if event else ''
            failure = task.pop('failure')
            if failure and task['reason'] in ('', 'initial_status'):
                task['reason'] = failure
            # Only the coordinator may author the owner ask. Ordinary comments
            # and summaries from other profiles cannot replace it.
            try:
                comment = db.execute("SELECT body FROM task_comments WHERE task_id=? AND author=? AND instr(body,'Blocking:')>0 ORDER BY created_at DESC, id DESC LIMIT 1", (task['id'], PROFILE)).fetchone()
            except sqlite3.OperationalError:
                comment = None
            task['comment'] = comment['body'] if comment else ''
        return tasks


def owner_summary(comment):
    """The agent-authored plain summary lines in a comment, or ''.

    A comment carrying `Blocking:` / `Why owner:` / `Unblock:` is the owner-facing
    rewrite of a card whose body is internal jargon. Only its presence changes the
    revision, so ordinary coordination comments never re-page the owner.
    """
    if not comment:
        return ''
    end = r'(?=^[A-Z][A-Za-z ]*:|\Z)'
    values = []
    for name in (r'Blocking', r'Why owner', r'Why only owner', r'Why owner-only', r'Unblock', r'Recommended'):
        match = re.search(rf'^{name}:[ \t]*(.*?)' + end, comment, re.M | re.S)
        if match:
            values.append(' '.join(match[1].split()))
    return '\n'.join(values)


def token(value):
    # The owner-facing summary is part of the revision so posting one re-pushes;
    # the raw comment is excluded so unrelated chatter does not.
    # Authorship is checked separately; adding its read-only column must not
    # invalidate an unchanged question's existing label during installation.
    payload = {key: item for key, item in value.items() if key not in ('comment', 'created_by')}
    summary = owner_summary(value.get('comment', ''))
    if summary:
        payload['summary'] = summary
    return hashlib.sha256(json.dumps(payload, sort_keys=True).encode()).hexdigest()


def load_inbox(root):
    path = root / 'kanban/owner-alerts/inbox.json'
    if not path.exists():
        return {'version': 1, 'next_label': 1, 'decisions': {}, 'next_blocker': 1, 'blockers': {}, 'delivery': {}}
    state = json.loads(path.read_text())
    if (not isinstance(state, dict) or state.get('version') != 1
            or type(state.get('next_label')) is not int or state['next_label'] < 1
            or not isinstance(state.get('decisions'), dict) or not isinstance(state.get('delivery'), dict)):
        raise ValueError('Invalid inbox state; restore it instead of reusing decision labels')
    # Add technical labels without changing existing decision IDs or receipts.
    state.setdefault('next_blocker', 1)
    state.setdefault('blockers', {})
    if type(state['next_blocker']) is not int or state['next_blocker'] < 1 or not isinstance(state['blockers'], dict):
        raise ValueError('Invalid blocker mapping; restore inbox state')
    for prefix, records, counter in [('D', state['decisions'], state['next_label']), ('B', state['blockers'], state['next_blocker'])]:
        for label, record in records.items():
            if (not isinstance(record, dict) or not re.fullmatch(prefix + r'[1-9][0-9]*', label) or int(label[1:]) >= counter
                    or not all(k in record for k in ('board', 'task_id', 'token', 'shown', 'compact_complete', 'delivered'))):
                raise ValueError('Invalid label mapping; restore inbox state')
            if (not isinstance(record['board'], str) or not re.fullmatch(r'[a-zA-Z0-9_-]+', record['board'])
                    or not isinstance(record['task_id'], str) or not re.fullmatch(r't_[a-zA-Z0-9_]+', record['task_id'])
                    or not isinstance(record['delivered'], list) or not isinstance(record['shown'], str)
                    or not isinstance(record['compact_complete'], bool) or not isinstance(record['token'], str)):
                raise ValueError('Invalid label record; restore inbox state')
    for delivery in state['delivery'].values():
        if not isinstance(delivery, dict):
            raise ValueError('Invalid delivery record; restore inbox state')
        # State written before the single Hard Blocker category keyed this map as
        # 'urgent'; carry it forward rather than fail closed on old state.
        if 'hard_blocker' not in delivery:
            delivery['hard_blocker'] = delivery.pop('urgent', {})
        if (not isinstance(delivery.get('technical_token'), str)
                or not isinstance(delivery.get('hard_blocker'), dict) or 'technical_at' not in delivery
                or (delivery['technical_at'] is not None and not isinstance(delivery['technical_at'], (int, float)))):
            raise ValueError('Invalid delivery record; restore inbox state')
        if 'technical_format' in delivery and (type(delivery['technical_format']) is not int or delivery['technical_format'] < 0):
            raise ValueError('Invalid technical delivery format; restore inbox state')
        if 'decision_format' in delivery and (type(delivery['decision_format']) is not int or delivery['decision_format'] < 0):
            raise ValueError('Invalid decision delivery format; restore inbox state')
    return state


def inline_options(reason):
    matches = list(re.finditer(r'\b([A-Z])\)\s*', reason))
    options = []
    for index, match in enumerate(matches):
        end = matches[index + 1].start() if index + 1 < len(matches) else len(reason)
        choice = reason[match.end():end]
        choice = re.split(r'\.\s+(?:Details|Context|Evidence)\b', choice)[0]
        choice = re.sub(r'[,;\s]+(?:or|and)\s*$', '', choice).rstrip(' ,;.')
        options.append((match[1], choice))
    return options


def simplex_markdown(text):
    """Render emphasis the way SimpleX parses it.

    SimpleX Chat uses *bold*, _italic_ and ~strike~; GitHub's **bold**, __italic__
    and ~~strike~~ reach the phone as literal marker characters.
    """
    text = re.sub(r'\*\*(.+?)\*\*', r'*\1*', text, flags=re.S)
    text = re.sub(r'__(.+?)__', r'_\1_', text, flags=re.S)
    text = re.sub(r'~~(.+?)~~', r'~\1~', text, flags=re.S)
    return text


def plain(text):
    """Strip machine tokens (task ids, git hashes) from owner-facing text."""
    text = re.sub(r'\bsha256-[A-Za-z0-9+/=]+', '', text)
    text = re.sub(r'\bt_[0-9a-zA-Z_]+', '', text)
    text = re.sub(r'\b[0-9a-f]{7,40}\b', '', text)
    return ' '.join(text.split())


SUMMARY_FIELDS = ('Blocking', 'Why owner', 'Unblock')
SUMMARY_JARGON = re.compile(
    r'\b(?:kanban|card|board|workflow|worktree|needs_input|head-coordinator|'
    r'project-auditor|feature-reviewer|standard-implementer|local-implementer|'
    r'principal-consultant|t_[a-zA-Z0-9_]+|[0-9a-f]{7,40})\b', re.I)
SUMMARY_PLACEHOLDER = re.compile(
    r'\b(?:inspect details|see details|ask for details|reply with your answer|'
    r'only you can clear this|cannot self-resolve|choose A or B)\b', re.I)


def check_summary(text):
    """Check the coordinator's three lines; never invent an owner-only reason."""
    lines = text.strip().splitlines()
    if len(lines) != 3 or any(not line.startswith(name + ': ') for name, line in zip(SUMMARY_FIELDS, lines)):
        raise ValueError('Write exactly Blocking:, Why owner:, Unblock: in that order')
    if len(text.strip()) > 1000 or any(len(line) > 90 for line in lines):
        raise ValueError('Blocker summary exceeds 90 characters per line or 1000 total')
    fields = {}
    for name, line in zip(SUMMARY_FIELDS, lines):
        value = line[len(name) + 2:].strip()
        if not value or SUMMARY_JARGON.search(value) or SUMMARY_PLACEHOLDER.search(value):
            raise ValueError(f'{name}: supply a concrete plain-English problem, reason or action')
        fields[name] = value
    return fields


def blocker_summary(task):
    # A summary is an atomic statement of the current ask. Never mix a partial
    # comment with an old body, or attach the old body's choices to a new ask.
    comment = task.get('comment') or ''
    if comment:
        source = comment
    elif task.get('created_by') == PROFILE:
        source = task.get('body') or ''
    else:
        raise ValueError('head-coordinator must author the owner-facing summary')
    lines = [line for line in source.splitlines()
             if any(line.startswith(name + ':') for name in SUMMARY_FIELDS)]
    return check_summary('\n'.join(lines))


def decision_text(label, board, task):
    """Render only the coordinator's checked owner-facing summary."""
    heading = f'{label} · {board}\n' + plain(' '.join(task['title'].split()))[:80]
    try:
        fields = blocker_summary(task)
    except ValueError as exc:
        return heading + f'\nCoordinator must repair blocker text: {exc}', False
    lines = [f'Blocking: {fields["Blocking"]}', f'Why owner: {fields["Why owner"]}',
             f'Recommended: {fields["Unblock"]}']
    # Body choices are retained only when that same body supplied the summary.
    # A coordinator comment replaces the whole owner ask, including its options.
    if not task.get('comment'):
        end = r'(?=^\s*[A-Z]\)|^[A-Za-z][A-Za-z ]*:|\Z)'
        options = re.findall(r'^\s*([A-Z])\)[ \t]*(.*?)' + end,
                             task.get('body') or '', re.M | re.S)
        reason_options = inline_options(task.get('reason') or '')
        normalized = [(letter, ' '.join(value.split()).rstrip(' ,;.')) for letter, value in options]
        if reason_options and normalized != reason_options:
            return heading + '\nCoordinator must repair conflicting approval choices.', False
        if options:
            if len({letter for letter, _ in options}) != len(options):
                return heading + '\nCoordinator must repair duplicate approval choices.', False
            choices = [f'{letter}) {" ".join(value.split())}' for letter, value in options]
            if any(len(choice) > 90 or SUMMARY_JARGON.search(choice) for choice in choices):
                return heading + '\nCoordinator must shorten and explain approval choices.', False
            lines.append('Choices:')
            lines.extend(choices)
    if len('\n'.join(lines)) > 1000:
        return heading + '\nCoordinator must shorten the owner-facing summary.', False
    return heading + '\n' + '\n'.join(lines), True


def resolve(root, label):
    state = load_inbox(root)
    label = label.upper()
    technical = label.startswith('B')
    records = state['blockers'] if technical else state['decisions']
    if label not in records:
        raise ValueError(f'Unknown label {label}; do not guess its card')
    decision = records[label]
    tasks = snapshot(root / 'kanban/boards' / decision['board'] / 'board.json', decision['task_id'])
    current = tasks[0] if tasks else None
    complete = decision_text(label, decision['board'], current)[1] if current and not technical else False
    # A decision is answerable whenever the ask is still live and unchanged: the
    # owner is authenticated and reaches decisions from the board, so an
    # undelivered label is the normal case rather than a staleness signal. A
    # technical label still needs evidence the owner actually saw that card,
    # because recovery instructions there are authority to unblock.
    return {'label': label, **decision, 'kind': 'technical' if technical else 'decision', 'current': current,
            'can_reply': bool(current and current['status'] == 'blocked'
                              and ((current['block_kind'] != 'needs_input'
                                    and target_config(root) in decision['delivered'])
                                   if technical else
                                   (is_hard_blocker(current)
                                    and complete
                                    and token(current) == decision['token'])))}


def details(root, label):
    if label.lower() == 'blockers':
        entries = []
        state = load_inbox(root)
        for board in sorted((root / 'kanban/boards').glob('*/board.json')):
            if not board.parent.name.startswith('_'):
                for task in snapshot(board):
                    if is_hard_blocker(task):
                        continue
                    alias = next((alias for alias, record in state['blockers'].items()
                                  if (record['board'], record['task_id']) == (board.parent.name, task['id'])), 'Unlabelled')
                    entries.append(f"{alias} · {board.parent.name}:{task['id']} · {task['title']}\nBlock reason: {task['reason']}")
        return '\n\n'.join(entries) or 'No technical blockers.'
    if re.fullmatch(r'[a-zA-Z0-9_-]+:t_[a-zA-Z0-9_]+', label):
        board, task_id = label.split(':')
        tasks = snapshot(root / 'kanban/boards' / board / 'board.json', task_id)
        if not tasks:
            raise ValueError('Unknown board/card')
        task = tasks[0]
        return f"{label} · {task['status']} · {task['title']}\n{task['body'] or ''}\nBlock reason: {task['reason']}"
    decision = resolve(root, label)
    current = decision['current']
    return (f"{decision['label']} · {decision['board']} {decision['task_id']}\n"
            + (('Technical blocker; recovery instructions are not approval.' if decision['kind'] == 'technical' else 'Current question.')
               if decision['can_reply'] else 'Stale, closed or undelivered item; do not act on this label.')
            + f"\nShown:\n{decision['shown']}\nCurrent card:\n"
            + (f"{current['status']} · {current['title']}\n{current['body'] or ''}\nBlock reason: {current['reason']}" if current else 'Card no longer exists.'))


def send(root, target, text):
    env = os.environ.copy()
    env['HERMES_HOME'] = str(root)
    result = subprocess.run(['hermes', '--profile', PROFILE, 'send', '--to', target,
                             '--file', '-', '--json'], input=text, text=True,
                            capture_output=True, check=True, timeout=60, env=env)
    if json.loads(result.stdout).get('success') is not True:
        raise RuntimeError('SimpleX delivery did not acknowledge success')


def save(path, state):
    fd, temporary = tempfile.mkstemp(dir=path.parent, prefix='.state-')
    try:
        with os.fdopen(fd, 'w') as stream:
            json.dump(state, stream)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def technical_category(task):
    reason = task['reason'].lower()
    if reason in ('', 'initial_status'):
        reason = (task['body'] or '').lower()
        if re.search(r'operator.only|operator cleanup', reason):
            return 'operator action'
    if re.search(r'model|unresponsive|provider|rate.limit', reason):
        return 'worker failures'
    if re.search(r'evidence|artifact|receipt|worktree', reason):
        return 'missing evidence'
    if re.search(r'operator|cleanup|credential|permission', reason):
        return 'operator action'
    return 'execution problems'


def technical_text(label, board, task):
    causes = {'worker failures': 'Worker/model unavailable', 'missing evidence': 'Missing evidence',
              'operator action': 'Operator recovery needed', 'execution problems': 'Execution problem; inspect details'}
    return f'{label} · {board}\n' + ' '.join(task['title'].split())[:80] + '\nBlocked: ' + causes[technical_category(task)]


def batches_for(shown, order, heading=0):
    """Split a label sequence into messages that fit a phone screen."""
    batches, batch, size = [], [], heading
    for label in order:
        if batch and size + len(shown[label]) + 2 > MESSAGE_LIMIT - 120:
            batches.append(batch)
            batch, size = [], heading
        batch.append(label)
        size += len(shown[label]) + 2
    if batch:
        batches.append(batch)
    return batches


def decision_messages(labels, state):
    """Batch the current decision set, used only for an explicit owner request."""
    order = sorted(labels)
    shown = {label: state['decisions'][label]['shown'] for label in order}
    heading = '*Hard Blocker*\n'
    # An empty set answers the request rather than staying silent: the owner
    # asked, so "nothing waiting" is the reply.
    batches = batches_for(shown, order, len(heading)) or [[]]
    return [(heading + '\n' + '\n\n'.join(shown[label] for label in batch)
             + (f'\n\nReply: {batch[0]} <choice or answer>. Details: {batch[0]} details'
                if batch else '\nNo decisions are waiting.'), batch)
            for batch in batches]


def collect(root, state, errors):
    """Read every active board and refresh labels and their snapshots.

    Read-only against the boards; only the local inbox state changes. Returns
    the technical cards, their labels, the decision labels, the decision cards
    and whether any board could not be read, because a partial read must never
    be delivered as a complete answer.
    """
    technical, technical_labels, decision_labels, decisions = [], {}, {}, []
    snapshot_failed = False
    for board in sorted((root / 'kanban/boards').glob('*/board.json')):
        if board.parent.name.startswith('_'):
            continue
        try:
            for task in snapshot(board):
                if not is_hard_blocker(task):
                    technical.append((board.parent.name, task))
                    label = next((label for label, record in state['blockers'].items()
                                  if (record['board'], record['task_id']) == (board.parent.name, task['id'])), None)
                    if label is None:
                        label = f'B{state["next_blocker"]}'
                        state['next_blocker'] += 1
                        state['blockers'][label] = {'board': board.parent.name, 'task_id': task['id'],
                                                   'compact_complete': False, 'delivered': []}
                    state['blockers'][label].update(token=token(task), shown=technical_text(label, board.parent.name, task))
                    technical_labels[(board.parent.name, task['id'])] = label
                    continue
                decisions.append((board.parent.name, task))
                revision = token(task)
                label = next((label for label, d in state['decisions'].items()
                              if (d['board'], d['task_id'], d['token']) == (board.parent.name, task['id'], revision)), None)
                if label is None:
                    label = f'D{state["next_label"]}'
                    state['next_label'] += 1
                    state['decisions'][label] = {'board': board.parent.name, 'task_id': task['id'],
                        'token': revision, 'shown': '', 'compact_complete': False, 'delivered': []}
                # Refresh every tick so a message-format change reaches the live
                # set without minting a new label for an unchanged card.
                shown, complete = decision_text(label, board.parent.name, task)
                state['decisions'][label]['shown'] = shown
                state['decisions'][label]['compact_complete'] = complete
                decision_labels[(board.parent.name, task['id'])] = label
                if not complete:
                    errors.append(f'{board.parent.name}:{task["id"]}: {shown.splitlines()[-1]}')
                    snapshot_failed = True
        except (ValueError, OSError, sqlite3.Error) as exc:
            errors.append(f'{board.parent.name}: {exc}')
            snapshot_failed = True
    return technical, technical_labels, decision_labels, decisions, snapshot_failed


def tick(root, dry_run=False, now=None, force_decisions=False):
    target = target_config(root)
    if not dry_run and (os.environ.get('HERMES_DELEGATED_CHILD_CONTEXT') or os.environ.get('HERMES_KANBAN_TASK')):
        raise PermissionError('Owner alerts run only from the operator or no-agent cron')
    directory = root / 'kanban/owner-alerts'
    if not dry_run:
        directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    errors = []
    # Preview creates neither a state directory nor a lock file.
    with ((directory / '.lock').open('a') if not dry_run else nullcontext()) as lock:
        if lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
        path = directory / 'inbox.json'
        state = load_inbox(root)
        state['delivery'].setdefault(target, {'technical_token': '', 'technical_at': None, 'hard_blocker': {}})
        delivery = state['delivery'][target]
        if delivery.get('decision_format') != DECISION_FORMAT:
            # One-time format migration: re-send the live decision set so a stale
            # "Details required" stub does not stay on the phone.
            for record in state['decisions'].values():
                record['delivered'] = []
            delivery['decision_format'] = DECISION_FORMAT
        _, _, decision_labels, decisions, snapshot_failed = collect(root, state, errors)
        if not dry_run:
            save(path, state)  # Labels survive a failed send or a process restart.

        def deliver(text):
            text = simplex_markdown(text)
            if dry_run:
                print(text)
                return True
            try:
                send(root, target, text)
                return True
            except (ValueError, OSError, RuntimeError, subprocess.SubprocessError) as exc:
                errors.append(f'Delivery: {exc}')
                return False

        def delivered(records, labels):
            if not dry_run:
                for label in labels:
                    if target not in records[label]['delivered']:
                        records[label]['delivered'].append(target)
                save(path, state)

        # The one owner-facing category is a decision gate: a card blocked with
        # `needs_input`, which only the owner can clear and which the board will
        # not unblock on its own. A technical blocker can clear itself, so it is
        # never sent; it stays board-local and is read with `--details blockers`.
        pending = [decision_labels[(board, task['id'])] for board, task in decisions
                   if state['decisions'][decision_labels[(board, task['id'])]]['compact_complete']
                   and target not in state['decisions'][decision_labels[(board, task['id'])]]['delivered']]
        if pending:
            heading = '*Hard Blocker*\n'
            shown = {label: state['decisions'][label]['shown'] for label in pending}
            for batch in batches_for(shown, pending, len(heading)):
                text = (heading + '\n' + '\n\n'.join(shown[label] for label in batch)
                        + f'\n\nReply: {batch[0]} <choice or answer>. Details: {batch[0]} details')
                if deliver(text):
                    delivered(state['decisions'], batch)

        # Explicit pull of the decision set only. A failed board read omits
        # cards, so an incomplete list is never sent as if it were whole.
        if force_decisions and not snapshot_failed:
            for text, batch in decision_messages(decision_labels.values(), state):
                if not deliver(text):
                    continue
                if batch:
                    delivered(state['decisions'], batch)
    if errors:
        raise RuntimeError('; '.join(errors))


def install(root):
    source = Path(__file__).resolve().parent
    target_config(root)
    scripts = root / 'scripts'
    policy = (source / 'taskforce/owner-alert-replies.md').read_text()
    soul = root / 'profiles' / PROFILE / 'SOUL.md'
    existing = soul.read_text()
    block = MARKER + '\n' + policy + END_MARKER + '\n'
    if MARKER not in existing:
        wanted = existing.rstrip() + '\n\n' + block
    elif END_MARKER in existing:
        wanted, count = re.subn(re.escape(MARKER) + r'.*?' + re.escape(END_MARKER) + r'\n?',
                               lambda _: block, existing, flags=re.S)
        if count != 1:
            raise ValueError('Duplicate owner alert policy sections')
    elif existing.endswith(MARKER + '\n' + policy):
        wanted = existing[:-len(MARKER + '\n' + policy)] + block
    else:
        raise ValueError('Unrecognised owner alert policy; preserve and reconcile it')
    changes = {soul: wanted, scripts / 'kanban-owner-alerts.py': Path(__file__).read_text(),
               scripts / 'owner-blocker-authoring-guard.py': (source / 'owner-blocker-authoring-guard.py').read_text(),
               scripts / 'review-taskforce-approval.md': (source / 'taskforce/approval-policy.md').read_text()}
    spec = importlib.util.spec_from_file_location('steward_installer', source / 'install-steward-readonly.py')
    installer = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(installer)
    author_policy = (source / 'taskforce/owner-blocker-authoring.md').read_text()
    author_block = AUTHOR_MARKER + '\n' + author_policy + AUTHOR_END_MARKER + '\n'
    for profile_soul in sorted((root / 'profiles').glob('*/SOUL.md')):
        text = changes.get(profile_soul, profile_soul.read_text())
        if AUTHOR_MARKER in text:
            text, count = re.subn(re.escape(AUTHOR_MARKER) + r'.*?' + re.escape(AUTHOR_END_MARKER) + r'\n?',
                                 lambda _: author_block, text, flags=re.S)
            if count != 1:
                raise ValueError(f'Invalid blocker authorship section in {profile_soul}')
        else:
            text = text.rstrip() + '\n\n' + author_block
        changes[profile_soul] = text
        config = profile_soul.with_name('config.yaml')
        if config.exists():
            command = shlex.join(['python3', str(scripts / 'owner-blocker-authoring-guard.py')])
            text = installer.readonly_hook(config.read_text(), command, 'owner-blocker-author',
                                           '^kanban_(create|block|comment)$')
            changes[config] = installer.replace_setting(text, 'hooks_auto_accept', 'true')
    jobs = json.loads((root / 'cron/jobs.json').read_text()).get('jobs', [])
    matching = [job for job in jobs if job.get('name') == JOB]
    if matching and (len(matching) != 1 or matching[0].get('script') != 'kanban-owner-alerts.py'
                    or not matching[0].get('no_agent') or matching[0].get('schedule', {}).get('minutes') != 1):
        raise ValueError('Owner alert cron drift; repair the existing job instead of duplicating it')
    # Validate every policy transformation and cron before installing anything.
    for path, text in changes.items():
        if path.exists() and path.read_text() == text:
            continue
        if path.exists():
            backup = root / 'backups/owner-alerts'
            backup.mkdir(parents=True, exist_ok=True, mode=0o700)
            copy = backup / (hashlib.sha256(path.read_bytes()).hexdigest() + '.md')
            if not copy.exists():
                copy.write_bytes(path.read_bytes())
                copy.chmod(0o600)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
    (scripts / 'kanban-owner-alerts.py').chmod(0o700)
    if not matching:
        env = os.environ.copy()
        env['HERMES_HOME'] = str(root)
        subprocess.run(['hermes', '--profile', 'default', 'cron', 'create', 'every 1m',
                        '--name', JOB, '--script', 'kanban-owner-alerts.py', '--no-agent',
                        '--deliver', 'local', '--workdir', str(source.parent.parent),
                        '--paused', '--paused-reason', 'Validate owner alerts before activation'], check=True, env=env)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    actions = parser.add_mutually_exclusive_group()
    actions.add_argument('--dry-run', action='store_true')
    actions.add_argument('--install', action='store_true')
    actions.add_argument('--send-decisions', action='store_true', help='Send the current decision questions now')
    actions.add_argument('--resolve', metavar='D1|B1', help='Read exact label mapping and current validity as JSON')
    actions.add_argument('--details', metavar='D1|B1|blockers|board:card', help='Read requested diagnostics without sending or mutating')
    actions.add_argument('--check-summary', metavar='FILE|-', help='Check the coordinator summary without sending or mutating; - reads stdin')
    actions.add_argument('--check-blockers', action='store_true', help='Check all current owner blockers without sending or mutating')
    args = parser.parse_args()
    root = Path(os.environ.get('HERMES_ROOT', str(Path.home() / '.hermes')))
    try:
        if args.check_summary:
            check_summary(sys.stdin.read() if args.check_summary == '-' else Path(args.check_summary).read_text())
            print('Blocker summary OK')
        elif args.check_blockers:
            errors = []
            collect(root, load_inbox(root), errors)
            if errors:
                raise ValueError('; '.join(errors))
            print('Owner blocker summaries OK')
        elif args.resolve:
            print(json.dumps(resolve(root, args.resolve)))
        elif args.details:
            print(details(root, args.details))
        elif args.install:
            install(root)
        else:
            tick(root, args.dry_run, force_decisions=args.send_decisions)
    except (ValueError, OSError, RuntimeError, sqlite3.Error, subprocess.SubprocessError) as exc:
        print(f'owner alerts: {exc}', file=sys.stderr)
        sys.exit(2)
