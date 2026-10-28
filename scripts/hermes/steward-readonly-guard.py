#!/usr/bin/env python3
"""Enforce the steward's reporting scope through Hermes' pre_tool_call hook.

Standard-library operations glue reuses the existing Hermes hook protocol.
It is not a new backend. The shared account remains a workflow boundary.
"""
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import sys

READ_TOOLS = {'read_file', 'search', 'skill_view', 'skills_list', 'clarify',
              'tool_search', 'tool_describe'}
# The steward's skill directs it to check owner-alert delivery with the
# owner-alerts helper. Only its explicitly read-only diagnostics are allowed;
# the sending and installing actions stay blocked.
OWNER_ALERT_SCRIPT = 'kanban-owner-alerts.py'
OWNER_ALERT_READONLY_FLAGS = {'--details', '--resolve', '--check-summary'}
OWNER_ALERT_READONLY_BARE = {'--check-blockers'}
OWNER_ALERT_MUTATING_FLAGS = {'--dry-run', '--install', '--send-decisions'}


def owner_alert_readonly(args):
    """True only for an owner-alerts invocation that neither sends nor mutates."""
    if not args or any(arg in OWNER_ALERT_MUTATING_FLAGS for arg in args):
        return False
    if args[0] in OWNER_ALERT_READONLY_BARE:
        return True
    return args[0] in OWNER_ALERT_READONLY_FLAGS


def coordinator_request_args(args):
    # No recipient, executable, output path or arbitrary native CLI arguments.
    if args[:1] == ['--policy-report']:
        return (len(args) in (3, 4) and re.fullmatch(r'[a-f0-9]{24}', args[1])
                and re.fullmatch(r'[a-f0-9]{64}', args[2])
                and (len(args) == 3 or args[3] == '--to-author'))
    if len(args) != 4 or set(args[::2]) != {'--request-id', '--message'}:
        return False
    values = dict(zip(args[::2], args[1::2]))
    return (bool(values['--request-id'].strip()) and len(values['--request-id']) <= 128
            and bool(values['--message'].strip()) and len(values['--message']) <= 24000)


def terminal_command(command, root, repo):
    # Cron delivers the final report through the profile's configured channel.
    # Only the scoped coordinator/policy helper may queue an internal request.
    try:
        argv = shlex.split(command)
    except ValueError:
        return None
    if not argv:
        return None
    executable = Path(argv[0]).expanduser()
    name = executable.name
    allowed = False
    if name in {'python3', 'python'} and len(executable.parts) == 1 and len(argv) >= 2:
        executable = Path(sys.executable)
        script = Path(argv[1]).expanduser()
        if not script.is_absolute():
            script = repo / script
        scripts = {'kanban-daily-steward.py', 'usage-pace.py', 'kanban-performance.py', 'kanban-blockers.py',
                   'steward-opportunity-scan.py', 'steward-board-read.py', 'board_progress.py', 'card_policy_audit.py'}
        bases = (root / 'scripts', root / 'profiles/board-steward/scripts', repo / 'scripts/hermes')
        allowed_paths = {base / item for base in bases for item in scripts}
        allowed_paths.add(root / 'profiles/board-steward/skills/devops/board-steward/scripts/steward-sweep.py')
        owner_alert_paths = {base / OWNER_ALERT_SCRIPT for base in bases}
        request_paths = {base / 'steward-coordinator-request.py' for base in bases}
        recovery_paths = {base / 'capability_recovery.py' for base in bases}
        resolved = script.resolve()
        if resolved in {path.resolve() for path in recovery_paths}:
            tail = argv[2:]
            allowed = (tail in ([], ['--inspect'], ['--monitor']) or
                       (len(tail) == 3 and tail[0] == '--handoff'
                        and re.fullmatch(r'[a-z0-9][a-z0-9_-]{0,63}:t_[a-z0-9_]{1,64}', tail[1])
                        and re.fullmatch(r'[a-f0-9]{64}', tail[2])))
        elif resolved in {path.resolve() for path in request_paths}:
            allowed = coordinator_request_args(argv[2:])
        elif resolved in {path.resolve() for path in owner_alert_paths}:
            allowed = owner_alert_readonly(argv[2:])
        else:
            allowed = resolved in {path.resolve() for path in allowed_paths}
        if allowed:
            argv[1] = str(resolved)
    elif name == 'git' and len(executable.parts) == 1:
        git_path = shutil.which('git')
        if not git_path:
            return None
        executable = Path(git_path)
        args = argv[1:]
        if args[:1] == ['-C'] and len(args) >= 3:
            args = args[2:]
        if args and args[0] in {'status', 'log', 'show', 'diff', 'merge-base', 'rev-parse', 'ls-files'}:
            # Output redirection and external diff drivers are not read-only.
            allowed = not any(arg.startswith(('--output', '--ext-diff', '--textconv')) for arg in args[1:])
            if args[0] in {'log', 'show', 'diff'}:
                command_index = len(argv) - len(args)
                argv[command_index + 1:command_index + 1] = ['--no-ext-diff', '--no-textconv']
        elif args[:1] == ['branch']:
            allowed = len(args) == 2 and args[1] in {'--show-current', '--list'}
        argv.insert(1, '--no-optional-locks')
    if not allowed:
        return None
    # Execute the checked argv literally, not the original shell expression.
    # This neutralises substitutions, separators, redirects and newlines even
    # when they arrived inside the arguments to an otherwise allowed command.
    argv[0] = str(executable)
    return {'command': shlex.join(argv)}


