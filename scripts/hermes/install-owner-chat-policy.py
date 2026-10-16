#!/usr/bin/env python3
"""Stop native lifecycle notifications to the owner's private SimpleX chat.

Python operations glue uses Hermes' existing config/subscription CLI; no new
backend or dependency. The separate Hard Blocker sender keeps its own state.

Run after restoring/upgrading Hermes: python3 scripts/hermes/install-owner-chat-policy.py
HERMES_ROOT overrides the installation root. Refresh an idle coordinator's
gateway profile afterwards so cached identity includes the updated policy.
"""
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess

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


def install(root, target):
    if not re.fullmatch(r'simplex:[0-9]+', target):
        raise ValueError('Owner destination must be a private SimpleX contact')
    owner = target.split(':', 1)[1]
    soul = root / 'profiles/head-coordinator/SOUL.md'
    existing = soul.read_text()
    spec = importlib.util.spec_from_file_location('instructions',
        Path(__file__).with_name('install-instruction-policy.py'))
    instructions = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(instructions)
    wanted = instructions.block(existing, MARKER, END_MARKER, POLICY)
    env = {**os.environ, 'HERMES_HOME': str(root)}
    # Hermes reloads config when its file signature changes. Disable creation
    # before removing old rows, so new cards cannot immediately recreate them.
    for profile in ('default', 'head-coordinator'):
        subprocess.run(['hermes', '--profile', profile, 'config', 'set',
                        'kanban.auto_subscribe_on_create', 'false'], check=True, env=env)
    if wanted != existing:
        soul.write_text(wanted)
    removed = 0
    for board in sorted((root / 'kanban/boards').glob('*/board.json')):
        command = ['hermes', '--profile', 'default', 'kanban', '--board', board.parent.name]
        result = subprocess.run(command + ['notify-list', '--json'], check=True,
                                env=env, capture_output=True, text=True)
        for row in json.loads(result.stdout):
            if row['platform'] != 'simplex' or row['chat_id'] != owner:
                continue
            subprocess.run(command + ['notify-unsubscribe', row['task_id'],
                                      '--platform', 'simplex', '--chat-id', owner,
                                      '--thread-id', row['thread_id'] or ''], check=True, env=env)
            removed += 1
    return removed


if __name__ == '__main__':
    root = Path(os.environ.get('HERMES_ROOT', str(Path.home() / '.hermes')))
    # Reuse the existing allowlist/loopback validation without printing .env.
    spec = importlib.util.spec_from_file_location('owner_alerts',
                                                 Path(__file__).with_name('kanban-owner-alerts.py'))
    alerts = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(alerts)
    print(f'Removed {install(root, alerts.target_config(root))} private-chat subscriptions')
