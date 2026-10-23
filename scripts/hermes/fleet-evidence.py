#!/usr/bin/env python3
"""Collect native run facts and resolve qualified cross-board outputs, query-only.

Python operations glue reuses Hermes' SQLite and durable attachments. It does
not execute commands, copy raw transcripts, accept work or alter task state.
"""
import argparse
from contextlib import contextmanager
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import sqlite3
import sys
import time

from hermes_common import atomic_write
from fleet_workflow import acceptance, native_contract, review_handoff

SOURCE = Path(__file__).resolve().parent
MAX_ROWS = 200


def safe_path(root, relative):
    root = root.absolute()
    path = root / relative
    if not path.is_relative_to(root) or '..' in path.relative_to(root).parts:
        raise ValueError('Evidence path leaves the fleet root')
    for candidate in (root, *path.parents, path):
        if candidate.is_relative_to(root) and candidate.is_symlink():
            raise ValueError('Evidence paths must not contain symlinks')
    return path


@contextmanager
def board_db(root, board):
    if not re.fullmatch(r'[A-Za-z0-9_-]{1,64}', board):
        raise ValueError('Invalid producer board')
    path = safe_path(root, Path('kanban/boards') / board / 'kanban.db')
    db = sqlite3.connect(path.as_uri() + '?mode=ro', uri=True, timeout=2)
    try:
        db.row_factory = sqlite3.Row
        db.execute('PRAGMA query_only=ON')
        deadline = time.monotonic() + 5
        db.set_progress_handler(lambda: int(time.monotonic() > deadline), 1000)
        db.execute('BEGIN')
        yield db
    finally:
        db.close()


def metadata_for(row):
    raw = row['metadata'] or '{}'
    if len(raw) > 65536:
        raise ValueError('Run metadata exceeds evidence bound')
    value = json.loads(raw)
    if not isinstance(value, dict):
        raise ValueError('Run metadata must be an object')
    return value


def output(root, board, task_id, name, version):
    if (not re.fullmatch(r't_[A-Za-z0-9_]{1,80}', task_id)
            or not re.fullmatch(r'[A-Za-z0-9_.-]{1,80}', name)
            or type(version) is not int or version < 1):
        raise ValueError('Invalid versioned output reference')
    with board_db(root, board) as db:
        task = db.execute('SELECT * FROM tasks WHERE id=?', (task_id,)).fetchone()
        run = db.execute('SELECT * FROM task_runs WHERE task_id=? ORDER BY id DESC LIMIT 1',
                         (task_id,)).fetchone()
        if (not task or task['status'] != 'done' or not run
                or run['profile'] != task['assignee']
                or run['profile'] not in {'feature-reviewer', 'project-auditor'}
                or run['status'] != 'done' or run['outcome'] != 'completed'):
            raise ValueError('Output needs a completed independent verification run')
        metadata = metadata_for(run)
        spec = importlib.util.spec_from_file_location('fleet_verdict', SOURCE / 'review-verdict-guard.py')
        guard = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(guard)
        guard.validate(metadata, profile=run['profile'])
        if metadata['verdict'] != 'accept' or not re.fullmatch(r'[a-f0-9]{40}|[a-f0-9]{64}', metadata['revision']):
            raise ValueError('Output needs acceptance of an exact source revision')
        if 'body' in task.keys() and native_contract(task['body'], db, task_id):
            acceptance(review_handoff(db, task_id), metadata, run['profile'])
        outputs = metadata.get('outputs')
        if not isinstance(outputs, list) or len(outputs) > 32:
            raise ValueError('No bounded output list was independently accepted')
        matches = [x for x in outputs if isinstance(x, dict) and x.get('name') == name
                   and type(x.get('version')) is int and x['version'] == version]
        if len(matches) != 1:
            raise ValueError('The requested output version is absent or ambiguous')
        result = matches[0]
        history = db.execute("SELECT metadata FROM task_runs WHERE task_id=? AND status='done'"
                             " AND outcome='completed' ORDER BY id DESC LIMIT 65", (task_id,)).fetchall()
        if len(history) > 64:
            raise ValueError('Output history exceeds validation bound; publish a distinct output task')
        for prior in history:
            previous = metadata_for(prior)
            if previous.get('verdict') != 'accept':
                continue
            for item in previous.get('outputs', []):
                if (isinstance(item, dict) and item.get('name') == name and item.get('version') == version
                        and (item.get('sha256') != result.get('sha256')
                             or previous.get('revision') != metadata.get('revision'))):
                    raise ValueError('An output version was reused for changed bytes/source; increment its version')
        if (type(result.get('attachment_id')) is not int
                or not isinstance(result.get('sha256'), str)
                or not re.fullmatch(r'[a-f0-9]{64}', result['sha256'])):
            raise ValueError('Output needs an actual attachment ID and full SHA256')
        attachment = db.execute('SELECT * FROM task_attachments WHERE task_id=? AND id=?',
                                (task_id, result['attachment_id'])).fetchone()
        if not attachment:
            raise ValueError('Accepted output attachment is missing')
        allowed = Path('kanban/boards') / board / 'attachments' / task_id
        stored = Path(attachment['stored_path'])
        if not stored.is_absolute():
            stored = root / stored
        if not stored.is_relative_to(root / allowed):
            raise ValueError('Output attachment leaves its producer task')
        path = safe_path(root, stored.relative_to(root))
        if not path.is_file() or path.stat().st_size > 256 * 1024 * 1024:
            raise ValueError('Output artifact is unavailable or exceeds the read bound')
        digest = hashlib.sha256()
        with path.open('rb') as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b''):
                digest.update(chunk)
        if digest.hexdigest() != result['sha256']:
            raise ValueError('Output artifact no longer matches its accepted digest')
        return dict(schema_version=1, board=board, task_id=task_id, run_id=run['id'],
                    name=name, version=version, revision=metadata['revision'],
                    attachment_id=result['attachment_id'], sha256=result['sha256'],
                    path=str(path))


