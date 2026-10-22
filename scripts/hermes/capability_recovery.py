#!/usr/bin/env python3
"""Observe capability holds and queue deterministic coordinator handoffs.

Python operations glue reuses Hermes' read-only board evidence, fixed-recipient
delivery and scheduler backoff. No board mutations, backend or dependency.
"""
import argparse
from contextlib import closing
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import sqlite3
import stat
import subprocess
import sys
import time

sys.dont_write_bytecode = True

MAX_OPEN = 1000
HELPERS = ('scripts/fixture-runner.py', 'scripts/autonomy-policy.py',
           'scripts/repair-task-workspace.py',
           'scripts/worker_origin.py',
           'hermes-agent/hermes_cli/nixhomeserver_worker_origin.py',
           'hermes-agent/hermes_cli/nixhomeserver_resume_recovered.py',
           'scripts/steward-coordinator-request.py',
           'scripts/hermes-capability-recovery.md', 'scripts/hermes-coordinator-reference.md',
           'hermes-agent/hermes_cli/nixhomeserver_autonomy.py',
           'hermes-agent/tools/kanban_tools.py')
PARKED = {'blocked', 'scheduled', 'todo', 'triage'}


def workspace_identity(value, observations):
    """Observe committed identity only; never run status, hooks, filters or fetch.

    A directory's existence is insufficient: source repairs must wake the
    consumer even when its path was already present. Git discovery cannot
    silently borrow an enclosing checkout's identity.
    """
    if not value:
        return {'state': 'unassigned'}
    if value in observations:
        return observations[value]
    if len(observations) >= 64:
        raise ValueError('Workspace observation bound exceeded')
    path = Path(value)
    if path.is_symlink():
        result = {'state': 'symlink'}
    elif not path.is_dir():
        result = {'state': 'missing'}
    elif not (path / '.git').exists():
        result = {'state': 'directory'}
    else:
        env = dict(os.environ)
        env.update(GIT_OPTIONAL_LOCKS='0', GIT_TERMINAL_PROMPT='0',
                   GIT_CEILING_DIRECTORIES=str(path.absolute().parent))
        # Ignore ambient Git location overrides, never worker/delegation pins.
        for key in ('GIT_DIR', 'GIT_WORK_TREE', 'GIT_COMMON_DIR'):
            env.pop(key, None)
        try:
            probe = subprocess.run(
                ['git', '--no-optional-locks', '-C', str(path), 'rev-parse',
                 '--show-toplevel', 'HEAD', 'HEAD^{tree}'],
                capture_output=True, text=True, env=env, timeout=.5)
            lines = probe.stdout.splitlines()
            if (probe.returncode == 0 and len(lines) == 3
                    and Path(lines[0]).resolve() == path.resolve()
                    and all(re.fullmatch(r'[0-9a-f]{40,64}', x) for x in lines[1:])):
                result = dict(state='git-root', revision=lines[1], tree=lines[2])
            else:
                result = {'state': 'unqualified-git-root'}
        except (OSError, subprocess.TimeoutExpired):
            # Failure cannot be treated as a missing/unchanged prerequisite.
            raise ValueError('Workspace Git identity unavailable') from None
    observations[value] = result
    return result


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


def helper_identity(root):
    values = []
    root = root.resolve()
    for name in HELPERS:
        path = root / name
        try:
            info = path.lstat()
            if (not stat.S_ISREG(info.st_mode) or info.st_size > 1024 * 1024
                    or not path.resolve().is_relative_to(root)):
                values.append([name, 'unsupported'])
                continue
            # NOFOLLOW/NONBLOCK also refuse a concurrent replacement by a link/FIFO.
            fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
            with os.fdopen(fd, 'rb') as stream:
                actual = os.fstat(stream.fileno())
                if not stat.S_ISREG(actual.st_mode):
                    raise ValueError('Unsupported helper file')
                data = stream.read(1024 * 1024 + 1)
            if len(data) > 1024 * 1024:
                raise ValueError('Helper file exceeds observation bound')
            values.append([name, hashlib.sha256(data).hexdigest()])
        except FileNotFoundError:
            values.append([name, 'missing'])
        except OSError:
            values.append([name, 'unavailable'])
    return digest(values)


def attachments(root, board, tid):
    base = root / 'kanban/boards' / board
    directory = base / 'attachments' / tid
    if not directory.exists():
        return []
    if directory.is_symlink() or not directory.resolve().is_relative_to(base.resolve()):
        raise ValueError('Attachment directory leaves its board')
    entries = sorted(directory.iterdir())
    if len(entries) > 128:
        raise ValueError('Attachment observation bound exceeded')
    return [[p.name, p.lstat().st_size, p.lstat().st_mtime_ns] for p in entries]


