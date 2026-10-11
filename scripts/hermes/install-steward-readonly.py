#!/usr/bin/env python3
"""Install the report-only steward using existing Hermes hooks and cron.

Standard-library operations glue preserves unrelated YAML without reserialising
the profile or adding a parser dependency.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys

SOURCE = Path(__file__).resolve().parent
PROFILE = 'board-steward'


def replace_setting(text, key, yaml_value):
    block = key + ': ' + yaml_value + '\n\n'
    pattern = rf'^{re.escape(key)}:.*?(?=^[^\s#]|\Z)'
    changed, count = re.subn(pattern, lambda _: block, text, flags=re.M | re.S)
    if count > 1:
        raise ValueError(f'Duplicate {key} settings')
    return changed if count else text.rstrip() + '\n\n' + block


def readonly_hook(text, command, marker_name='steward-readonly', matcher='.*'):
    marker = f'    # nixhomeserver-{marker_name}:'
    if marker + 'start' in text:
        text, count = re.subn(r'^' + marker + r'start\n.*?^' + marker + r'end\n', '', text, flags=re.M | re.S)
        if count != 1:
            raise ValueError('Invalid managed steward hook section')
    stanza = (marker + 'start\n    - matcher: ' + json.dumps(matcher) + '\n      command: ' + json.dumps(command)
              + '\n      timeout: 10\n      fail_closed: true\n' + marker + 'end\n')
    match = re.search(r'^hooks:[ \t]*\n(.*?)(?=^\S|\Z)', text, re.M | re.S)
    if not match:
        if re.search(r'^hooks:', text, re.M):
            raise ValueError('Existing hooks must use block YAML; preserve and reconcile them')
        return text.rstrip() + '\n\nhooks:\n  pre_tool_call:\n' + stanza + '\n'
    hooks = match[1]
    if re.search(r'^  pre_tool_call:[ \t]*\n', hooks, re.M):
        hooks = re.sub(r'^  pre_tool_call:[ \t]*\n', lambda _: '  pre_tool_call:\n' + stanza,
                       hooks, count=1, flags=re.M)
    elif re.search(r'^  pre_tool_call: \[\][ \t]*$', hooks, re.M):
        hooks = re.sub(r'^  pre_tool_call: \[\][ \t]*\n?', lambda _: '  pre_tool_call:\n' + stanza,
                       hooks, count=1, flags=re.M)
    elif re.search(r'^  pre_tool_call:', hooks, re.M):
        raise ValueError('Existing pre_tool_call hooks must use block YAML')
    else:
        hooks = '  pre_tool_call:\n' + stanza + hooks
    return text[:match.start(1)] + hooks + text[match.end(1):]


def install(root, repo, check=False):
    profile = root / 'profiles' / PROFILE
    if not (profile / 'SOUL.md').exists():
        raise ValueError('Create the board-steward profile before installing its policy')
    config_path = profile / 'config.yaml'
    config_text = config_path.read_text()
    command = shlex.join(['python3', str(root / 'scripts/steward-readonly-guard.py')])
    config_text = readonly_hook(config_text, command)
    # The owner's explicit read-only request authorises this scoped hook. Other
    # hooks/configuration are retained; only the steward profile is affected.
    config_text = replace_setting(config_text, 'hooks_auto_accept', 'true')
    metadata_path = profile / 'profile.yaml'
    description = ('Independent read-only board steward. Inspects all boards and reports '
                   'blockers, parallel-work opportunities and exact proposed commands '
                   'for the external Codex agent. Never writes files or changes cards.')
    changes = {profile / 'SOUL.md': (SOURCE / 'taskforce/board-steward.md').read_text(),
               profile / 'skills/devops/board-steward/SKILL.md':
                   (SOURCE / 'taskforce/board-steward-skill.md').read_text(),
               config_path: config_text,
               metadata_path: replace_setting(metadata_path.read_text(), 'description', json.dumps(description))}
    for name in ('kanban-daily-steward.py', 'steward-opportunity-scan.py', 'steward-board-read.py',
                 'steward-readonly-guard.py'):
        changes[root / 'scripts' / name] = (SOURCE / name).read_text()
        if name != 'steward-readonly-guard.py':
            changes[profile / 'scripts' / name] = (SOURCE / name).read_text()
    changes = {path: text for path, text in changes.items() if not path.exists() or path.read_text() != text}
    jobs_path = profile / 'cron/jobs.json'
    jobs = json.loads(jobs_path.read_text()).get('jobs', []) if jobs_path.exists() else []
    # The separately approved DM split uses profile-scoped scheduler delivery.
    # Reinstallation must not restore manual group sends or disable DM reports.
    specifications = [('hermes daily steward', '0 7 * * *', 'daily-steward-prompt.txt', '--script', 'kanban-daily-steward.py', 'simplex'),
                      ('steward opportunity scan', 'every 2h', 'steward-opportunity-prompt.txt', '--monitor-script', 'steward-opportunity-scan.py', 'local')]
    commands = []
    for name, schedule, prompt_name, script_flag, script, deliver in specifications:
        matching = [job for job in jobs if job.get('name') == name]
        if len(matching) > 1:
            raise ValueError(f'Duplicate steward job: {name}')
        prompt = (SOURCE / prompt_name).read_text()
        prefix = ['hermes', '--profile', PROFILE, 'cron']
        if matching:
            job = matching[0]
            schedule_changed = (name == 'hermes daily steward'
                                and (job.get('schedule') or {}).get('expr') != schedule)
            if (job.get('prompt') != prompt or 'board-steward' not in (job.get('skills') or [])
                    or job.get('deliver') != deliver or job.get('workdir') != str(repo)
                    or job.get(script_flag[2:].replace('-', '_')) != script or schedule_changed):
                commands.append(prefix + ['edit', job['id'], '--prompt', prompt, '--add-skill', 'board-steward',
                                           script_flag, script, '--workdir', str(repo), '--deliver', deliver]
                                + (['--schedule', schedule] if schedule_changed else []))
        else:
            commands.append(prefix + ['create', schedule, prompt, '--name', name, '--skill', 'board-steward',
                                     script_flag, script, '--workdir', str(repo), '--deliver', deliver])
    if check:
        for path in changes:
            print(f'drift: {path}')
        for command in commands:
            print(f'drift: steward cron {command[4]}')
        return int(bool(changes or commands))
    for path, text in changes.items():
        if path.exists():
            backup = root / 'backups/steward-readonly' / hashlib.sha256(str(path).encode()).hexdigest()[:12]
            backup.mkdir(parents=True, exist_ok=True, mode=0o700)
            old = path.read_bytes()
            copy = backup / hashlib.sha256(old).hexdigest()
            if not copy.exists():
                copy.write_bytes(old)
                copy.chmod(0o600)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        if path.suffix in ('.sh', '.py'):
            path.chmod(0o700)
        print(f'installed: {path}')
    environment = {**os.environ, 'HERMES_ROOT': str(root), 'HERMES_HOME': str(root)}
    for command in commands:
        subprocess.run(command, check=True, env=environment, stdout=subprocess.DEVNULL)
    return 0


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    try:
        root = Path(os.environ.get('HERMES_ROOT', str(Path.home() / '.hermes')))
        repo = Path(os.environ.get('REPO_DIR', '/home/dsaw/Projects/NixOS'))
        sys.exit(install(root, repo, args.check))
    except (ValueError, OSError, subprocess.SubprocessError) as exc:
        print(f'steward installer: {exc}', file=sys.stderr)
        sys.exit(2)