def collect(root):
    """Bounded incremental capture; failures are retained and acceptance is copied."""
    cursor_path = safe_path(root, 'state/fleet/evidence-cursor.json')
    cursors = json.loads(cursor_path.read_text()) if cursor_path.exists() else {}
    captured = 0
    for path in sorted((root / 'kanban/boards').glob('*/kanban.db')):
        board = path.parent.name
        if board.startswith(('_', '.')):
            continue
        ended, rid = cursors.get(board, [0, 0])
        with board_db(root, board) as db:
            rows = db.execute('SELECT * FROM task_runs WHERE ended_at IS NOT NULL'
                              ' AND (ended_at>? OR (ended_at=? AND id>?))'
                              ' ORDER BY ended_at,id LIMIT ?', (ended, ended, rid, MAX_ROWS)).fetchall()
            for row in rows:
                if not re.fullmatch(r't_[A-Za-z0-9_]{1,80}', row['task_id']):
                    raise ValueError('Invalid evidence task ID')
                packet = {k: row[k] for k in ('id', 'task_id', 'profile', 'status', 'outcome',
                                               'started_at', 'ended_at')}
                packet.update(schema_version=1, board=board)
                try:
                    metadata = metadata_for(row)
                except (ValueError, TypeError):
                    metadata = {}
                    packet['metadata_error'] = 'malformed_or_oversize'
                    packet['metadata_sha256'] = hashlib.sha256(str(row['metadata']).encode()).hexdigest()
                packet.update({k: metadata[k] for k in ('revision', 'checks', 'verdict',
                                                       'independence', 'outputs') if k in metadata})
                target = safe_path(root, Path('state/fleet/evidence') / board / row['task_id'] / f'{row["id"]}.json')
                text = json.dumps(packet, sort_keys=True, indent=2) + '\n'
                if target.exists() and target.read_text() != text:
                    raise ValueError('Previously captured run evidence changed; retain both for investigation')
                if not target.exists():
                    atomic_write(target, text, mode=0o600)
                    captured += 1
                cursors[board] = [row['ended_at'], row['id']]
        atomic_write(cursor_path, json.dumps(cursors, sort_keys=True) + '\n', mode=0o600)
    return captured


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    commands.add_parser('collect')
    read = commands.add_parser('output')
    for field in ('board', 'task', 'name'):
        read.add_argument('--' + field, required=True)
    read.add_argument('--version', type=int, required=True)
    args = parser.parse_args()
    if args.command=='collect' and any(os.environ.get(k) for k in
            ('HERMES_KANBAN_TASK','HERMES_KANBAN_RUN_ID','HERMES_DELEGATED_CHILD_CONTEXT')):
        parser.error('Collection belongs to the local no-agent supervisor')
    root = Path(os.environ.get('HERMES_ROOT', str(Path.home() / '.hermes'))).absolute()
    result = ({'captured': collect(root)} if args.command == 'collect' else
              output(root, args.board, args.task, args.name, args.version))
    print(json.dumps(result, sort_keys=True))


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, sqlite3.Error) as exc:
        print('Fleet evidence unavailable: ' + str(exc), file=sys.stderr)
        sys.exit(1)