def guard(payload, root, repo):
    tool = payload.get('tool_name')
    args = payload.get('tool_input') or {}
    # Asking the coordinator to act is authorized even when performing the
    # requested action is outside the steward's own read-only scope.
    if tool == 'message_agent':
        message = args.get('message')
        if (args.get('target') == 'head-coordinator'
                and isinstance(message, str) and message.strip()):
            return {}
        return {'action': 'block', 'message':
                'Steward handoffs require target=head-coordinator and a non-empty message. '
                'Other recipients and delegation tools remain outside this scope.'}
    if tool in READ_TOOLS:
        return {}
    if isinstance(tool, str) and tool.startswith('kanban_'):
        return {'action': 'block', 'message':
                'Native board reads can recompute readiness or migrate state. Use '
                'python3 ~/.hermes/scripts/steward-board-read.py --boards, then '
                '--board <slug> --query <SELECT> for read-only board evidence.'}
    if tool == 'terminal':
        checked = terminal_command(args.get('command', ''), root, repo)
        if checked:
            return {'action': 'modify', 'args': checked}
    return {'action': 'block', 'message':
            'The board steward is read-only. Report the finding, exact proposed action '
            'to head-coordinator: use message_agent in Bot Chat, or the installed '
            'steward-coordinator-request.py helper in SimpleX. Do not execute the change.'}


def default_repo(root):
    """The repo relative steward terminal paths resolve against.

    STEWARD_REPO overrides; otherwise the nixhomeserver board's recorded
    default_workdir is authoritative, with the tracked workstation path as the
    final fallback for a machine whose board state is not yet installed.
    """
    override = os.environ.get('STEWARD_REPO')
    if override:
        return Path(override)
    try:
        workdir = json.loads((root / 'kanban/boards/nixhomeserver/board.json').read_text()).get('default_workdir')
    except (OSError, ValueError):
        workdir = None
    return Path(workdir) if workdir else Path('/home/dsaw/Projects/NixOS')


if __name__ == '__main__':
    try:
        root = Path(os.environ.get('HERMES_ROOT', str(Path.home() / '.hermes')))
        print(json.dumps(guard(json.load(sys.stdin), root, default_repo(root))))
    except (ValueError, TypeError, AttributeError):
        print(json.dumps({'action': 'block', 'message': 'Invalid steward tool request; no action allowed.'}))
