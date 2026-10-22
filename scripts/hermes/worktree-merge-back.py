#!/usr/bin/env python3
"""Bounded merge-back helper for accepted worktree card branches.

Why
---
A `done`/`archived` card is the board's record that the work passed the
required review, but its commits stay in the card worktree until something
merges the branch into master. One unbounded "clear the backlog" model pass
doing inventory, conflict diagnosis, merge and validation in turn is exactly
the too-large slice shape that burned the coordinator's lanes in 2026-10-21
(runtime timeouts followed by protocol-violation exits). This helper
performs the mechanical part in one bounded, re-runnable invocation, so a
coordinator run narrows to: one card, one helper call, one receipt.

Side-effect safety:
  * never pushes or rewrites remote state;
  * never resolves conflicts by itself and never parks a dirty index;
  * leaves master either green (validated) or exactly as it found it;
  * a disrupted run re-merges nothing: the merge commit is durable git state
    and the next call reports the existing receipt instead.

Deterministic receipt + exit codes:
    0  receipt printed (merged / already integrated / disposed)
    2  refused: invalid input, unknown board/repo, unclean worktree,
       wrong integration head, or a disposition that names nothing
    3  merge conflicted (receipt names the files) or validation failed
       (merge reverted, master restored green)

Dispositions are card comments written through the native CLI by this
helper, body starting exactly with `merge-back disposition: ` authored by
head-coordinator -- so the board-health detector and the audit trail read
the same fact with no second state surface.
"""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys

sys.dont_write_bytecode = True

MAX_PLAN_COMMITS = 8
MAX_PLAN_FILES = 40
MAX_LIST = 20
DISPOSITION_MARKER = 'merge-back disposition: '
TASK_ID_RE = re.compile(r't_[a-z0-9_]{1,64}')


class Refused(Exception):
    """Refusal with a marker: the caller's input or environment, not a fault."""


def run_git(repo, args, timeout=60):
    return subprocess.run(['git', '-C', str(repo)] + args, text=True,
                          capture_output=True, timeout=timeout)


def git_out(repo, args, timeout=60):
    result = run_git(repo, args, timeout)
    if result.returncode != 0:
        raise ValueError('git %s failed: %s' % (' '.join(args), result.stderr.strip()[:200]))
    return result.stdout


def emit_receipt(obj):
    print('RECEIPT ' + json.dumps(obj, sort_keys=True))


def board_db(root, board):
    path = root / 'kanban' / 'boards' / board / 'kanban.db'
    if not path.is_file():
        raise Refused('BOARD_MISSING ' + board)
    return path


def branch_rows(conn):
    """Bounded observation: one row per wt branch owned by a done/archived card."""
    columns = {r[1] for r in conn.execute('PRAGMA table_info(tasks)')}
    if not {'id', 'status', 'branch_name'} <= columns:
        raise Refused('SCHEMA_UNSUPPORTED')
    title = ',substr(title,1,80)' if 'title' in columns else ",''"
    rows = conn.execute(
        "SELECT branch_name, MIN(id), MAX(status)" + title +
        " FROM tasks WHERE status IN ('done','archived')"
        " AND branch_name LIKE 'wt/%' GROUP BY branch_name ORDER BY branch_name"
    ).fetchall()
    result = []
    for branch, task_id, status, text in rows:
        if branch and task_id and TASK_ID_RE.fullmatch(task_id):
            result.append((branch, task_id, status, text or ''))
    return result


def disposed_tasks(conn):
    rows = conn.execute(
        "SELECT DISTINCT task_id FROM task_comments WHERE author = 'head-coordinator'"
        " AND body LIKE ?", (DISPOSITION_MARKER + '%',)).fetchall()
    return {row[0] for row in rows}


def branch_state(repo, branch):
    """(ahead_of_master, unapplied_commits); (None, 0) names a missing ref
    -- the durability detectors and the reaper treat that as already closed."""
    probe = run_git(repo, ['rev-parse', '--verify', '--quiet', branch + '^{commit}'])
    if probe.returncode != 0:
        return None, 0
    ahead = git_out(repo, ['rev-list', '--count', branch, '--not', 'master']).strip()
    if not ahead.isdigit():
        raise ValueError('unresolvable ahead count for ' + branch)
    if int(ahead) == 0:
        return 0, 0
    cherry = git_out(repo, ['cherry', 'master', branch])
    unapplied = sum(1 for line in cherry.splitlines() if line.startswith('+'))
    return int(ahead), unapplied


def detect_conflicts(repo, branch):
    """Conflict evidence from a virtual merge; never touches the worktree."""
    result = run_git(repo, ['merge-tree', '--write-tree', '--name-only',
                            'master', branch], timeout=120)
    if result.returncode != 0 and not result.stdout.strip():
        raise ValueError('merge-tree failed: ' + result.stderr.strip()[:200])
    # New-style output: tree oid, then the conflicted file names (the branch
    # name form: they contain '/'), then a blank line, then informational
    # messages. Files only, so receipts stay bounded and path-free.
    names = []
    for line in result.stdout.splitlines()[1:]:
        if not line:
            break
        names.append(line.strip())
    return names


