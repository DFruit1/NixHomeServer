#!/usr/bin/env python3
"""Ingest one authenticated owner reply against a D label, deterministically.

The decision channel messages carry a stable ``D<n>`` label. An owner replies
either by typing the label (``D49 A``) or by using SimpleX's reply-to-message
feature, in which case the adapter surfaces the quoted message as a leading
``[Replying to: ...]`` line. Both forms resolve to the same label.

This helper does the mechanical part of the reply flow that the coordinator
otherwise performs by hand:

1. Extract the D label from the reply text or its quoted prefix.
2. Resolve the label read-only with ``kanban-owner-alerts.py --resolve``.
3. Refuse stale, closed, undelivered, or technical (B) labels.
4. Record the verbatim reply as a ``kanban_comment`` authored by the
   coordinator, naming its SimpleX origin.
5. With ``--apply``, unblock the resolved card only for a ``kind=decision``
   card and only when the reply is affirmative (a choice or explicit
   approval). It never treats a reply as deploy authorisation.

Default is a dry run: it prints the resolution and the exact write it would
perform. Use ``--apply`` from the coordinator session, outside a delegated
worker fence.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys

LABEL_RE = re.compile(r'\b([DB]\d+)\b', re.I)
QUOTED_RE = re.compile(r'^\[Replying to:\s*(.*?)\]\s*', re.S)
AFFIRMATIVE_WORDS = re.compile(
    r'\b(?:approve|approved|accept|accepted|yes|yep|proceed|go ahead|confirm|'
    r'confirmed|do it|ok|okay|reconstruct|supersede|descope)\b', re.I)
BARE_CHOICE = re.compile(r'^(?:option\s+)?[abc]\)?[.!]?$', re.I)


def find_label(text: str) -> str | None:
    """The first D/B label in the reply, preferring a quoted label."""
    quoted = QUOTED_RE.match(text)
    if quoted:
        match = LABEL_RE.search(quoted.group(1))
        if match:
            return match.group(1).upper()
    match = LABEL_RE.search(text)
    return match.group(1).upper() if match else None


def reply_body(text: str) -> str:
    """The owner's reply without the adapter's quoted prefix or the D label."""
    quoted = QUOTED_RE.match(text)
    body = text[quoted.end():].strip() if quoted else text.strip()
    body = LABEL_RE.sub('', body, count=1).strip(' :,-')
    return body


def resolve(label: str) -> dict:
    helper = Path(os.environ.get(
        'HERMES_OWNER_ALERTS_HELPER',
        str(Path.home() / '.hermes' / 'scripts' / 'kanban-owner-alerts.py')))
    if not helper.exists():
        raise SystemExit(f'owner-alerts helper not found: {helper}')
    result = subprocess.run(
        [sys.executable, str(helper), '--resolve', label],
        capture_output=True, text=True, timeout=60)
    if result.returncode != 0:
        raise SystemExit(f'resolve {label} failed: {result.stderr.strip() or result.stdout.strip()}')
    return json.loads(result.stdout)


NEGATION_RE = re.compile(
    r"\b(?:not|no|never|hold|wait|reject|decline|cancel|stop|without)\b|"
    r"\b(?:don'?t|doesn'?t|do not)\b", re.I)


def is_affirmative(body: str) -> bool:
    body = body.strip()
    if BARE_CHOICE.match(body):
        return True
    if NEGATION_RE.search(body):
        return False
    return bool(AFFIRMATIVE_WORDS.search(body))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--text', help='Reply text; omit to read stdin')
    parser.add_argument('--apply', action='store_true',
                        help='Record the comment and unblock an affirmative decision reply')
    parser.add_argument('--json', action='store_true')
    args = parser.parse_args()

    text = (args.text if args.text is not None else sys.stdin.read()).strip()
    if not text:
        print('decision-reply: empty reply', file=sys.stderr)
        return 2

    label = find_label(text)
    if not label:
        print('decision-reply: no D/B label in the reply or its quoted message',
              file=sys.stderr)
        return 2

    decision = resolve(label)
    body = reply_body(text)
    outcome = {
        'label': label,
        'board': decision.get('board'),
        'task_id': decision.get('task_id'),
        'kind': decision.get('kind'),
        'can_reply': bool(decision.get('can_reply')),
        'affirmative': is_affirmative(body),
        'reply': body,
        'recorded': False,
        'unblocked': False,
    }

    if decision.get('kind') != 'decision':
        outcome['error'] = 'B labels are technical diagnostics and cannot unblock work'
    elif not decision.get('can_reply'):
        outcome['error'] = 'label is stale, closed, reclassified or never delivered'
    elif not args.apply:
        outcome['dry_run'] = True
    else:
        board, task_id = decision['board'], decision['task_id']
        comment = (f'Owner reply via SimpleX {label}: {body}\n\n'
                   f'Authenticated SimpleX decision-channel reply; recorded verbatim '
                   f'before any board transition.')
        recorded = subprocess.run(
            ['hermes', 'kanban', '--board', board, 'comment', task_id,
             '--author', 'head-coordinator', comment],
            capture_output=True, text=True, timeout=120)
        if recorded.returncode != 0:
            outcome['error'] = f'comment failed: {recorded.stderr.strip() or recorded.stdout.strip()}'
        else:
            outcome['recorded'] = True
            if outcome['affirmative']:
                unblocked = subprocess.run(
                    ['hermes', 'kanban', '--board', board, 'unblock', task_id,
                     '--reason', f'Owner replied affirmatively via {label}: {body[:180]}'],
                    capture_output=True, text=True, timeout=120)
                if unblocked.returncode == 0:
                    outcome['unblocked'] = True
                else:
                    outcome['error'] = (f'unblock failed: '
                                        f'{unblocked.stderr.strip() or unblocked.stdout.strip()}')

    if args.json:
        print(json.dumps(outcome, indent=2, sort_keys=True))
    else:
        print(f"{label} -> {outcome.get('board')}/{outcome.get('task_id')} "
              f"kind={outcome.get('kind')} can_reply={outcome.get('can_reply')}")
        print(f"reply: {body}")
        if outcome.get('error'):
            print(f"refused: {outcome['error']}")
        elif outcome.get('dry_run'):
            print('dry run: would record the reply' +
                  (' and unblock' if outcome['affirmative'] else ' only'))
        else:
            print(f"recorded={outcome['recorded']} unblocked={outcome['unblocked']}")
    return 0 if not outcome.get('error') else 1


if __name__ == '__main__':
    raise SystemExit(main())
