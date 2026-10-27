#!/usr/bin/env python3
"""Install the report-only steward using existing Hermes hooks and cron.

Python operations glue preserves unrelated YAML; the bounded tool-list editor
reuses Hermes' existing PyYAML dependency.
"""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys

import hermes_common

SOURCE = Path(__file__).resolve().parent
sys.path.insert(0, str(SOURCE))
from hermes_config import document, platform_tools
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
    stanza = (marker + 'start\n    - matcher: ' + json.dumps(matcher) + '\n      command: ' + json.dumps(command)
              + '\n      timeout: 10\n      fail_closed: true\n' + marker + 'end\n')
    if start in text or end in text:
        if text.count(start) != 1 or text.count(end) != 1 or text.index(end) < text.index(start):
            raise ValueError('Invalid managed hook markers; preserve and reconcile the config')
        # An exact block is left exactly where it is. Every installer prepends its
        # own block to pre_tool_call, so the second installer moved the first one
        # down and the first then rewrote it back on top: `--check` reported
        # permanent drift on six profile configs and the always-red signal was
        # ignored. Hook order between distinct matchers is not significant, so
        # only a wrong or absent block is rewritten.
        existing = re.search(r'^' + re.escape(start) + r'\n.*?^' + re.escape(end) + r'(?:\n|\Z)',
                             text, flags=re.M | re.S)
        if existing and existing.group(0) == stanza:
            return text
        text, count = re.subn(r'^' + re.escape(start) + r'\n.*?^' + re.escape(end) + r'(?:\n|\Z)',
                              '', text, flags=re.M | re.S)
        if count != 1:
            raise ValueError('Invalid managed hook section; preserve and reconcile the config')
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


def default_repo(root):
    """The repo a steward cron workdir points at.

    REPO_DIR overrides; otherwise the nixhomeserver board's recorded
    default_workdir is the natural source (the same one the steward scripts
    resolve checkouts from), with the tracked workstation path as the final
    fallback for a machine whose board state is not yet installed.
    """
    env_repo = os.environ.get('REPO_DIR')
    if env_repo:
        return Path(env_repo)
    try:
        workdir = json.loads((root / 'kanban/boards/nixhomeserver/board.json').read_text()).get('default_workdir')
        if workdir:
            return Path(workdir)
    except (OSError, ValueError):
        pass
    return Path('/home/dsaw/Projects/NixOS')


def steward_soul(current, instructions):
    wanted = instructions.shared((SOURCE / 'taskforce/board-steward.md').read_text(), PROFILE)
    # Independent policy blocks are installed by other components: the cron
    # installer owns the hermes-cron-policy block and the memory installer owns
    # the hermes-memory-policy block. Retain each one's exact bytes, because
    # refreshing the steward role must not remove another component's policy.
    # Preserving only the cron block made this installer and
    # install-memory-policy.py strip each other's block on every run, so
    # `--check` reported drift forever on the steward SOUL.
    sections = []
    for name in ('cron-policy', 'memory-policy'):
        start, end = f'<!-- hermes-{name} -->', f'<!-- /hermes-{name} -->'
        if start not in current and end not in current:
            continue
        if current.count(start) != 1 or current.count(end) != 1 or current.index(end) < current.index(start):
            raise ValueError(f'Invalid managed {name} markers; preserve and reconcile the SOUL')
        sections.append(current[current.index(start):current.index(end) + len(end)])
    if not sections:
        return wanted
    return wanted.rstrip() + '\n\n' + '\n\n'.join(sections) + '\n'


def configure_model(text):
    """Pin the owner's DeepSeek/high choice without changing fallback providers."""
    original = document(text)
    model = dict(original.get('model') or {})
    agent = dict(original.get('agent') or {})
    overrides = dict(agent.get('reasoning_overrides') or {})
    model.update(default='deepseek-v4.1-flash', provider='custom:opencode-go')
    agent['reasoning_effort'] = 'high'
    overrides['deepseek-v4.1-flash'] = 'high'
    agent['reasoning_overrides'] = overrides
    for key, value in (('model', model), ('agent', agent)):
        if original.get(key) != value:
            text = replace_setting(text, key, json.dumps(value))
    expected = {**original, 'model': model, 'agent': agent}
    if document(text) != expected:
        raise ValueError('Steward model edit would change unrelated settings')
    return text


