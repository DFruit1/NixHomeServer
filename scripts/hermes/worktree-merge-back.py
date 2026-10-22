#!/usr/bin/env python3
"""Bounded merge-back helper for accepted worktree card branches.

An explicit independent acceptance binds a card branch to its exact commit.
The coordinator can integrate one branch or a queue of at most eight pinned
candidates, validating after each merge and stopping at the first conflict,
failed gate, changed source or missing acceptance. Board status alone never
substitutes for acceptance. Observation and disposition remain available for
terminal cards whose acceptance needs repair.

Side-effect safety:
  * never pushes or rewrites remote state;
  * never resolves conflicts by itself and never parks a dirty index;
  * reverts failed validation without rewriting history;
  * preserves unrelated work if another writer changes the checkout;
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
from contextlib import closing, contextmanager
import fcntl
import sqlite3
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
MAX_QUEUE = 8
REVIEW_PROFILES = {'feature-reviewer', 'project-auditor'}
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
    # Patch-equivalent commits may deliberately reapply reverted content.
    # Cherry's patch-id shortcut would incorrectly suppress that composition.
    return int(ahead), int(ahead)


def unresolved_rollback(repo, revision):
    """Find a reverted candidate whose rollback is absent from its source base.

    Reverts keep failed merges in ancestry. A normal merge of a repair added to
    that old source then applies only the repair delta. Require composition on
    a source including the rollback, so its newly reviewed diff reconstructs
    the complete feature instead. The committed trailer survives restarts and
    checkout changes; no mutable side database or implicit reapply is needed.
    """
    records = git_out(repo, ['log', 'master', '--grep=^Hermes-Merge-Back-Rollback:',
                            '--format=%H%x09%(trailers:key=Hermes-Merge-Back-Rollback,valueonly)'])
    for line in records.splitlines():
        if not line.strip():
            continue
        rollback, separator, source = line.partition('\t')
        source = source.strip()
        if not separator or not re.fullmatch(r'[0-9a-f]{40}|[0-9a-f]{64}', source):
            raise Refused('ROLLBACK_RECORD_INVALID ' + rollback)
        contains_source = run_git(repo, ['merge-base', '--is-ancestor', source, revision])
        contains_rollback = run_git(repo, ['merge-base', '--is-ancestor', rollback, revision])
        if contains_source.returncode not in (0, 1) or contains_rollback.returncode not in (0, 1):
            raise Refused('ROLLBACK_ANCESTRY_UNKNOWN ' + rollback)
        if contains_source.returncode == 0 and contains_rollback.returncode == 1:
            return {'rollback_commit': rollback, 'reverted_revision': source}
    return None


def require_reconstructed_source(repo, branch, revision):
    rollback = unresolved_rollback(repo, revision)
    if rollback:
        raise Refused('RECONSTRUCTION_REQUIRED ' + branch + ' rollback=' + rollback['rollback_commit']
                      + ' source=' + rollback['reverted_revision']
                      + '; prepare complete reapply/composition from current master and independently review its new revision')


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


@contextmanager
def read_board(root, board):
    with closing(sqlite3.connect(board_db(root, board).resolve().as_uri() + '?mode=ro',
                                 uri=True, timeout=5)) as conn:
        conn.execute('PRAGMA query_only=ON')
        conn.execute('BEGIN')
        yield conn


def owning_card(conn, branch, allow_nonterminal=False):
    columns = {r[1] for r in conn.execute('PRAGMA table_info(tasks)')}
    if not {'id', 'status', 'branch_name'} <= columns:
        raise Refused('SCHEMA_UNSUPPORTED')
    title = 'substr(title,1,80)' if 'title' in columns else "''"
    owners = conn.execute('SELECT id,status,' + title +
                          ' FROM tasks WHERE branch_name=? LIMIT 2', (branch,)).fetchall()
    if len(owners) > 1:
        raise Refused('AMBIGUOUS_CARD_OWNER ' + branch)
    if not owners or not branch.startswith('wt/') or not isinstance(owners[0][0], str) \
            or not TASK_ID_RE.fullmatch(owners[0][0]):
        raise Refused(('NO_OWNING_CARD ' if allow_nonterminal else 'NO_ACCEPTED_CARD ') + branch)
    task_id, status, text = owners[0]
    # Review planning must precede acceptance. Only observation opts out of the
    # terminal-state requirement; every mutation retains the stricter default.
    if not allow_nonterminal and status not in ('done', 'archived'):
        raise Refused('NO_ACCEPTED_CARD ' + branch)
    return task_id, status, text or ''


def accepted_card(conn, branch, revision):
    task_id, status, title = owning_card(conn, branch)
    # Native request-review keeps the owning task; independently created review
    # cards can be prerequisites or consumers. Only explicit edges qualify,
    # never an unrelated acceptance that happens to name the same commit.
    review_ids = {task_id}
    for parent, child in conn.execute(
            'SELECT parent_id,child_id FROM task_links WHERE parent_id=? OR child_id=?',
            (task_id, task_id)):
        review_ids.update((parent, child))
    owner = conn.execute('SELECT assignee FROM tasks WHERE id=?', (task_id,)).fetchone()[0]
    implementers = {owner}
    for payload, in conn.execute(
            "SELECT payload FROM task_events WHERE task_id=? AND kind='review_requested' ORDER BY id DESC LIMIT 1",
            (task_id,)):
        try:
            implementer = json.loads(payload or '{}').get('implementer')
        except (ValueError, AttributeError):
            implementer = None
        if implementer:
            implementers = {implementer}
    # Historical implementation runs remain provenance after reassignment.
    for profile, outcome in conn.execute('SELECT profile,outcome FROM task_runs WHERE task_id=?', (task_id,)):
        if outcome == 'review_requested':
            implementers.add(profile)
    if not implementers or not all(isinstance(profile, str) and profile.strip() for profile in implementers):
        raise Refused('IMPLEMENTER_PROVENANCE_MISSING ' + task_id)
    evidence = []
    columns = {r[1] for r in conn.execute('PRAGMA table_info(tasks)')}
    for review_id in review_ids:
        review = conn.execute('SELECT assignee,status FROM tasks WHERE id=?', (review_id,)).fetchone()
        if not review:
            continue
        if 'tenant' in columns and review_id != task_id:
            tenant = conn.execute('SELECT tenant FROM tasks WHERE id=?', (review_id,)).fetchone()[0]
            if tenant in {'continuous-improvement', 'review-question'}:
                continue
        run = conn.execute('SELECT id,profile,status,outcome,metadata FROM task_runs WHERE task_id=? ORDER BY id DESC LIMIT 1',
                           (review_id,)).fetchone()
        if run and (review[0] in REVIEW_PROFILES or run[1] in REVIEW_PROFILES):
            evidence.append((run, review, review_id))
    if not evidence:
        raise Refused('NO_INDEPENDENT_ACCEPTANCE ' + task_id)
    # Latest independent review is authoritative, including a failed new run.
    run, review, review_id = max(evidence, key=lambda item: item[0][0])
    _run_id, profile, run_status, outcome, metadata = run
    if review[1] not in ('done', 'archived') or profile != review[0] or profile in implementers \
            or run_status != 'done' or outcome != 'completed':
        raise Refused('NO_INDEPENDENT_ACCEPTANCE ' + review_id)
    try:
        metadata = json.loads(metadata or '{}')
        checks = metadata.get('checks')
        independence = metadata.get('independence')
        if profile == 'project-auditor' and (not isinstance(independence, dict)
                or independence.get('plan_author') is not False
                or independence.get('implementer') is not False):
            raise Refused('AUDITOR_INDEPENDENCE_REQUIRED ' + review_id)
        valid = (metadata.get('verdict') == 'accept' and metadata.get('revision') == revision
                 and isinstance(checks, list) and bool(checks)
                 and all(isinstance(check, dict) and isinstance(check.get('command'), str)
                         and bool(check['command'].strip()) and type(check.get('exit_code')) is int
                         and check['exit_code'] == 0 for check in checks))
    except (ValueError, AttributeError, TypeError):
        valid = False
    if not valid:
        raise Refused('ACCEPTANCE_MISMATCH ' + review_id + ' revision=' + revision)
    return task_id, status, title


@contextmanager
def integration_lock(repo):
    if repo is None:
        raise Refused('REPO_UNRESOLVED')
    common = Path(git_out(repo, ['rev-parse', '--git-common-dir']).strip())
    if not common.is_absolute():
        common = repo / common
    with open(common / 'hermes-merge-back.lock', 'a', encoding='utf-8') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise Refused('MERGE_ALREADY_RUNNING')
        yield


def merge_step(root, repo, branch, expected_revision=None, expected_master=None):
    with integration_lock(repo):
        return merge_locked(root, repo, branch, expected_revision, expected_master)


def merge_locked(root, repo, branch, expected_revision=None, expected_master=None):
    board = os.environ.get('HERMES_BOARD', 'nixhomeserver')
    require_integration_head(repo)
    if not branch.startswith('wt/'):
        raise Refused('CARD_BRANCH_REQUIRED ' + branch)
    revision = git_out(repo, ['rev-parse', '--verify', branch + '^{commit}']).strip()
    if expected_revision is not None and revision != expected_revision:
        raise Refused('BRANCH_CHANGED ' + branch)
    if expected_master is not None and git_out(repo, ['rev-parse', 'HEAD']).strip() != expected_master:
        raise Refused('MASTER_CHANGED')
    with read_board(root, board) as conn:
        task_id, card_status, _text = accepted_card(conn, branch, revision)
    require_reconstructed_source(repo, branch, revision)
    ahead, unapplied = branch_state(repo, branch)
    if ahead is None:
        raise Refused('BRANCH_MISSING ' + branch)
    if unapplied == 0:
        # Ancestry survives a run interrupted before validation. With no durable
        # gate receipt, retry the integration gate before claiming success;
        # never revert an earlier merge whose execution this run does not own.
        integrated_head = git_out(repo, ['rev-parse', 'HEAD']).strip()
        try:
            verdict = validate_step(repo)
            require_integration_head(repo)
            if git_out(repo, ['rev-parse', 'HEAD']).strip() != integrated_head:
                raise Refused('MASTER_CHANGED')
            if git_out(repo, ['rev-parse', '--verify', branch + '^{commit}']).strip() != revision:
                raise Refused('BRANCH_CHANGED ' + branch)
            with read_board(root, board) as conn:
                accepted_card(conn, branch, revision)
            if verdict not in ('pass', 'skipped'):
                raise Refused('VALIDATION_' + verdict)
        except (Refused, OSError, ValueError, sqlite3.Error, subprocess.SubprocessError) as exc:
            return 3, {'status': 'integration_unverified', 'branch': branch, 'task_id': task_id,
                       'revision': revision, 'integration_head': integrated_head,
                       'reason': str(exc)[:200]}
        return 0, {'status': 'already_integrated', 'branch': branch, 'task_id': task_id,
                   'revision': revision, 'integration_head': integrated_head, 'validate': verdict}
    if run_git(repo, ['merge', '--no-ff', '--no-edit', revision],
               timeout=180).returncode != 0:
        # Parked index: abort it so the worktree stays clean for the next call.
        subprocess.run(['git', '-C', str(repo), 'merge', '--abort'],
                       capture_output=True, timeout=30)
        files = detect_conflicts(repo, branch)
        return 3, {'status': 'conflict', 'branch': branch, 'task_id': task_id,
                   'conflict_files': files[:MAX_PLAN_FILES],
                   'conflict_files_omitted': max(0, len(files) - MAX_PLAN_FILES)}
    merged_head = git_out(repo, ['rev-parse', 'HEAD']).strip()
    try:
        verdict = validate_step(repo)
    except (OSError, ValueError, subprocess.SubprocessError) as exc:
        verdict = 'error:' + type(exc).__name__
    # A validator or unrelated writer must never have its work reverted.
    if git_out(repo, ['rev-parse', 'HEAD']).strip() != merged_head \
            or run_git(repo, ['status', '--porcelain']).stdout.strip():
        return 3, {'status': 'integration_changed', 'branch': branch, 'task_id': task_id,
                   'merge_commit': merged_head, 'validate': verdict}
    if verdict in ('pass', 'skipped'):
        try:
            if git_out(repo, ['rev-parse', '--verify', branch + '^{commit}']).strip() != revision:
                raise Refused('BRANCH_CHANGED ' + branch)
            with read_board(root, board) as conn:
                accepted_card(conn, branch, revision)
        except (Refused, OSError, ValueError, sqlite3.Error, subprocess.SubprocessError) as exc:
            verdict = 'acceptance_changed:' + str(exc)[:160]
    if verdict not in ('pass', 'skipped'):
        # Record the rejected source in the rollback commit itself: ancestry
        # alone can never again mistake this failed integration for success.
        rollback_message = ('Revert failed Hermes integration ' + merged_head + '\n\n'
                            'Validation or acceptance failed; reconstruct the full feature from current master.\n\n'
                            'Hermes-Merge-Back-Rollback: ' + revision + '\n'
                            'Hermes-Merge-Back-Merge: ' + merged_head)
        if run_git(repo, ['revert', '--no-commit', '-m', '1', merged_head], timeout=120).returncode == 0 \
                and run_git(repo, ['commit', '-m', rollback_message], timeout=120).returncode == 0:
            return 3, {'status': 'reverted', 'branch': branch, 'task_id': task_id,
                       'validate': verdict, 'revision': revision, 'merge_commit': merged_head,
                       'rollback_commit': git_out(repo, ['rev-parse', 'HEAD']).strip(),
                       'note': 'master tree restored; prepare complete reapply/composition from current master'
                               ' and independently review its new revision before merging'}
        return 3, {'status': 'merge_left_with_validation_failure',
                   'branch': branch, 'task_id': task_id,
                   'merge_commit': git_out(repo, ['rev-parse', 'HEAD']).strip(),
                   'validate': verdict}
    return 0, {'status': 'merged', 'branch': branch, 'task_id': task_id,
               'card_status': card_status, 'revision': revision,
               'merge_commit': git_out(repo, ['rev-parse', 'HEAD']).strip(),
               'validate': verdict}


def merge_queue(root, repo, candidates, max_merges):
    if type(max_merges) is not int or not 1 <= max_merges <= MAX_QUEUE \
            or not candidates or len(candidates) > max_merges \
            or len({branch for branch, _sha in candidates}) != len(candidates):
        raise Refused('QUEUE_BOUND 1..%d distinct candidates required' % MAX_QUEUE)
    board = os.environ.get('HERMES_BOARD', 'nixhomeserver')
    with integration_lock(repo):
        require_integration_head(repo)
        expected_master = git_out(repo, ['rev-parse', 'HEAD']).strip()
        # Refuse an invalid plan before integrating any prefix of that plan.
        with read_board(root, board) as conn:
            for branch, sha in candidates:
                if not branch.startswith('wt/') or not re.fullmatch(r'[0-9a-f]{40}|[0-9a-f]{64}', sha):
                    raise Refused('QUEUE_PIN_REQUIRED ' + branch)
                if git_out(repo, ['rev-parse', '--verify', branch + '^{commit}']).strip() != sha:
                    raise Refused('BRANCH_CHANGED ' + branch)
                accepted_card(conn, branch, sha)
                require_reconstructed_source(repo, branch, sha)
        results = []
        for branch, sha in candidates:
            try:
                code, receipt = merge_locked(root, repo, branch, sha, expected_master)
            except (Refused, OSError, ValueError, sqlite3.Error, subprocess.SubprocessError) as exc:
                return 2, {'status': 'queue_stopped', 'results': results, 'blocked_branch': branch,
                           'reason': str(exc)}
            results.append(receipt)
            if code:
                return code, {'status': 'queue_stopped', 'results': results}
            expected_master = git_out(repo, ['rev-parse', 'HEAD']).strip()
        return 0, {'status': 'queue_complete', 'results': results}


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
    board = os.environ.get('HERMES_BOARD', 'nixhomeserver')
    with read_board(root, board) as conn:
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
            rollback = unresolved_rollback(repo, branch) if ahead is not None else None
        except ValueError:
            print('UNMERGED_UNKNOWN ' + task_id + ' branch=' + branch)
            continue
        if rollback:
            line = ('UNMERGED_REVERTED_WORK ' + task_id + ' branch=' + branch
                    + ' rollback=' + rollback['rollback_commit'] + ' needs=reviewed-composition')
        elif ahead is None or unapplied <= 0:
            continue
        else:
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
    board = os.environ.get('HERMES_BOARD', 'nixhomeserver')
    with read_board(root, board) as conn:
        task_id, status, text = owning_card(conn, branch, allow_nonterminal=True)
    if repo is None:
        raise Refused('REPO_UNRESOLVED ' + branch)
    ahead, unapplied = branch_state(repo, branch)
    if ahead is None:
        print('RECEIPT ' + json.dumps({'status': 'branch_missing', 'branch': branch}, sort_keys=True))
        return 0
    rollback = unresolved_rollback(repo, branch)
    if rollback:
        emit_receipt({'status': 'reconstruction-required', 'branch': branch, 'task_id': task_id,
                      **rollback, 'next_step': 'compose complete reapply from current master; review its new revision'})
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
    with read_board(root, board) as conn:
        task_id, _status, _text = owning_card(conn, branch)
    require_integration_head(repo)
    ahead, unapplied = branch_state(repo, branch)
    if ahead is None:
        raise Refused('BRANCH_MISSING ' + branch)
    rollback = unresolved_rollback(repo, branch)
    if unapplied == 0 and not rollback:
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
    modes = parser.add_mutually_exclusive_group(required=True)
    modes.add_argument('--list', action='store_true')
    modes.add_argument('--plan', metavar='BRANCH')
    modes.add_argument('--merge', metavar='BRANCH')
    modes.add_argument('--dispose', metavar='BRANCH', help='requires --reason')
    modes.add_argument('--queue', nargs='+', metavar='BRANCH@SHA',
                       help='explicit pinned candidates, stopping at the first failure')
    parser.add_argument('--max-merges', type=int, default=4, help='queue limit, 1..8 (default: 4)')
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
        if args.queue:
            candidates = []
            for pin in args.queue:
                branch, separator, sha = pin.rpartition('@')
                if not separator:
                    raise Refused('QUEUE_PIN_REQUIRED ' + pin)
                candidates.append((branch, sha))
            code, receipt = merge_queue(root, resolve_repo(root, board), candidates, args.max_merges)
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
    except (OSError, ValueError, sqlite3.Error, subprocess.SubprocessError) as exc:
        print('MERGE_BACK_ERROR ' + str(exc)[:300], file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())
