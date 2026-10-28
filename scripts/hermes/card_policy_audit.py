#!/usr/bin/env python3
"""Observe persisted card-policy escapes, never rejected writes or board mutations.

Python/SQLite operations glue reuses the write guards as the policy source and
the steward's existing monitor/queue. No backend or dependency is introduced.
"""
from contextlib import closing
from functools import lru_cache
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import sqlite3
import sys
import time

sys.dont_write_bytecode = True

AGENTS = {'head-coordinator', 'standard-implementer', 'local-implementer',
          'feature-reviewer', 'project-auditor', 'board-steward', 'worker'}
SYSTEM = {'hermes-system', 'hermes-cron', 'system'}
ACTIVATION = 'state/card-policy-monitor.json'


@lru_cache(maxsize=1)
def validators():
    result = []
    for name in ('card-dependency-guard.py', 'owner-blocker-authoring-guard.py'):
        spec = importlib.util.spec_from_file_location('audit_' + name, Path(__file__).with_name(name))
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        result.append(module)
    return result


def fingerprint(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True).encode()).hexdigest()


def finding(board, task, location, rule, author, summary, evidence):
    key = fingerprint([board, task, location, rule])[:24]
    return dict(key=key, version=fingerprint([key, author, summary, evidence]),
                board=board, task_id=task, location=location, rule=rule,
                author=author, summary=summary)


def collect(root, now=None):
    root = Path(root)
    since = int(time.time() if now is None else now) - 86400
    activation = root / ACTIVATION
    if activation.exists():
        try:
            stamp = json.loads(activation.read_text())
            if (stamp.get('version') != 1 or type(stamp.get('comment_since')) is not int
                    or stamp['comment_since'] <= 0):
                raise ValueError('Invalid activation record')
        except (OSError, ValueError, AttributeError):
            return dict(findings=[], warnings=[dict(board='*', reason='policy activation unreadable')])
        since = max(since, stamp['comment_since'])
    dependencies, comments = validators()
    findings, warnings = [], []
    boards = root / 'kanban/boards'
    for path in sorted(boards.rglob('kanban.db')):
        parts = path.parent.relative_to(boards).parts
        if any(p.startswith(('.', '_')) for p in parts):
            continue
        board = '/'.join(parts)
        try:
            if not path.resolve().is_relative_to(boards.resolve()):
                raise ValueError('Board path leaves the board directory')
            with closing(sqlite3.connect(path.resolve().as_uri() + '?mode=ro', uri=True, timeout=1)) as db:
                db.row_factory = sqlite3.Row
                db.execute('PRAGMA query_only=ON')
                db.execute('BEGIN')
                deadline = time.monotonic() + 5
                db.set_progress_handler(lambda: int(time.monotonic() > deadline), 1000)
                if not db.execute('SELECT 1 FROM tasks LIMIT 1').fetchone():
                    continue
                tasks = [dict(r) for r in db.execute(
                    "SELECT * FROM tasks WHERE status NOT IN ('done','archived','cancelled') "
                    'ORDER BY id LIMIT 1001')]
                if len(tasks) > 1000:
                    warnings.append(dict(board=board, reason='open-card coverage truncated at 1000'))
                for task in tasks[:1000]:
                    body, author = task.get('body') or '', task.get('created_by')
                    if dependencies.guard(dict(tool_name='kanban_create', profile=author,
                                               tool_input=dict(body=body))):
                        findings.append(finding(board, task['id'], 'card', 'dependency-prose', author,
                            'Current card prose declares a prerequisite outside the graph fields.', body))
                    if task.get('block_kind') == 'dependency' and task['status'] == 'blocked':
                        parent = db.execute('SELECT 1 FROM task_links WHERE child_id=? LIMIT 1',
                                            (task['id'],)).fetchone()
                        if not parent:
                            findings.append(finding(board, task['id'], 'card', 'unlinked-dependency', author,
                                'Persisted dependency block has no formal parent.', task['block_kind']))
                    count, latest = db.execute(
                        'SELECT COUNT(*),MAX(created_at) FROM task_comments WHERE task_id=?',
                        (task['id'],)).fetchone()
                    if count > comments.CARD_COMMENT_LIMIT and (latest or 0) >= since:
                        findings.append(finding(board, task['id'], 'history', 'comment-budget', author,
                            f'{count} persisted comments exceed the {comments.CARD_COMMENT_LIMIT}-comment budget.', count))
                rows = db.execute('SELECT * FROM task_comments WHERE created_at>=? ORDER BY id LIMIT 5001',
                                  (since,)).fetchall()
                if len(rows) > 5000:
                    warnings.append(dict(board=board, reason='recent-comment coverage truncated at 5000'))
                for row in rows[:5000]:
                    body, author = row['body'] or '', row['author']
                    if author in SYSTEM:
                        continue  # Native transition producers have their own contracts.
                    location = 'comment:' + str(row['id'])
                    if dependencies.guard(dict(tool_name='kanban_comment', profile=author,
                                               tool_input=dict(body=body))):
                        findings.append(finding(board, row['task_id'], location, 'dependency-prose', author,
                            'Persisted comment encodes a card prerequisite.', body))
                    summary = re.search(r'^Blocking:', body, re.M) and re.search(r'^(?:Why owner|Unblock):', body, re.M)
                    agent = author in AGENTS or (isinstance(author, str) and
                        re.fullmatch(r'[a-z0-9][a-z0-9_-]{0,63}', author) and
                        (root / 'profiles' / author / 'state.db').is_file())
                    if agent and not summary and comments.comment_policy(body, author):
                        findings.append(finding(board, row['task_id'], location, 'comment-format', author,
                            f'Persisted routine comment has {len(body)} characters/{len(body.splitlines())} lines '
                            'or invalid Update/Evidence/Next fields.', body))
        except (sqlite3.Error, OSError, ValueError, TypeError, KeyError, IndexError) as exc:
            warnings.append(dict(board=board, reason=type(exc).__name__))
    return dict(findings=sorted(findings, key=lambda f: f['key']),
                warnings=sorted(warnings, key=lambda w: (w['board'], w['reason'])))


