#!/usr/bin/env python3
"""Read-only board polling and owner delivery using Hermes' existing Python/CLI.

This is operations glue, not a new backend or dependency. No board mutation,
approval, subscription or unblock is performed by the unattended job.
"""
import argparse
from contextlib import closing
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import sqlite3
import subprocess
import sys
import tempfile

PROFILE = 'head-coordinator'
JOB = 'kanban owner blocker alerts'
MARKER = '<!-- kanban-owner-alerts -->'
END_MARKER = '<!-- /kanban-owner-alerts -->'


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


def snapshot(board_file):
    with closing(sqlite3.connect((board_file.parent / 'kanban.db').resolve().as_uri() + '?mode=ro', uri=True)) as db:
        db.row_factory = sqlite3.Row
        db.execute('PRAGMA query_only=ON')
        tasks = [dict(r) for r in db.execute("SELECT id,title,body,block_kind FROM tasks WHERE status='blocked' ORDER BY id")]
        for task in tasks:
            event = db.execute("SELECT id,payload FROM task_events WHERE task_id=? AND (kind='blocked' OR (kind='status' AND json_extract(payload,'$.status')='blocked')) ORDER BY id DESC LIMIT 1", (task['id'],)).fetchone()
            task['event_id'] = event['id'] if event else 0
            task['reason'] = (json.loads(event['payload'] or '{}').get('reason') or '') if event else ''
        return tasks


def message(board, task):
    heading = 'Owner decision' if task['block_kind'] == 'needs_input' else 'Technical blocker'
    text = f"{heading}: {board} {task['id']}\n{task['title']}\n\n"
    body = (task.get('body') or '').strip()
    reason = (task.get('reason') or '').strip()
    text += (body[:1100] + ('\n[Card body shortened]' if len(body) > 1100 else ''))
    if reason and reason not in body:
        text += '\n\nBlock reason: ' + reason[:1100]
    if heading == 'Technical blocker':
        text += f"\n\nReply: {board} {task['id']} — provide information or recovery instructions."
        text += '\nThis reports an execution problem; replying does not approve a code or policy change.'
    else:
        text += f"\n\nReply: {board} {task['id']} — approve, reject, or provide the requested information."
    text += '\nYour reply must be recorded on this exact card before any justified unblock. No deployment is authorised.'
    return text


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


def tick(root, dry_run=False):
    target = target_config(root)
    if not dry_run and (os.environ.get('HERMES_DELEGATED_CHILD_CONTEXT') or os.environ.get('HERMES_KANBAN_TASK')):
        raise PermissionError('Owner alerts run only from the operator or no-agent cron')
    directory = root / 'kanban/owner-alerts'
    if dry_run:
        for board in sorted((root / 'kanban/boards').glob('*/board.json')):
            for task in snapshot(board):
                print(message(board.parent.name, task))
        return
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    errors = []
    with (directory / '.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        path = directory / 'state.json'
        state = json.loads(path.read_text()) if path.exists() else {}
        for board in sorted((root / 'kanban/boards').glob('*/board.json')):
            try:
                for task in snapshot(board):
                    key = f'{target}:{board.parent.name}:{task["id"]}'
                    token = hashlib.sha256(json.dumps(task, sort_keys=True).encode()).hexdigest()
                    if state.get(key) == token:
                        continue
                    try:
                        send(root, target, message(board.parent.name, task))
                        state[key] = token
                        save(path, state)  # Advance only after successful delivery.
                        print(f'Sent {board.parent.name} {task["id"]} block={task["event_id"]}')
                    except (ValueError, OSError, RuntimeError, subprocess.SubprocessError) as exc:
                        errors.append(f'{board.parent.name} {task["id"]}: {exc}')
            except (ValueError, OSError, sqlite3.Error) as exc:
                errors.append(f'{board.parent.name}: {exc}')
    if errors:
        raise RuntimeError('; '.join(errors))


def install(root):
    source = Path(__file__).resolve().parent
    target_config(root)
    scripts = root / 'scripts'
    scripts.mkdir(parents=True, exist_ok=True)
    (scripts / 'kanban-owner-alerts.py').write_text(Path(__file__).read_text())
    (scripts / 'kanban-owner-alerts.py').chmod(0o700)
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
    if soul.read_text() != wanted:
        backup = root / 'backups/owner-alerts'
        backup.mkdir(parents=True, exist_ok=True, mode=0o700)
        copy = backup / (hashlib.sha256(soul.read_bytes()).hexdigest() + '.md')
        if not copy.exists():
            copy.write_bytes(soul.read_bytes())
            copy.chmod(0o600)
        soul.write_text(wanted)
    jobs = json.loads((root / 'cron/jobs.json').read_text()).get('jobs', [])
    matching = [job for job in jobs if job.get('name') == JOB]
    if not matching:
        env = os.environ.copy()
        env['HERMES_HOME'] = str(root)
        subprocess.run(['hermes', '--profile', 'default', 'cron', 'create', 'every 1m',
                        '--name', JOB, '--script', 'kanban-owner-alerts.py', '--no-agent',
                        '--deliver', 'local', '--workdir', str(source.parent.parent),
                        '--paused', '--paused-reason', 'Validate owner alerts before activation'], check=True, env=env)
    elif len(matching) != 1 or matching[0].get('script') != 'kanban-owner-alerts.py' or not matching[0].get('no_agent') or matching[0].get('schedule', {}).get('minutes') != 1:
        raise ValueError('Owner alert cron drift; repair the existing job instead of duplicating it')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dry-run', action='store_true')
    parser.add_argument('--install', action='store_true')
    args = parser.parse_args()
    root = Path(os.environ.get('HERMES_ROOT', str(Path.home() / '.hermes')))
    try:
        install(root) if args.install else tick(root, args.dry_run)
    except (ValueError, OSError, RuntimeError, sqlite3.Error, subprocess.SubprocessError) as exc:
        print(f'owner alerts: {exc}', file=sys.stderr)
        sys.exit(2)
