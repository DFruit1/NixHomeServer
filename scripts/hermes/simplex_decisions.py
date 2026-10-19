#!/usr/bin/env python3
"""Maintain the coordinator's current-decisions SimpleX group as a live ledger.

The owner's general SimpleX chat is a conversation. This module keeps owner
decisions in a separate group so the group can read as *current state* instead
of an accumulating transcript: every open decision has exactly one message, the
message is edited when its wording changes, and it is deleted as soon as the
decision is answered, revised or closed.

Two writers share the group without overwriting each other:

* ``reconcile`` owns keys prefixed ``alert:``. The five-minute owner-alert
  sender calls it with the complete current decision set, so it adds new
  decisions, edits changed ones and deletes any ``alert:`` message that is no
  longer live.
* The CLI's ``post``/``edit``/``delete`` commands own every other key. The
  coordinator uses them for status or context that is not an alert-managed
  gate. ``reconcile`` never touches those keys.

The ledger records the SimpleX item id returned by the daemon, because an edit
or delete needs the original item id. State is written atomically under a lock,
so a crash cannot duplicate a decision or lose a known id.

Run it with the Hermes bundled Python (see ``simplex-decisions.sh``), which
makes the vendored ``websockets`` importable. Outbound-only, loopback-only.
"""

from __future__ import annotations

import argparse
import asyncio
import fcntl
import hashlib
import json
import os
import re
import sys
import tempfile
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path
from typing import Protocol

PROFILE = 'head-coordinator'
STATE_VERSION = 1
ALERT_PREFIX = 'alert:'
DEFAULT_WS = 'ws://127.0.0.1:5225'
KEY_PATTERN = re.compile(r'[A-Za-z0-9][A-Za-z0-9._-]{0,63}')
# Alert labels and technical diagnostics already have a stable namespace. A
# manual key must not look like one, or reconcile would delete it as stale.
RESERVED_KEY = re.compile(r'^(?:[DB][0-9]+|alert:)', re.I)


class RpcError(RuntimeError):
    pass


class ItemGone(RpcError):
    """The target item no longer exists, so an edit must recreate it."""


def env_values(root):
    values = {}
    path = root / 'profiles' / PROFILE / '.env'
    if not path.exists():
        return values
    for line in path.read_text().splitlines():
        match = re.fullmatch(r'\s*(SIMPLEX_[A-Z_]+)\s*=\s*(.*?)\s*', line)
        if match:
            values[match[1]] = match[2].strip('"\'')
    return values


def configured_group(root):
    """Return the decision group id, or None when the channel is not wired.

    Fail closed on ambiguous wiring: a group allowlist that is wider than the
    one decision group would also admit unrelated group traffic into the
    coordinator profile.
    """
    values = env_values(root)
    raw = values.get('SIMPLEX_DECISION_GROUP', '').strip()
    allowed = [value.strip() for value in values.get('SIMPLEX_GROUP_ALLOWED', '').split(',') if value.strip()]
    if not raw:
        if allowed:
            raise ValueError('SIMPLEX_GROUP_ALLOWED requires SIMPLEX_DECISION_GROUP')
        return None
    if not re.fullmatch(r'[0-9]+', raw):
        raise ValueError('SIMPLEX_DECISION_GROUP must be a numeric SimpleX group id')
    if allowed and set(allowed) != {raw}:
        raise ValueError('SIMPLEX_GROUP_ALLOWED must contain only the decision group id')
    return int(raw)


def ws_url(root):
    values = env_values(root)
    url = values.get('SIMPLEX_WS_URL', '') or DEFAULT_WS
    if not re.fullmatch(r'ws://127\.0\.0\.1:[0-9]+', url):
        raise ValueError('Use the existing loopback SimpleX daemon for the decision channel')
    return url


def state_path(root):
    return root / 'kanban' / 'owner-alerts' / 'decision-messages.json'


def _empty_state():
    return {'version': STATE_VERSION, 'group': None, 'messages': {}}