def prerequisite_results(db, parents, tables):
    """Observe changed decisions even when the prerequisite stays done."""
    if 'task_runs' not in tables:
        return []
    result = []
    for parent in parents:
        run = db.execute('SELECT id,status,outcome,metadata FROM task_runs WHERE task_id=? '
                         'ORDER BY id DESC LIMIT 1', (parent[0],)).fetchone()
        if run is None:
            continue
        raw = run['metadata'] or '{}'
        if not isinstance(raw, str) or len(raw) > 64000:
            raise ValueError('Prerequisite result exceeds observation bound')
        metadata = json.loads(raw)
        if not isinstance(metadata, dict):
            raise ValueError('Unsupported prerequisite result')
        # Hash structured evidence, never expose arbitrary result contents.
        result.append([parent[0], run['id'], run['status'], run['outcome'], digest(metadata)])
    return result


def read_board(db, root, board, helpers, workspaces=None):
    """Use the caller's query-only transaction so each board is coherent."""
    workspaces = {} if workspaces is None else workspaces
    columns = {r[1] for r in db.execute('PRAGMA table_info(tasks)')}
    if not {'id', 'status', 'assignee', 'block_kind'} <= columns:
        raise ValueError('Unsupported task schema')
    extras = ','.join(k if k in columns else 'NULL AS ' + k for k in ('body', 'workspace_path'))
    rows = db.execute("SELECT id,status,assignee,block_kind," + extras +
                      " FROM tasks WHERE status NOT IN ('done','archived') ORDER BY id LIMIT ?",
                      (MAX_OPEN + 1,)).fetchall()
    if len(rows) > MAX_OPEN:
        raise ValueError('Open task observation bound exceeded')
    tables = {r[0] for r in db.execute("SELECT name FROM sqlite_master WHERE type='table'")}
    result = []
    for row in rows:
        task = dict(row)
        if task['status'] not in PARKED:
            continue
        tid = task['id']
        if not re.fullmatch(r't_[a-z0-9_]{1,64}', tid):
            raise ValueError('Unsupported task identity')
        event = (db.execute("SELECT kind,payload FROM task_events WHERE task_id=? "
                            "AND kind IN ('blocked','block_loop_detected','unblocked','completed',"
                            "'scheduled','block_reclassified') ORDER BY id DESC LIMIT 1",
                            (tid,)).fetchone() if 'task_events' in tables else None)
        block = json.loads(event['payload'] or '{}') if event else {}
        if not isinstance(block, dict):
            raise ValueError('Unsupported block event')
        technical_wait = bool(event and event['kind'] == 'scheduled' and task['status'] == 'scheduled'
                              and re.search(r'Input supplier:\s*(agent|model/provider|external-source-owner\()',
                                            str(block.get('reason', ''))))
        if event and event['kind'] == 'scheduled' and not technical_wait:
            # Scheduling does not itself release the preceding capability block.
            event = db.execute("SELECT kind,payload FROM task_events WHERE task_id=? "
                               "AND kind IN ('blocked','block_loop_detected','unblocked','completed','block_reclassified') ORDER BY id DESC LIMIT 1",
                               (tid,)).fetchone()
            block = json.loads(event['payload'] or '{}') if event else {}
            if not isinstance(block, dict):
                raise ValueError('Unsupported block event')
        if event and event['kind'] in {'unblocked', 'completed'}:
            continue  # A later successful release ends the historical hold episode.
        if event and event['kind'] == 'block_reclassified':
            # A reclassification renames the current hold episode in place; the
            # newest kind is authoritative. A capability hold that an owner-
            # directed audit reclassified to another kind is not a capability
            # hold any more, and re-queuing its stale pre-reclassification
            # version would reproduce a request the disposition already
            # consumed (the repeat-request loop).
            # Older native classification records carry only a reason. The
            # current row supplies that missing field in this same snapshot;
            # an explicitly malformed new_kind still fails coverage below.
            new_kind = block.get('new_kind', task['block_kind'])
            if not isinstance(new_kind, str) or not re.fullmatch(r'[a-z][a-z_]{0,31}', new_kind):
                raise ValueError('Unsupported block reclassification')
            block['kind'] = new_kind
        if not technical_wait and block.get('kind', task['block_kind']) != 'capability':
            continue
        reason = block.get('reason') or 'No recorded capability reason; coordinator must reconcile.'
        if not isinstance(reason, str) or len(reason) > 64000 or len(task['body'] or '') > 64000:
            raise ValueError('Capability evidence exceeds observation bound')
        supplier = re.search(r'Input supplier:\s*(owner|agent|model/provider|external-source-owner\([^\n)]+\))', reason)
        parents = [list(p) for p in db.execute(
            "SELECT l.parent_id,coalesce(t.status,'missing'),t.block_kind FROM task_links l "
            'LEFT JOIN tasks t ON t.id=l.parent_id WHERE l.child_id=? ORDER BY l.parent_id LIMIT 129', (tid,))]
        if len(parents) > 128:
            raise ValueError('Prerequisite observation bound exceeded')
        workspace = task['workspace_path']
        inputs = dict(task=task, reason=reason, parents=parents, helpers=helpers,
                      prerequisite_results=prerequisite_results(db, parents, tables),
                      workspace_present=bool(workspace and Path(workspace).is_dir()),
                      workspace_identity=workspace_identity(workspace, workspaces),
                      attachments=attachments(root, board, tid))
        result.append(dict(key=board + ':' + tid, board=board, task_id=tid,
                           version=digest(inputs), status=task['status'], assignee=task['assignee'],
                           supplier=supplier[1] if supplier else 'unclassified',
                           reason=' '.join(reason.split())[:1200], parents=parents,
                           workspace_present=inputs['workspace_present'],
                           workspace_identity=inputs['workspace_identity'],
                           attachment_count=len(inputs['attachments'])))
    return result