def profile_files(root, pending=None):
    pending = pending or {}
    profile = root / 'profiles' / PROFILE
    if not (profile / 'SOUL.md').exists():
        raise ValueError('Create the board-steward profile before installing its policy')
    config_path = profile / 'config.yaml'
    config_text = configure_model(pending.get(config_path, config_path.read_text()))
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
    soul_path = profile / 'SOUL.md'
    changes = {soul_path: steward_soul(pending.get(soul_path, soul_path.read_text()), instructions),
               profile / 'skills/devops/board-steward/SKILL.md':
                   (SOURCE / 'taskforce/board-steward-skill.md').read_text(),
               config_path: config_text,
               metadata_path: replace_setting(metadata_path.read_text(), 'description', json.dumps(description))}
    changes[root / 'scripts/hermes-fleet-policy.md'] = (SOURCE / 'taskforce/owner-blocker-authoring.md').read_text()
    changes[root / 'scripts/hermes-card-authoring.md'] = (SOURCE.parent.parent / 'documentation/hermes-card-authoring.md').read_text()
    changes[root / 'scripts/hermes-daily-steward.md'] = (SOURCE.parent.parent / 'documentation/hermes-daily-steward.md').read_text()
    changes[root / 'scripts/hermes-instructions.md'] = (SOURCE.parent.parent / 'documentation/hermes-instructions.md').read_text()
    changes[root / 'scripts/hermes-capability-recovery.md'] = (SOURCE / 'instructions/capability-recovery.md').read_text()
    for name in ('capability_recovery.py', 'kanban-daily-steward.py', 'daily-steward-window.py', 'usage-pace.py', 'kanban-performance.py', 'agent_usage_report.py', 'kanban-blockers.py',
                 'steward-opportunity-scan.py', 'board_progress.py',
                 'steward-board-read.py', 'steward-readonly-guard.py', 'steward-coordinator-request.py'):
        changes[root / 'scripts' / name] = (SOURCE / name).read_text()
        if name != 'steward-readonly-guard.py':
            changes[profile / 'scripts' / name] = (SOURCE / name).read_text()
    changes = {path: text for path, text in changes.items() if not path.exists() or path.read_text() != text}
    return changes


def install(root, repo, check=False):
    profile = root / 'profiles' / PROFILE
    changes = profile_files(root)
    jobs_path = profile / 'cron/jobs.json'
    jobs = json.loads(jobs_path.read_text()).get('jobs', []) if jobs_path.exists() else []
    # The separately approved DM split uses profile-scoped scheduler delivery.
    # Reinstallation must not restore manual group sends or disable DM reports.
    # The daily job runs through the daytime catch-up window so a missed 07:00
    # slot after a late power-on is reported during the day, never overnight;
    # cron-policy wraps the stall collector with a bounded, due-only packet.
    specifications = [('hermes daily steward', '0 7 * * *', 'daily-steward-prompt.txt', '--script', 'daily-steward-window.py', 'simplex', True),
                      ('steward opportunity scan', 'every 2h', 'steward-opportunity-prompt.txt', '--monitor-script', 'steward-opportunity-scan.py', 'local', False),
                      ('steward stall follow-up', '0 */4 * * *', 'steward-stall-prompt.txt', '--script', 'kanban-daily-steward.py', 'bot-chat:head-coordinator', False)]
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
                    or (continuity != ('self' in (job.get('context_from') or [])))):
                commands.append(prefix + ['edit', job['id'], '--prompt', prompt, '--add-skill', 'board-steward',
                                           script_flag, script, '--workdir', str(repo), '--deliver', deliver]
                                + (['--schedule', schedule] if schedule_changed else [])
                                + (['--continuity'] if continuity else ['--no-continuity']))
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
        hermes_common.backup_file(root, 'steward-readonly', path)
        mode = 0o700 if path.suffix in ('.sh', '.py') else (
            path.stat().st_mode & 0o777 if path.exists() else 0o600)
        hermes_common.atomic_write(path, text, mode=mode)
        print(f'installed: {path}')
    environment = {**os.environ, 'HERMES_ROOT': str(root), 'HERMES_HOME': str(root)}
    for command in commands:
        subprocess.run(command, check=True, timeout=60, env=environment, stdout=subprocess.DEVNULL)
    return 0


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    try:
        root = Path(os.environ.get('HERMES_ROOT', str(Path.home() / '.hermes')))
        sys.exit(install(root, default_repo(root), args.check))
    except (ValueError, OSError, subprocess.SubprocessError) as exc:
        print(f'steward installer: {exc}', file=sys.stderr)
        sys.exit(2)