def commit_subjects(repo, branch):
    log = git_out(repo, ['log', '--format=%h %s', '--max-count=%d' % (MAX_PLAN_COMMITS + 1),
                         'master..' + branch])
    lines = [line for line in log.splitlines() if line]
    omitted = max(0, len(lines) - MAX_PLAN_COMMITS)
    return lines[:MAX_PLAN_COMMITS], omitted


def resolve_repo(root, board):
    board_json = root / 'kanban' / 'boards' / board / 'board.json'
    if not board_json.is_file():
        raise Refused('BOARD_METADATA_MISSING ' + board)
    try:
        with open(board_json, encoding='utf-8') as fh:
            workdir = json.load(fh).get('default_workdir') or ''
    except ValueError:
        raise Refused('BOARD_METADATA_UNREADABLE ' + board)
    return Path(workdir) if workdir else None


def require_integration_head(repo):
    if run_git(repo, ['rev-parse', '--git-dir']).returncode != 0:
        raise Refused('REPO_NOT_A_WORKING_COPY')
    head = git_out(repo, ['rev-parse', '--abbrev-ref', 'HEAD']).strip()
    if head != 'master':
        raise Refused('NOT_ON_MASTER head=' + head)
    if run_git(repo, ['status', '--porcelain']).stdout.strip():
        raise Refused('UNCLEAN_WORKTREE')


def accepted_card(conn, branch):
    row = next((r for r in branch_rows(conn) if r[0] == branch), None)
    if row is None:
        raise Refused('NO_ACCEPTED_CARD ' + branch)
    return row[1], row[2], row[3]


def merge_step(root, repo, branch):
    board = os.environ.get('HERMES_BOARD', 'nixhomeserver')
    import sqlite3
    with sqlite3.connect(board_db(root, board)) as conn:
        task_id, card_status, _text = accepted_card(conn, branch)
    require_integration_head(repo)
    ahead, unapplied = branch_state(repo, branch)
    if ahead is None:
        raise Refused('BRANCH_MISSING ' + branch)
    if unapplied == 0:
        return 0, {'status': 'already_integrated', 'branch': branch, 'task_id': task_id}
    pre_head = git_out(repo, ['rev-parse', 'HEAD']).strip()
    pre_tree = git_out(repo, ['rev-parse', 'HEAD^{tree}']).strip()
    if run_git(repo, ['merge', '--no-ff', '--no-edit', branch],
               timeout=180).returncode != 0:
        # Parked index: abort it so the worktree stays clean for the next call.
        subprocess.run(['git', '-C', str(repo), 'merge', '--abort'],
                       capture_output=True, timeout=30)
        files = detect_conflicts(repo, branch)
        return 3, {'status': 'conflict', 'branch': branch, 'task_id': task_id,
                   'conflict_files': files[:MAX_PLAN_FILES],
                   'conflict_files_omitted': max(0, len(files) - MAX_PLAN_FILES)}
    post_tree = git_out(repo, ['rev-parse', 'HEAD^{tree}']).strip()
    if pre_tree == post_tree:
        git_out(repo, ['reset', '--hard', pre_head])
        return 0, {'status': 'already_integrated', 'branch': branch, 'task_id': task_id}
    verdict = validate_step(repo)
    if verdict not in ('pass', 'skipped'):
        # Master must not sit broken. Reducer: revert the merge commit so
        # master's tree is exactly as found, with an honest audit pair (merge
        # + revert). The branch and its acceptance are untouched; the
        # conflicting content needs a routed repair, not a second acceptance.
        if run_git(repo, ['revert', '--no-edit', 'HEAD'], timeout=120).returncode == 0:
            return 3, {'status': 'reverted', 'branch': branch, 'task_id': task_id,
                       'validate': verdict,
                       'note': 'master restored green; route the conflicting'
                               ' content as fresh repair, not a second acceptance'}
        return 3, {'status': 'merge_left_with_validation_failure',
                   'branch': branch, 'task_id': task_id,
                   'merge_commit': git_out(repo, ['rev-parse', 'HEAD']).strip(),
                   'validate': verdict}
    return 0, {'status': 'merged', 'branch': branch, 'task_id': task_id,
               'card_status': card_status,
               'merge_commit': git_out(repo, ['rev-parse', 'HEAD']).strip(),
               'validate': verdict}


def validate_step(repo):
    gate = repo / 'scripts' / 'validate-repo.sh'
    if not gate.is_file():
        return 'skipped'
    if run_git(repo, ['status', '--porcelain']).stdout.strip():
        raise ValueError('Refusing a dirty worktree validation')
    result = subprocess.run(['bash', str(gate)], cwd=str(repo), text=True,
                            timeout=1800, capture_output=True)
    return 'pass' if result.returncode == 0 else 'fail'


