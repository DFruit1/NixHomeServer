#!/usr/bin/env python3
"""Install the report-only steward using existing Hermes hooks and cron.

Python operations glue preserves unrelated YAML; the bounded tool-list editor
reuses Hermes' existing PyYAML dependency.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys

SOURCE = Path(__file__).resolve().parent
sys.path.insert(0, str(SOURCE))
from hermes_config import platform_tools
PROFILE = 'board-steward'


def replace_setting(text, key, yaml_value):
    block = key + ': ' + yaml_value + '\n\n'
    pattern = rf'^{re.escape(key)}:.*?(?=^[^\s#]|\Z)'
    matches = list(re.finditer(pattern, text, flags=re.M | re.S))
    if len(matches) == 1:
        lines = matches[0][0].splitlines()
        if (lines[0] == key + ': ' + yaml_value
                and all(not line.strip() or line.lstrip().startswith('#') for line in lines[1:])):
            return text  # Keep existing spacing and annotations on an unchanged setting.
    changed, count = re.subn(pattern, lambda _: block, text, flags=re.M | re.S)
    if count > 1:
        raise ValueError(f'Duplicate {key} settings')
    return changed if count else text.rstrip() + '\n\n' + block


def readonly_hook(text, command, marker_name='steward-readonly', matcher='.*'):
    marker = f'    # nixhomeserver-{marker_name}:'
    start, end = marker + 'start', marker + 'end'
    if start in text or end in text:
        if text.count(start) != 1 or text.count(end) != 1 or text.index(end) < text.index(start):
            raise ValueError('Invalid managed hook markers; preserve and reconcile the config')
        text, count = re.subn(r'^' + re.escape(start) + r'\n.*?^' + re.escape(end) + r'(?:\n|\Z)',
                              '', text, flags=re.M | re.S)
        if count != 1:
            raise ValueError('Invalid managed hook section; preserve and reconcile the config')
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
    # Offer tools the existing read-only guard can use. Bot Chat injects its
    # fixed-recipient message_agent separately; this does not widen the guard.
    for platform in ('cli', 'desktop', 'simplex'):
        config_text = platform_tools(config_text, platform,
                                    replace=('file', 'terminal', 'skills', 'clarify'), optional=True)
    metadata_path = profile / 'profile.yaml'
    description = ('Independent read-only board steward. Inspects all boards and reports '
                   'blockers, parallel-work opportunities and exact proposed commands '
                   'to head-coordinator, including requests outside its own permissions. '
                   'Never writes files or changes cards itself.')
    spec = importlib.util.spec_from_file_location('instruction_policy', SOURCE / 'install-instruction-policy.py')
    instructions = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(instructions)
    changes = {profile / 'SOUL.md': instructions.shared((SOURCE / 'taskforce/board-steward.md').read_text()),
               profile / 'skills/devops/board-steward/SKILL.md':
                   (SOURCE / 'taskforce/board-steward-skill.md').read_text(),
               config_path: config_text,
               metadata_path: replace_setting(metadata_path.read_text(), 'description', json.dumps(description))}
    changes[root / 'scripts/hermes-fleet-policy.md'] = (SOURCE / 'taskforce/owner-blocker-authoring.md').read_text()
    changes[root / 'scripts/hermes-card-authoring.md'] = (SOURCE.parent.parent / 'documentation/hermes-card-authoring.md').read_text()
    changes[root / 'scripts/hermes-instructions.md'] = (SOURCE.parent.parent / 'documentation/hermes-instructions.md').read_text()
    for name in ('kanban-daily-steward.py', 'daily-steward-window.py', 'usage-pace.py',
                 'steward-opportunity-scan.py',
                 'steward-board-read.py', 'steward-readonly-guard.py', 'steward-coordinator-request.py'):
        changes[root / 'scripts' / name] = (SOURCE / name).read_text()
        if name != 'steward-readonly-guard.py':
            changes[profile / 'scripts' / name] = (SOURCE / name).read_text()
    changes = {path: text for path, text in changes.items() if not path.exists() or path.read_text() != text}
    jobs_path = profile / 'cron/jobs.json'
    jobs = json.loads(jobs_path.read_text()).get('jobs', []) if jobs_path.exists() else []
    # The separately approved DM split uses profile-scoped scheduler delivery.
    # Reinstallation must not restore manual group sends or disable DM reports.
    # The daily job runs through the daytime catch-up window so a missed 07:00
    # slot after a late power-on is reported during the day, never overnight;
    # the stall follow-up keeps the raw collector because it fires every slot.
    specifications = [('hermes daily steward', '0 7 * * *', 'daily-steward-prompt.txt', '--script', 'daily-steward-window.py', 'simplex', False),
                      ('steward opportunity scan', 'every 2h', 'steward-opportunity-prompt.txt', '--monitor-script', 'steward-opportunity-scan.py', 'local', False),
                      ('steward stall follow-up', '0 */4 * * *', 'steward-stall-prompt.txt', '--script', 'kanban-daily-steward.py', 'bot-chat:head-coordinator', True)]
    commands = []
    for name, schedule, prompt_name, script_flag, script, deliver, continuity in specifications:
        matching = [job for job in jobs if job.get('name') == name]
        if len(matching) > 1:
            raise ValueError(f'Duplicate steward job: {name}')
        prompt = (SOURCE / prompt_name).read_text()
        prefix = ['hermes', '--profile', PROFILE, 'cron']
        if matching:
            job = matching[0]
            schedule_changed = (name in {'hermes daily steward', 'steward stall follow-up'}
                                and (job.get('schedule') or {}).get('expr') != schedule)
            if ((job.get('prompt') or '').strip() != prompt.strip() or 'board-steward' not in (job.get('skills') or [])
                    or job.get('deliver') != deliver or job.get('workdir') != str(repo)
                    or job.get(script_flag[2:].replace('-', '_')) != script or schedule_changed
                    or (continuity and 'self' not in (job.get('context_from') or []))):
                commands.append(prefix + ['edit', job['id'], '--prompt', prompt, '--add-skill', 'board-steward',
                                           script_flag, script, '--workdir', str(repo), '--deliver', deliver]
                                + (['--schedule', schedule] if schedule_changed else [])
                                + (['--continuity'] if continuity else []))
        else:
            commands.append(prefix + ['create', schedule, prompt, '--name', name, '--skill', 'board-steward',
                                     script_flag, script, '--workdir', str(repo), '--deliver', deliver]
                            + (['--continuity'] if continuity else []))
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