def report(root):
    root = Path(root).resolve()
    base = root / 'kanban/boards'
    paths = sorted(set(base.glob('*/kanban.db')) |
                   {p.with_name('kanban.db') for p in base.glob('*/board.json')})
    result = dict(schema_version=1, holds=[], warnings=[])
    helpers = helper_identity(root)
    workspaces = {}
    boards = [p for p in paths if not p.parent.name.startswith(('_', '.'))]
    if not boards:
        result['warnings'].append('no_active_boards')
    if len(boards) > 32:
        result['warnings'].append('board_observation_bound_exceeded')
        return result
    for path in boards:
        board = path.parent.name
        try:
            if not re.fullmatch(r'[a-z0-9][a-z0-9_-]{0,63}', board) or not path.resolve().is_relative_to(base):
                raise ValueError('Invalid board location')
            with closing(sqlite3.connect(path.resolve().as_uri() + '?mode=ro', uri=True, timeout=.2)) as db:
                db.row_factory = sqlite3.Row
                db.execute('PRAGMA query_only=ON')
                deadline = time.monotonic() + 2
                db.set_progress_handler(lambda: int(time.monotonic() > deadline), 1000)
                db.execute('BEGIN')
                result['holds'].extend(read_board(db, root, board, helpers, workspaces))
        except (OSError, ValueError, TypeError, sqlite3.Error):
            result['warnings'].append(board + ':missing_unreadable_unsupported_or_oversize')
    return result


def monitor_lines(data, limit=20):
    lines = [f"CAPABILITY_HOLD {h['key']} version={h['version']} status={h['status']} "
             f"supplier={h['supplier']} :: {h['reason'][:260]}" for h in data['holds'][:limit]]
    if len(data['holds']) > limit:
        # Include omitted identities in the hash; a change there must not disappear.
        lines.append(f"CAPABILITY_MORE {len(data['holds']) - limit} version=" + digest(data['holds'][limit:]))
    lines.extend('CAPABILITY_COVERAGE ' + warning for warning in data['warnings'])
    return lines


def handoff(root, key, version, queue=None):
    data = report(root)
    if data['warnings']:
        raise ValueError('Incomplete capability coverage; reconcile before queuing recovery')
    hold = next((h for h in data['holds'] if h['key'] == key), None)
    if hold is None or hold['version'] != version:
        raise ValueError('Recovery input changed; inspect the current hold before requesting action')
    if queue is None:
        spec = importlib.util.spec_from_file_location('steward_handoff', Path(__file__).with_name('steward-coordinator-request.py'))
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        queue = module.queue_request
    # The payload and request ID are both deterministic; an acknowledgment cannot
    # generate a new request or collide with an earlier ID's immutable payload.
    message = ('Goal: resolve this existing capability hold through actual accepted results.\n'
               'Evidence: ' + json.dumps(hold, sort_keys=True) + '\n'
               'Action: read ~/.hermes/scripts/hermes-capability-recovery.md, recheck current native '
               'evidence and existing ownership, then supply the missing supported capability/input '
               'or route one bounded repair using existing cards. Make informed reversible choices '
               'with backups/rollback; ask project-auditor for substantive plan/provenance decisions.\n'
               'Verify: record actual input/capability evidence and native readback; keep the owning '
               'handoff open through independent acceptance and its required activation result.\n'
               'Constraints: no duplicate writer/audit, unchanged retry, pin bypass, invented receipt '
               'or weakened secret/destructive/exposure/review/deploy gate. Owner-only input goes '
               'through your existing checked owner-gate route. Queuing is not resolution.')
    return queue(Path(root), 'capability-recovery:' + digest([key, version]), message)


def main():
    parser = argparse.ArgumentParser(description=__doc__, allow_abbrev=False)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument('--inspect', action='store_true')
    mode.add_argument('--monitor', action='store_true')
    mode.add_argument('--handoff', nargs=2, metavar=('BOARD:TASK', 'VERSION'))
    args = parser.parse_args()
    root = Path(os.environ.get('HERMES_ROOT', str(Path.home() / '.hermes')))
    if args.handoff:
        try:
            print(json.dumps(handoff(root, *args.handoff)))
            return 0
        except (ValueError, OSError, ImportError) as exc:
            print('Capability handoff refused: ' + str(exc), file=sys.stderr)
            return 2
    data = report(root)
    print('\n'.join(monitor_lines(data)) if args.monitor else json.dumps(data, sort_keys=True))
    return 2 if data['warnings'] else 0


if __name__ == '__main__':
    sys.exit(main())