def load_state(path):
    if not path.exists():
        return _empty_state()
    state = json.loads(path.read_text())
    if (not isinstance(state, dict) or state.get('version') != STATE_VERSION
            or not isinstance(state.get('messages'), dict)
            or state.get('group') is not None and type(state['group']) is not int):
        raise ValueError('Invalid decision-channel state; restore it instead of reusing item ids')
    for key, record in state['messages'].items():
        if (not isinstance(key, str) or not isinstance(record, dict)
                or type(record.get('item_id')) is not int or record['item_id'] < 1
                or not isinstance(record.get('text'), str)):
            raise ValueError('Invalid decision-channel message record; restore the state file')
    return state


def save_state(path, state):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, temporary = tempfile.mkstemp(dir=path.parent, prefix='.decisions-')
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, 'w') as stream:
            json.dump(state, stream, indent=1, sort_keys=True)
            stream.write('\n')
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


@contextmanager
def locked(root):
    directory = root / 'kanban' / 'owner-alerts'
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    with (directory / '.decisions.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        yield


def markdown(text):
    """Convert GitHub emphasis to SimpleX markup, matching the alert sender."""
    text = re.sub(r'\*\*(.+?)\*\*', r'*\1*', text, flags=re.S)
    return re.sub(r'__(.+?)__', r'_\1_', text, flags=re.S)


class Transport(Protocol):
    def send(self, group: int, text: str) -> int: ...
    def update(self, group: int, item_id: int, text: str) -> None: ...
    def delete(self, group: int, item_id: int) -> None: ...


def load_websockets(root=None):
    """Import websockets, bootstrapping the Hermes runtime when needed.

    The bundled Python (and a bare ``python3``) does not expose the vendored
    ``websockets`` on the default path; ``hermes_bootstrap`` adds it, exactly as
    ``simplex_send_group.py`` does.
    """
    try:
        import websockets
        return websockets
    except ImportError:
        pass
    home = Path(root) if root else Path(os.environ.get('HERMES_ROOT', str(Path.home() / '.hermes')))
    os.environ.setdefault('HERMES_HOME', str(home))
    agent = str(home / 'hermes-agent')
    if agent not in sys.path:
        sys.path.insert(0, agent)
    import hermes_bootstrap  # noqa: E402,F401
    import websockets  # noqa: E402
    return websockets


class DaemonTransport:
    """One shot per operation against the local simplex-chat WebSocket API."""

    def __init__(self, url, home=None):
        self.url = url
        self.home = home

    def _call(self, command):
        websockets = load_websockets(self.home)

        async def call():
            corr = hashlib.sha256(command.encode()).hexdigest()[:24]
            async with websockets.connect(self.url, max_size=None) as ws:
                await ws.send(json.dumps({'corrId': corr, 'cmd': command}))
                while True:
                    message = json.loads(await asyncio.wait_for(ws.recv(), timeout=15))
                    if message.get('corrId') == corr:
                        return message.get('resp') or {}
                    # Async events share the socket; ignore everything else.

        return asyncio.run(call())

    @staticmethod
    def _error(resp):
        error = (resp.get('chatError') or {}).get('errorType') or {}
        return error.get('message') or resp.get('type') or 'unknown SimpleX error'

    def send(self, group, text):
        items = [{'msgContent': {'type': 'text', 'text': markdown(text)}}]
        resp = self._call(f'/_send #{group} json {json.dumps(items)}')
        if resp.get('type') != 'newChatItems':
            raise RpcError(self._error(resp))
        items = resp.get('chatItems') or []
        if isinstance(items, dict):
            items = [items]
        for item in items:
            item_id = ((item.get('chatItem') or {}).get('meta') or {}).get('itemId')
            if type(item_id) is int:
                return item_id
        raise RpcError('SimpleX did not return the sent item id')

    def update(self, group, item_id, text):
        updated = {'msgContent': {'type': 'text', 'text': markdown(text)}, 'mentions': {}}
        resp = self._call(f'/_update item #{group} {item_id} json {json.dumps(updated)}')
        if resp.get('type') in ('chatItemUpdated', 'chatItemNotChanged'):
            return
        message = self._error(resp).lower()
        if 'not found' in message or 'no chat item' in message or 'invalidchatitemupdate' in message:
            raise ItemGone(message)
        raise RpcError(self._error(resp))

    def delete(self, group, item_id):
        resp = self._call(f'/_delete item #{group} {item_id} broadcast')
        if resp.get('type') == 'chatItemsDeleted':
            return
        message = self._error(resp).lower()
        if 'not found' in message or 'no chat item' in message:
            return
        raise RpcError(self._error(resp))


def _upsert(state, transport, group, key, text):
    """Send, edit or leave one ledger message. Returns True on a state change."""
    record = state['messages'].get(key)
    if record is None:
        item_id = transport.send(group, text)
        state['messages'][key] = {'item_id': item_id, 'text': text,
                                  'updated_at': datetime.now(timezone.utc).isoformat()}
        return True
    # Verify every live message, not only changed ones: a member may have
    # deleted a decision in SimpleX, and the ledger must recreate it instead of
    # pretending the channel still shows it. ``chatItemNotChanged`` is a no-op.
    try:
        transport.update(group, record['item_id'], text)
    except ItemGone:
        # The message was deleted outside the ledger; replace it rather than
        # leaving the decision unrepresented.
        item_id = transport.send(group, text)
        state['messages'][key] = {'item_id': item_id, 'text': text,
                                  'updated_at': datetime.now(timezone.utc).isoformat()}
        return True
    if record['text'] == text:
        return False
    record['text'] = text
    record['updated_at'] = datetime.now(timezone.utc).isoformat()
    return True


def reconcile(root, live, transport=None, dry_run=False):
    """Make the alert-owned messages exactly match ``live``.

    ``live`` maps keys (normally ``alert:D1``) to message bodies. Only keys under
    the alert namespace are removed when absent, so coordinator-authored
    messages survive an alert tick. A partial board read must not call this with
    an incomplete set, or it would delete live decisions.
    """
    group = configured_group(root)
    if group is None:
        raise ValueError('Decision channel is not configured; install it first')
    transport = transport or DaemonTransport(ws_url(root), home=root)
    path = state_path(root)
    errors = []
    with locked(root):
        state = load_state(path)
        if state.get('group') not in (None, group):
            raise ValueError('Decision-channel state belongs to another group; reconcile it first')
        state['group'] = group
        alert_keys = {key for key in state['messages'] if key.startswith(ALERT_PREFIX)}
        for key, text in live.items():
            if not key.startswith(ALERT_PREFIX):
                raise ValueError('reconcile only manages alert-owned keys')
            if dry_run:
                print(f'[decision-group] upsert {key}:\n{text}\n')
                continue
            try:
                if _upsert(state, transport, group, key, text):
                    save_state(path, state)
            except (OSError, RpcError, ValueError) as exc:
                errors.append(f'{key}: {exc}')
        if not dry_run:
            save_state(path, state)
        for key in sorted(alert_keys - set(live)):
            if dry_run:
                print(f'[decision-group] delete {key}')
                continue
            record = state['messages'].get(key)
            if record is None:
                continue
            try:
                transport.delete(group, record['item_id'])
                del state['messages'][key]
                save_state(path, state)
            except (OSError, RpcError, ValueError) as exc:
                errors.append(f'{key}: {exc}')
    return errors


def validate_key(key):
    key = key.strip()
    if not KEY_PATTERN.fullmatch(key) or RESERVED_KEY.match(key):
        raise ValueError('Use a short key that does not look like an alert label (D1/B1) or start with alert:')
    return key


def _manual_transport(root):
    return DaemonTransport(ws_url(root), home=root)


def post(root, key, text, transport=None, replace=False):
    key = validate_key(key)
    group = configured_group(root)
    if group is None:
        raise ValueError('Decision channel is not configured; install it first')
    if not text.strip():
        raise ValueError('Refusing to post an empty decision')
    transport = transport or _manual_transport(root)
    path = state_path(root)
    with locked(root):
        state = load_state(path)
        if state.get('group') not in (None, group):
            raise ValueError('Decision-channel state belongs to another group; reconcile it first')
        state['group'] = group
        if key in state['messages']:
            if not replace:
                raise ValueError(f'{key} already has a message; use edit')
            transport.delete(group, state['messages'][key]['item_id'])
        item_id = transport.send(group, text.strip())
        state['messages'][key] = {'item_id': item_id, 'text': text.strip(),
                                  'updated_at': datetime.now(timezone.utc).isoformat()}
        save_state(path, state)
    return item_id


def edit(root, key, text, transport=None):
    key = validate_key(key)
    group = configured_group(root)
    if group is None:
        raise ValueError('Decision channel is not configured; install it first')
    if not text.strip():
        raise ValueError('Refusing to edit a decision to empty text; delete it instead')
    transport = transport or _manual_transport(root)
    path = state_path(root)
    with locked(root):
        state = load_state(path)
        if state.get('group') not in (None, group):
            raise ValueError('Decision-channel state belongs to another group; reconcile it first')
        record = state['messages'].get(key)
        if record is None:
            raise ValueError(f'{key} has no message; use post first')
        transport.update(group, record['item_id'], text.strip())
        record['text'] = text.strip()
        record['updated_at'] = datetime.now(timezone.utc).isoformat()
        save_state(path, state)


def delete(root, key, transport=None):
    key = validate_key(key)
    group = configured_group(root)
    if group is None:
        raise ValueError('Decision channel is not configured; install it first')
    transport = transport or _manual_transport(root)
    path = state_path(root)
    with locked(root):
        state = load_state(path)
        if state.get('group') not in (None, group):
            raise ValueError('Decision-channel state belongs to another group; reconcile it first')
        record = state['messages'].get(key)
        if record is None:
            return False
        transport.delete(group, record['item_id'])
        del state['messages'][key]
        save_state(path, state)
    return True


def listing(root):
    state = load_state(state_path(root))
    return sorted(state['messages'].items())


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true', help='Validate local decision-channel wiring without sending')
    parser.add_argument('--list', action='store_true', help='List ledger keys and their first line')
    sub = parser.add_subparsers(dest='command')
    for name, help_text in (('post', 'Send a new decision message (stdin)'),
                            ('edit', 'Edit an existing decision message (stdin)'),
                            ('delete', 'Delete an existing decision message')):
        command = sub.add_parser(name, help=help_text)
        command.add_argument('key')
        command.add_argument('--replace', action='store_true', help=argparse.SUPPRESS)
    args = parser.parse_args(argv)
    root = Path(os.environ.get('HERMES_ROOT', str(Path.home() / '.hermes')))

    try:
        if args.check:
            group = configured_group(root)
            if group is None:
                raise ValueError('SIMPLEX_DECISION_GROUP is not set')
            ws_url(root)
            print(f'Decision channel OK: group {group}')
            return 0
        if args.list:
            for key, record in listing(root):
                first = record['text'].splitlines()[0] if record['text'] else ''
                print(f'{key}\t{record["item_id"]}\t{first[:100]}')
            return 0
        if args.command in ('post', 'edit'):
            text = sys.stdin.read()
            if args.command == 'post':
                item_id = post(root, args.key, text, replace=args.replace)
                print(f'Posted {args.key} as item {item_id}')
            else:
                edit(root, args.key, text)
                print(f'Edited {args.key}')
            return 0
        if args.command == 'delete':
            print(f'Deleted {args.key}' if delete(root, args.key) else f'{args.key} was already absent')
            return 0
        parser.print_help()
        return 2
    except (OSError, ValueError, RpcError) as exc:
        print(f'simplex-decisions: {exc}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
