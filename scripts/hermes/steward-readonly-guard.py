#!/usr/bin/env python3
"""Enforce the steward's reporting scope through Hermes' pre_tool_call hook.

Standard-library operations glue reuses the existing Hermes hook protocol.
It is not a new backend. The shared account remains a workflow boundary.
"""
import json
import os
from pathlib import Path
import shlex
import shutil
import sys

READ_TOOLS = {'read_file', 'search', 'skill_view', 'skills_list', 'clarify'}


def terminal_command(command, root, repo):
    # Cron delivers the final report through the profile's configured channel.
    # The steward never invokes a sender or performs an outbound tool mutation.
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
        scripts = {'kanban-daily-steward.py', 'steward-opportunity-scan.py', 'steward-board-read.py'}
        allowed_paths = {base / item for base in
                         (root / 'scripts', root / 'profiles/board-steward/scripts', repo / 'scripts/hermes')
                         for item in scripts}
        allowed_paths.add(root / 'profiles/board-steward/skills/devops/board-steward/scripts/steward-sweep.py')
        allowed = script.resolve() in {path.resolve() for path in allowed_paths}
        if allowed:
            argv[1] = str(script.resolve())
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
            'and commands for the owner to pass to the external agent; do not execute the change.'}


if __name__ == '__main__':
    try:
        root = Path(os.environ.get('HERMES_ROOT', str(Path.home() / '.hermes')))
        repo = Path(os.environ.get('STEWARD_REPO', '/home/dsaw/Projects/NixOS'))
        print(json.dumps(guard(json.load(sys.stdin), root, repo)))
    except (ValueError, TypeError, AttributeError):
        print(json.dumps({'action': 'block', 'message': 'Invalid steward tool request; no action allowed.'}))
