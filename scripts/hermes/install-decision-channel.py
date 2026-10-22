#!/usr/bin/env python3
"""Install the coordinator's current-decisions SimpleX group.

The group is the third owner-facing SimpleX channel: the coordinator's DM stays
a conversation, and the group holds only the decisions that still need or
recently changed the owner's awareness. It is deliberately a group rather than a
second DM, because one contact can have only one direct conversation.

This installer is idempotent:

* with no configured group it creates one, enables full deletion (so a resolved
  decision can be removed for every member), invites the owner and records
  ``SIMPLEX_DECISION_GROUP`` plus the matching inbound allowlist in the
  coordinator profile;
* with a configured group it verifies the group still exists and the owner is a
  member, and re-invites only when an invitation is genuinely missing;
* it copies the tracked ledger CLI into ``~/.hermes/scripts``;
* it never restarts the gateway, because that would interrupt active workers.

Run ``--check`` for a read-only drift report. Nothing is sent to the owner
except the group invitation itself, and accepting that invitation is the
owner's action in SimpleX.
"""

from __future__ import annotations

import argparse
import asyncio
import hashlib
import json
import os
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import hermes_common
import simplex_decisions

PROFILE = simplex_decisions.PROFILE
GROUP_NAME = 'Hermes Decisions'
GROUP_FULL_NAME = 'Head coordinator decisions'
GROUP_DESCRIPTION = 'Current owner decisions only; edited and removed as they change'


class GroupRpc:
    def __init__(self, url, home=None):
        self.url = url
        self.home = home

    def call(self, command):
        websockets = simplex_decisions.load_websockets(self.home)

        async def run():
            corr = hashlib.sha256(command.encode()).hexdigest()[:24]
            async with websockets.connect(self.url, max_size=None) as ws:
                await ws.send(json.dumps({'corrId': corr, 'cmd': command}))
                while True:
                    message = json.loads(await asyncio.wait_for(ws.recv(), timeout=20))
                    if message.get('corrId') == corr:
                        return message.get('resp') or {}

        return asyncio.run(run())

    @staticmethod
    def error(resp):
        error = (resp.get('chatError') or {}).get('errorType') or {}
        return error.get('message') or resp.get('type') or 'unknown SimpleX error'

    def users(self):
        resp = self.call('/users')
        if resp.get('type') != 'usersList':
            raise RuntimeError(self.error(resp))
        for entry in resp.get('users') or []:
            user = entry.get('user') if isinstance(entry, dict) else None
            if user and user.get('activeUser'):
                return user['userId']
        raise RuntimeError('No active SimpleX user on the coordinator daemon')

    def groups(self):
        resp = self.call('/groups')
        if resp.get('type') != 'groupsList':
            raise RuntimeError(self.error(resp))
        return {group['groupId']: group for group in resp.get('groups') or []}

    def members(self, group_id):
        resp = self.call(f'/_members #{group_id}')
        if resp.get('type') != 'groupMembers':
            raise RuntimeError(self.error(resp))
        return (resp.get('group') or {}).get('members') or []

    def create_group(self):
        user_id = self.users()
        profile = {
            'displayName': GROUP_NAME,
            'fullName': GROUP_FULL_NAME,
            'shortDescr': GROUP_DESCRIPTION,
            'groupPreferences': {
                'fullDelete': {'enable': 'on'},
                'history': {'enable': 'on'},
            },
        }
        resp = self.call(f'/_group {user_id} {json.dumps(profile)}')
        if resp.get('type') != 'groupCreated':
            raise RuntimeError(self.error(resp))
        return int(resp['groupInfo']['groupId'])

    def enable_full_delete(self, group_id):
        profile = {
            'displayName': GROUP_NAME,
            'fullName': GROUP_FULL_NAME,
            'shortDescr': GROUP_DESCRIPTION,
            'groupPreferences': {'fullDelete': {'enable': 'on'}, 'history': {'enable': 'on'}},
        }
        resp = self.call(f'/_group_profile #{group_id} {json.dumps(profile)}')
        if resp.get('type') != 'groupUpdated':
            raise RuntimeError(self.error(resp))

    def invite(self, group_id, contact_id):
        resp = self.call(f'/_add #{group_id} {contact_id} admin')
        if resp.get('type') == 'sentGroupInvitation':
            return True
        message = self.error(resp).lower()
        if 'already' in message or 'member' in message and 'exists' in message:
            return False
        raise RuntimeError(self.error(resp))


def set_env(path, updates):
    existing = path.read_text() if path.exists() else ''
    lines = existing.splitlines()
    for key, value in updates.items():
        pattern = re.compile(rf'\s*{re.escape(key)}\s*=')
        replaced = False
        for index, line in enumerate(lines):
            if pattern.match(line):
                lines[index] = f'{key}={value}'
                replaced = True
                break
        if not replaced:
            if lines and lines[-1] == '':
                lines.insert(len(lines) - 1, f'{key}={value}')
            else:
                lines.append(f'{key}={value}')
    return '\n'.join(lines) + '\n'


