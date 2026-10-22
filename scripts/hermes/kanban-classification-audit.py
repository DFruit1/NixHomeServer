#!/usr/bin/env python3
"""Periodic classification audit for kanban cards.

Catches misclassified blocks that slipped past the authoring guard or were
created before the guard existed. Flags cards where:
  - block_kind is 'capability' but the reason describes a dependency pattern
  - block_kind is 'dependency' but no open prerequisite is linked
  - block_kind is missing but the card is blocked with a dependency-like reason
  - card is blocked but no blocker reason is recorded at all

Run as a cron job or from kanban-board-health.sh. Read-only: it reports
findings but never mutates the board. The coordinator applies corrections.
"""
import argparse
import json
import os
from pathlib import Path
import re
import sqlite3
import sys
import time

OPEN_STATUSES = ('triage', 'todo', 'ready', 'scheduled', 'blocked', 'review')
BLOCK_KINDS = {'capability', 'dependency', 'needs_input', 'transient'}

# Patterns that indicate a dependency, not a capability gap.
DEPENDENCY_PATTERNS = [
    re.compile(r'\bwaiting on\b.*\b(?:card|task|review|verdict|findings|output|producer|reviewer)\b', re.I),
    re.compile(r'\b(?:waiting|blocked|pending|depends?|until|after|once)\b[^.\n]{0,80}\bt_\d{6,}\b', re.I),
    re.compile(r'\bt_\d{6,}\b[^.\n]{0,80}\b(?:review|verdict|producer|output|findings|completes?|arrives?|done)\b', re.I),
    re.compile(r'\b(?:after|once|when|until)\b.*\b(?:review|verdict|producer|reviewer|parent|upstream|findings)\b', re.I),
    re.compile(r'\b(?:blocked|waiting)\s+on\s+(?:another|other|upstream|parent)\b', re.I),
    re.compile(r'\b(?:depends?|dependent)\s+on\b', re.I),
    re.compile(r'\bprerequisite\b', re.I),
]

# Patterns that indicate a legitimate capability block (do not flag these).
CAPABILITY_PATTERNS = [
    re.compile(r'\b(?:command|binary|executable|package|library|module|API|endpoint|token|credential)\s+(?:not found|missing|not available|unavailable|denied|exit \d+)\b', re.I),
    re.compile(r'\b(?:permission denied|exit code \d+|command not found|no such file|not installed)\b', re.I),
    re.compile(r'\b(?:quota|rate.?limit|throttl|timeout|429|503|502)\b', re.I),
    re.compile(r'\b(?:lifecycle guard|sequencing|catch-?22)\b', re.I),
]


def looks_like_dependency(reason):
    """Whether a block reason describes a dependency pattern."""
    if not reason:
        return False
    # Check legitimate capability patterns first.
    for pat in CAPABILITY_PATTERNS:
        if pat.search(reason):
            return False
    for pat in DEPENDENCY_PATTERNS:
        if pat.search(reason):
            return True
    return False


def looks_like_capability(reason):
    """Whether a block reason describes a genuine capability gap."""
    if not reason:
        return False
    for pat in CAPABILITY_PATTERNS:
        if pat.search(reason):
            return True
    return False


def connect_ro(path):
    db = sqlite3.connect(path.resolve().as_uri() + '?mode=ro', uri=True)
    db.row_factory = sqlite3.Row
    db.execute('PRAGMA query_only=ON')
    return db


def block_reason(db, task_id):
    """The newest blocked event's reason text, or ''."""
    try:
        row = db.execute(
            "SELECT payload FROM task_events WHERE task_id = ? AND kind = 'blocked'"
            ' ORDER BY id DESC LIMIT 1', (task_id,)).fetchone()
    except sqlite3.Error:
        return ''
    if not row:
        return ''
    try:
        return (json.loads(row['payload'] or '{}').get('reason') or '').strip()
    except (ValueError, AttributeError):
        return ''


def has_open_parent(db, task_id):
    """Whether the card has at least one open prerequisite."""
    try:
        row = db.execute(
            "SELECT 1 FROM task_links l JOIN tasks p ON p.id=l.parent_id"
            " WHERE l.child_id=? AND p.status NOT IN ('done','archived') LIMIT 1",
            (task_id,)).fetchone()
    except sqlite3.Error:
        return False
    return row is not None


