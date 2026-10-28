#!/usr/bin/env python3
"""Reject informal card prerequisites through Hermes' existing pre-write hooks.

Python glue uses the native hook protocol and standard library, with no backend
or new dependency. The formal task graph remains the scheduler's only authority.
"""
import json
import re
import sys

CARD = r'\bt_[A-Za-z0-9_]+\b'
REFERENCE = rf'(?:{CARD}|\b(?:cards?|tasks?|parents?|upstream)\b)'
WAIT = (r'\b(?:wait(?:s|ing)?\s+(?:on|for)|await(?:s|ing)?|blocked\s+(?:on|by)|'
        r'depends?\s+(?:on|upon)|gated\s+by)\b')
TARGET = rf'(?:[A-Za-z0-9_-]+:)?{CARD}'
PREREQUISITE = (rf'\b(?:pending|requires?|needs?|after|until|once|when|before|'
                rf'dependenc(?:y|ies)|prerequisites?|parents?)\s*:?\s*'
                rf'(?:\n\s*[-*]\s*)?{TARGET}')
RECEIPTS = {'deployment_decision', 'owner_execution_decision', 'delegated_execution_decision'}


def guard(payload):
    if not isinstance(payload, dict) or not isinstance(payload.get('tool_input'), dict):
        raise ValueError('Expected a native hook object and tool_input mapping')
    tool, args = payload.get('tool_name'), payload['tool_input']
    if tool not in ('kanban_comment', 'kanban_create', 'kanban_amend'):
        return {}
    if tool == 'kanban_amend':
        args = args.get('changes') or {}
        if not isinstance(args, dict):
            raise ValueError('Expected amendment changes mapping')
    body = args.get('body') or ''
    if not isinstance(body, str):
        raise ValueError('Expected card text')
    # These are evidence contracts, not declarations of scheduling edges. Their
    # existing validators still decide whether the quote/decision is authorized.
    if tool == 'kanban_comment' and payload.get('profile') == 'head-coordinator':
        if re.match(r'^Owner reply (?:via SimpleX D\d+:|received:)\s*\S', body):
            return {}
        if body.lstrip().startswith('{'):
            try:
                receipt = json.loads(body)
            except ValueError:
                receipt = None
            if (isinstance(receipt, dict) and len(receipt) == 1
                    and next(iter(receipt)) in RECEIPTS
                    and isinstance(next(iter(receipt.values())), dict)):
                return {}
    # Membership is explicitly not a prerequisite; do not let its ID turn an
    # unrelated sentence about software dependencies into a false positive.
    text = '\n'.join(line for line in body.splitlines() if not re.fullmatch(
        rf'Feature tracker: [A-Za-z0-9_-]+:{CARD}', line))
    # Check sentences/fields, retaining newlines for a Dependencies: ID list.
    for sentence in re.split(r'[.!?;]|\n(?=(?:Goal|Change|Verify|Update|Evidence|Next):)', text):
        if (re.search(PREREQUISITE, sentence, re.I)
                or re.search(rf'{CARD}\s+(?:must\s+(?:finish|complete)|blocks?|blocking)\b',
                             sentence, re.I)
                or re.search(rf'{WAIT}\s+(?:(?:the|a|an|another|that|this|its)\s+)?{TARGET}',
                             sentence, re.I)
                or re.search(rf'{WAIT}\s+(?:(?:the|a|an|another|that|this|its)\s+)?{REFERENCE}',
                             sentence, re.I)
                or re.search(rf'{CARD}\s*(?:->|<-|→|←|=>|<=)\s*{CARD}', sentence)):
            return {'action': 'block', 'message':
                    'Card dependencies belong in the formal graph, never in comments '
                    'or dependency prose. Use kanban_create(parents=[...]) or '
                    'kanban_link(parent_id=..., child_id=..., board=...), then '
                    'kanban_show to verify the edge. If waiting, use '
                    'kanban_block(kind="dependency") only after linking an open '
                    'prerequisite. Keep comments for results and evidence.'}
    return {}


if __name__ == '__main__':
    try:
        print(json.dumps(guard(json.load(sys.stdin))))
    except (ValueError, TypeError, AttributeError) as exc:
        print(json.dumps({'action': 'block', 'message': f'Card dependency check failed closed: {exc}'}))