def list_backlog(root, repo):
    import sqlite3
    board = os.environ.get('HERMES_BOARD', 'nixhomeserver')
    with sqlite3.connect(board_db(root, board)) as conn:
        rows = branch_rows(conn)
        disposed = disposed_tasks(conn)
    if repo is None:
        # No recorded checkout: the merge-back cadence has nothing to read here.
        return 0
    lines, excess = [], 0
    for branch, task_id, status, _text in rows:
        if task_id in disposed:
            continue
        try:
            ahead, unapplied = branch_state(repo, branch)
        except ValueError:
            print('UNMERGED_UNKNOWN ' + task_id + ' branch=' + branch)
            continue
        if ahead is None or unapplied <= 0:
            continue
        line = ('UNMERGED_ACCEPTED_WORK ' + task_id + ' branch=' + branch +
                ' commits=' + str(unapplied) + ' card=' + status)
        if len(lines) < MAX_LIST:
            lines.append(line)
        else:
            excess += 1
    for line in lines:
        print(line)
    if excess:
        print('UNMERGED_EXCESS additional=%d needs=reduce-backlog' % excess)
    return 0


def plan_backlog(root, repo, branch):
    import sqlite3
    board = os.environ.get('HERMES_BOARD', 'nixhomeserver')
    with sqlite3.connect(board_db(root, board)) as conn:
        task_id, status, text = accepted_card(conn, branch)
    if repo is None:
        raise Refused('REPO_UNRESOLVED ' + branch)
    ahead, unapplied = branch_state(repo, branch)
    if ahead is None:
        print('RECEIPT ' + json.dumps({'status': 'branch_missing', 'branch': branch}, sort_keys=True))
        return 0
    conflicts = detect_conflicts(repo, branch)
    subjects, omitted = commit_subjects(repo, branch)
    emit_receipt({'status': 'conflict-plan' if conflicts else 'clean-plan',
                  'branch': branch, 'task_id': task_id, 'card_status': status,
                  'title': text[:80], 'commits_ahead': ahead,
                  'commits_unapplied': unapplied,
                  'conflict_files': conflicts[:MAX_PLAN_FILES],
                  'conflict_files_omitted': max(0, len(conflicts) - MAX_PLAN_FILES),
                  'commits': subjects, 'commits_omitted': omitted})
    return 0


def dispose(root, board, branch, reason):
    if not isinstance(reason, str) or not (1 <= len(' '.join(reason.split())) <= 240):
        raise Refused('REASON_REQUIRED 1..240 chars')
    reason = ' '.join(reason.split())
    repo = resolve_repo(root, board)
    if repo is None:
        raise Refused('REPO_UNRESOLVED ' + branch)
    import sqlite3
    with sqlite3.connect(board_db(root, board)) as conn:
        task_id, _status, _text = accepted_card(conn, branch)
    require_integration_head(repo)
    ahead, unapplied = branch_state(repo, branch)
    if ahead is None:
        raise Refused('BRANCH_MISSING ' + branch)
    if unapplied == 0:
        emit_receipt({'status': 'already_integrated', 'branch': branch})
        return 0
    message = DISPOSITION_MARKER + reason + ' (unapplied=%d)' % unapplied
    cli = os.environ.get('HERMES_BIN', 'hermes')
    result = subprocess.run(
        [cli, 'kanban', '--board', board, 'comment', task_id, message],
        text=True, capture_output=True, timeout=60,
        env=dict(os.environ, HERMES_KANBAN_HOME=str(root)))
    if result.returncode != 0:
        raise ValueError('comment write refused: ' + result.stderr.strip()[:200])
    emit_receipt({'status': 'disposed', 'task_id': task_id, 'branch': branch})
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__, allow_abbrev=False)
    parser.add_argument('--list', action='store_true')
    parser.add_argument('--plan', metavar='BRANCH')
    parser.add_argument('--merge', metavar='BRANCH')
    parser.add_argument('--dispose', metavar='BRANCH', help='requires --reason')
    parser.add_argument('--reason')
    args = parser.parse_args()
    root = Path(os.environ.get('HERMES_ROOT', str(Path.home() / '.hermes'))).resolve()
    board = os.environ.get('HERMES_BOARD', 'nixhomeserver')
    try:
        if args.list:
            return list_backlog(root, resolve_repo(root, board))
        if args.plan:
            return plan_backlog(root, resolve_repo(root, board), args.plan)
        if args.merge:
            code, receipt = merge_step(root, resolve_repo(root, board), args.merge)
            emit_receipt(receipt)
            return code
        if args.dispose:
            if not args.reason:
                parser.error('--dispose requires --reason')
            return dispose(root, board, args.dispose, args.reason)
        parser.error('one mode is required')
    except Refused as exc:
        print('MERGE_BACK_REFUSED ' + str(exc), file=sys.stderr)
        return 2
    except (OSError, ValueError, subprocess.SubprocessError) as exc:
        print('MERGE_BACK_ERROR ' + str(exc)[:300], file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())