def monitor_lines(root, now=None):
    report = collect(root, now)
    pending, tracked = [], 0
    for item in report['findings']:
        delivery_id = hashlib.sha256(('steward-handoff:' + report_request_id(item)).encode()).hexdigest()
        receipt = Path(root) / 'profiles/board-steward/cron/bot_chat_pending' / (delivery_id + '.json')
        if receipt.exists():
            try:
                record = json.loads(receipt.read_text())
                if (record.get('id') != delivery_id or not isinstance(record.get('status'), str)
                        or record.get('profile') not in {'head-coordinator', item['author']}):
                    raise ValueError('Mismatched policy receipt')
                tracked += 1  # A handoff receipt is never proof of rectification.
            except (OSError, ValueError, AttributeError):
                report['warnings'].append(dict(board=item['board'], key=item['key'], reason='policy delivery unknown; do not replay'))
        else:
            pending.append(item)
    lines = ['CARD_POLICY ' + json.dumps(f, sort_keys=True) for f in pending[:24]]
    if len(pending) > 24:
        lines.append('CARD_POLICY_MORE ' + json.dumps(dict(omitted=len(pending) - 24, version=fingerprint(pending))))
    if tracked:
        lines.append(f'CARD_POLICY_TRACKED count={tracked} handoff-only-not-corrected')
    return lines + ['CARD_POLICY_UNKNOWN ' + json.dumps(w, sort_keys=True) for w in report['warnings']]


def current(root, key, version):
    match = next((f for f in collect(root)['findings'] if f['key'] == key and f['version'] == version), None)
    if match is None:
        raise ValueError('Policy finding changed or cleared; inspect again before reporting')
    return match


def recipient(root, item):
    author = item['author']
    if (item['rule'] not in {'comment-budget', 'unlinked-dependency'}
            and isinstance(author, str) and author not in {'owner', 'user', 'worker', 'board-steward', 'default'}
            and re.fullmatch(r'[a-z0-9][a-z0-9_-]{0,63}', author)
            and (Path(root) / 'profiles' / author / 'state.db').is_file()):
        return author
    return 'head-coordinator'


def report_request_id(item):
    # One queue identity across both routes prevents author+coordinator copies.
    return f"policy:{item['key']}:{item['version']}"


def message(item):
    action = {
        'comment-format': 'Use Update:/Evidence:/Next: in order, at most 400 characters and 8 lines, in future comments.',
        'comment-budget': 'Have head-coordinator obtain the required human review. Stop further comments; never reset the count or replace the card.',
        'unlinked-dependency': 'Inspect the actual missing result and link its producer as a formal parent before resuming the consumer.',
        'dependency-prose': 'Reconcile genuine prerequisites with parents/kanban_link and verify the graph. Remove redundant current body prose only through an authorized amendment.',
    }[item['rule']]
    return (f"Card-policy rectification: {item['board']}:{item['task_id']} {item['location']}\n"
            f"Evidence: {item['summary']}\n"
            f'Action: {action}\n'
            'Constraints: Act within existing authority on the same card; preserve gates and historical comments. '
            'Do not post acknowledgments or create replacement cards.\n'
            'Verify: Re-read the native card/graph and subsequent outputs. Queued is not corrected.')


if __name__ == '__main__':
    root = Path(os.environ.get('HERMES_ROOT', str(Path.home() / '.hermes')))
    for line in monitor_lines(root):
        print(line)