def owner_contact(root):
    values = simplex_decisions.env_values(root)
    home = values.get('SIMPLEX_HOME_CHANNEL', '').strip()
    allowed = [value.strip() for value in values.get('SIMPLEX_ALLOWED_USERS', '').split(',') if value.strip()]
    if not re.fullmatch(r'[0-9]+', home) or home not in allowed:
        raise ValueError('Owner home channel must be a numeric allowlisted contact')
    return int(home)


def check(root):
    group = simplex_decisions.configured_group(root)
    rpc = GroupRpc(simplex_decisions.ws_url(root), home=root)
    if group is None:
        print('decision channel: not configured')
        return 1
    groups = rpc.groups()
    if group not in groups:
        print(f'decision channel: group {group} is missing from the daemon')
        return 1
    info = groups[group]
    members = rpc.members(group)
    owner = owner_contact(root)
    owner_member = next((member for member in members if member.get('memberContactId') == owner), None)
    full_delete = (((info.get('fullGroupPreferences') or {}).get('fullDelete') or {}).get('enable'))
    print(f'decision channel: group {group} ({info.get("localDisplayName", "")})')
    print(f'  owner member: {owner_member.get("memberStatus", "unknown") if owner_member else "missing"}')
    print(f'  full deletion: {full_delete or "off"}')
    print(f'  inbound allowlist: {simplex_decisions.env_values(root).get("SIMPLEX_GROUP_ALLOWED", "")}')
    return 0 if owner_member and full_delete == 'on' else 1


def install(root):
    env_path = root / 'profiles' / PROFILE / '.env'
    if not env_path.exists():
        raise ValueError(f'Missing coordinator profile env: {env_path}')
    group = simplex_decisions.configured_group(root)
    rpc = GroupRpc(simplex_decisions.ws_url(root), home=root)
    owner = owner_contact(root)

    groups = rpc.groups()
    created = False
    if group is None:
        group = rpc.create_group()
        created = True
        groups = rpc.groups()

    if group not in groups:
        raise ValueError(f'Configured decision group {group} does not exist on the daemon')

    info = groups[group]
    full_delete = (((info.get('fullGroupPreferences') or {}).get('fullDelete') or {}).get('enable'))
    if full_delete != 'on':
        rpc.enable_full_delete(group)

    members = rpc.members(group)
    present = any(member.get('memberContactId') == owner for member in members)
    invited = False
    if not present:
        invited = rpc.invite(group, owner)

    env_path.parent.mkdir(parents=True, exist_ok=True)
    wanted = set_env(env_path, {'SIMPLEX_DECISION_GROUP': str(group),
                                'SIMPLEX_GROUP_ALLOWED': str(group)})
    if wanted != env_path.read_text():
        hermes_common.backup_file(root, 'decision-channel', env_path)
        hermes_common.atomic_write(env_path, wanted)

    source = Path(__file__).resolve().parent
    scripts = root / 'scripts'
    for name in ('simplex_decisions.py', 'simplex-decisions.sh'):
        target = scripts / name
        text = (source / name).read_text()
        if not target.exists() or target.read_text() != text:
            hermes_common.backup_file(root, 'decision-channel', target)
            hermes_common.atomic_write(target, text, mode=0o700)

    print(f'decision channel: group {group} ({GROUP_NAME})')
    print(f'  created: {"yes" if created else "no"}')
    print(f'  invitation sent: {"yes" if invited else "not needed"}')
    if invited:
        print('  owner must accept the SimpleX group invitation before replies work')
    print('  refresh the coordinator adapter when idle: hermes --profile head-coordinator gateway restart')
    return 0 if present or invited else 1


def ensure_runtime(root):
    """Make ``websockets`` importable, re-execing if the runtime is missing."""
    try:
        simplex_decisions.load_websockets(root)
        return
    except ImportError:
        pass
    candidates = sorted(root.glob('tools/python-*/bin/python3'))
    if candidates and Path(sys.executable).resolve() != candidates[0].resolve():
        os.execv(str(candidates[0]), [str(candidates[0]), str(Path(__file__).resolve()), *sys.argv[1:]])
    raise RuntimeError('websockets is unavailable; run this installer with the Hermes bundled Python')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true', help='Report drift without creating or sending')
    parser.add_argument('--install', action='store_true', help='Create or repair the decision channel')
    args = parser.parse_args()
    root = Path(os.environ.get('HERMES_ROOT', str(Path.home() / '.hermes')))
    try:
        ensure_runtime(root)
        return check(root) if args.check or not args.install else install(root)
    except (OSError, ValueError, RuntimeError) as exc:
        print(f'install-decision-channel: {exc}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
