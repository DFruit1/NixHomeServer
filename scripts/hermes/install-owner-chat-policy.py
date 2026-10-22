#!/usr/bin/env python3
"""Stop native lifecycle notifications to the owner's private SimpleX chat.

Python operations glue uses Hermes' existing config/subscription CLI; no new
backend or dependency. The separate Hard Blocker sender keeps its own state.

Run after restoring/upgrading Hermes: python3 scripts/hermes/install-owner-chat-policy.py
python3 scripts/hermes/install-owner-chat-policy.py --check   # report drift only
HERMES_ROOT overrides the installation root. Refresh an idle coordinator's
gateway profile afterwards so cached identity includes the updated policy.
"""
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys

import hermes_common

MARKER = '<!-- owner-private-chat-policy -->'
END_MARKER = '<!-- /owner-private-chat-policy -->'
POLICY = '''## Private owner chat: quiet by default

The owner has explicitly forbidden unsolicited files, done updates, progress
reports, self-improvement updates and temporary/technical blocker notices in
their private SimpleX chat. Keep those on the board. Do not send attachments,
logs, plans or reports unless the owner explicitly requests that exact content.
Only a Hard Blocker requiring the owner's action may be pushed, through the
existing owner-alert sender. Never send a duplicate manual alert.
Reply briefly to a direct owner request, limited to what they asked for.
Do not create or restore private-chat kanban notification subscriptions,
including notify+wake or wake-only subscriptions. A lifecycle event is not an
owner request and must not prompt a message to the owner.
Use board dependencies and internal channels for coordination. Disabling
auto-subscribe is intentional; never work around it with manual subscriptions.
'''


def instructions_module():
    spec = importlib.util.spec_from_file_location('instructions',
        Path(__file__).with_name('install-instruction-policy.py'))
    instructions = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(instructions)
    return instructions


def wanted_soul(root):
    soul = root / 'profiles/head-coordinator/SOUL.md'
    return soul, instructions_module().block(soul.read_text(), MARKER, END_MARKER, POLICY)


def owner_board_rows(root, owner):
    """Yield (board, row) for every simplex subscription to the owner chat."""
    env = {**os.environ, 'HERMES_HOME': str(root)}
    for board in sorted((root / 'kanban/boards').glob('*/board.json')):
        if board.parent.name.startswith('_'):
            continue
        command = ['hermes', '--profile', 'default', 'kanban', '--board', board.parent.name]
        result = subprocess.run(command + ['notify-list', '--json'], check=True,
                                env=env, capture_output=True, text=True, timeout=60)
        for row in json.loads(result.stdout or '[]'):
            if row.get('platform') == 'simplex' and row.get('chat_id') == owner:
                yield board.parent.name, row


def check(root, target):
    """Report drift only: the policy block, the auto-subscribe settings and
    any private-chat subscription. Writes nothing and unsubscribes nothing."""
    if not re.fullmatch(r'simplex:[0-9]+', target):
        raise ValueError('Owner destination must be a private SimpleX contact')
    owner = target.split(':', 1)[1]
    drift = 0
    soul, wanted = wanted_soul(root)
    if wanted != soul.read_text():
        print('drift: head-coordinator SOUL.md owner-chat policy block differs')
        drift += 1
    env = {**os.environ, 'HERMES_HOME': str(root)}
    for profile in ('default', 'head-coordinator'):
        result = subprocess.run(['hermes', '--profile', profile, 'config', 'get',
                                 'kanban.auto_subscribe_on_create'],
                                capture_output=True, text=True, timeout=60, env=env)
        current = result.stdout.strip() if result.returncode == 0 else '<unset>'
        if current != 'false':
            print(f'drift: {profile} kanban.auto_subscribe_on_create is {current}, want false')
            drift += 1
    for board, row in owner_board_rows(root, owner):
        print(f"drift: private-chat subscription on {board}:{row['task_id']}")
        drift += 1
    if not drift:
        print('owner-chat policy converged')
    return drift


def install(root, target):
    if not re.fullmatch(r'simplex:[0-9]+', target):
        raise ValueError('Owner destination must be a private SimpleX contact')
    owner = target.split(':', 1)[1]
    soul, wanted = wanted_soul(root)
    existing = soul.read_text()
    env = {**os.environ, 'HERMES_HOME': str(root)}
    # Hermes reloads config when its file signature changes. Disable creation
    # before removing old rows, so new cards cannot immediately recreate them.
    for profile in ('default', 'head-coordinator'):
        subprocess.run(['hermes', '--profile', profile, 'config', 'set',
                        'kanban.auto_subscribe_on_create', 'false'], check=True,
                       timeout=60, env=env)
    if wanted != existing:
        hermes_common.backup_file(root, 'owner-chat-policy', soul)
        hermes_common.atomic_write(soul, wanted)
    removed = 0
    for board, row in owner_board_rows(root, owner):
        command = ['hermes', '--profile', 'default', 'kanban', '--board', board]
        subprocess.run(command + ['notify-unsubscribe', row['task_id'],
                                  '--platform', 'simplex', '--chat-id', owner,
                                  '--thread-id', row['thread_id'] or ''], check=True,
                       timeout=60, env=env)
        removed += 1
    return removed


if __name__ == '__main__':
    root = Path(os.environ.get('HERMES_ROOT', str(Path.home() / '.hermes')))
    check_only = '--check' in sys.argv[1:]
    # Reuse the existing allowlist/loopback validation without printing .env.
    spec = importlib.util.spec_from_file_location('owner_alerts',
                                                  Path(__file__).with_name('kanban-owner-alerts.py'))
    alerts = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(alerts)
    try:
        if check_only:
            sys.exit(1 if check(root, alerts.target_config(root)) else 0)
        print(f'Removed {install(root, alerts.target_config(root))} private-chat subscriptions')
    except (ValueError, OSError, subprocess.SubprocessError) as exc:
        print(f'owner chat policy: {exc}', file=sys.stderr)
        sys.exit(2)