def audit_board(root, slug):
    """Audit one board for misclassified cards."""
    db_path = root / 'kanban' / 'boards' / slug / 'kanban.db'
    findings = []
    try:
        with connect_ro(db_path) as db:
            rows = db.execute(
                "SELECT id, title, status, block_kind, body FROM tasks"
                f" WHERE status IN ({','.join('?' * len(OPEN_STATUSES))})",
                OPEN_STATUSES).fetchall()
    except (OSError, sqlite3.Error) as exc:
        return [{'board': slug, 'severity': 'error',
                 'message': f'cannot read board: {exc}'}]

    for row in rows:
        tid = row['id']
        kind = row['block_kind']
        status = row['status']
        title = row['title']
        reason = block_reason(db, tid)
        body = row['body'] or ''

        # Case 1: capability block with dependency-like reason.
        if kind == 'capability' and looks_like_dependency(reason):
            findings.append({
                'board': slug, 'task_id': tid, 'title': title,
                'current_kind': 'capability', 'suggested_kind': 'dependency',
                'severity': 'misclassified',
                'reason': f'reason describes dependency: {reason[:120]}',
            })

        # Case 2: dependency block with no open prerequisite.
        if kind == 'dependency' and not has_open_parent(db, tid):
            findings.append({
                'board': slug, 'task_id': tid, 'title': title,
                'current_kind': 'dependency', 'suggested_kind': 'needs_input',
                'severity': 'orphaned_dependency',
                'reason': 'dependency block with no open prerequisite linked',
            })

        # Case 3: blocked card with no block_kind and a dependency-like reason.
        if status == 'blocked' and not kind and looks_like_dependency(reason):
            findings.append({
                'board': slug, 'task_id': tid, 'title': title,
                'current_kind': '(none)', 'suggested_kind': 'dependency',
                'severity': 'missing_classification',
                'reason': f'blocked with dependency-like reason: {reason[:120]}',
            })

        # Case 4: blocked card with no reason at all.
        if status == 'blocked' and not kind and not reason:
            # Check body for Hard Blocker or ASK: markers.
            if re.search(r'^Hard Blocker\b', body, re.M | re.I):
                findings.append({
                    'board': slug, 'task_id': tid, 'title': title,
                    'current_kind': '(none)', 'suggested_kind': 'needs_input',
                    'severity': 'missing_classification',
                    'reason': 'blocked with Hard Blocker but no block_kind recorded',
                })
            elif re.search(r'^\s*ASK:', body, re.M):
                findings.append({
                    'board': slug, 'task_id': tid, 'title': title,
                    'current_kind': '(none)', 'suggested_kind': 'needs_input',
                    'severity': 'missing_classification',
                    'reason': 'blocked with ASK: but no block_kind recorded',
                })
            else:
                findings.append({
                    'board': slug, 'task_id': tid, 'title': title,
                    'current_kind': '(none)', 'suggested_kind': 'dependency',
                    'severity': 'missing_classification',
                    'reason': 'blocked with no reason and no block_kind',
                })

        # Case 5: capability block with no reason (can't verify, but flag it).
        if kind == 'capability' and not reason:
            findings.append({
                'board': slug, 'task_id': tid, 'title': title,
                'current_kind': 'capability', 'suggested_kind': '(review)',
                'severity': 'unverifiable',
                'reason': 'capability block with no reason recorded',
            })

    return findings


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--board', help='restrict to one board slug')
    parser.add_argument('--json', action='store_true')
    args = parser.parse_args()

    root = Path(os.environ.get('HERMES_ROOT', str(Path.home() / '.hermes')))
    boards_dir = root / 'kanban' / 'boards'
    if not boards_dir.is_dir():
        print(json.dumps([], indent=2) if args.json else 'no boards found')
        return

    slugs = [args.board] if args.board else sorted(
        p.name for p in boards_dir.iterdir()
        if p.is_dir() and (p / 'kanban.db').exists()
        and not p.name.startswith(('_', '.')))

    all_findings = []
    for slug in slugs:
        all_findings.extend(audit_board(root, slug))

    if args.json:
        print(json.dumps(all_findings, indent=2, sort_keys=True))
        return

    if not all_findings:
        print('kanban classification audit: no misclassifications found')
        return

    print(f'kanban classification audit: {len(all_findings)} finding(s)')
    for f in all_findings:
        print(f"  [{f['board']}] {f['task_id']} {f['severity']}:"
              f" {f['current_kind']} -> {f['suggested_kind']}")
        print(f"    {f['reason']}")
        print(f"    {f['title'][:60]}")
    return 1


if __name__ == '__main__':
    raise SystemExit(main())
