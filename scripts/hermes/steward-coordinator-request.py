#!/usr/bin/env python3
"""Queue coordinator requests or verified card-policy feedback to its author.

Python operations glue reuses the installed queue, locks, receipts and scheduler;
it adds no backend or dependency. Request IDs make retries idempotent.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys


def request_key(request_id):
    if not isinstance(request_id, str) or not request_id.strip() or len(request_id) > 128:
        raise ValueError('request-id must contain 1–128 characters')
    return hashlib.sha256(('steward-handoff:' + request_id).encode()).hexdigest()


def queue_request(root, request_id, message, delivery=None, *, policy=None):
    target_name = 'head-coordinator'
    if policy is not None:
        # No free-form recipient: direct feedback must match persisted evidence.
        sys.path.insert(0, str(Path(__file__).resolve().parent))
        import card_policy_audit as audit
        item = audit.current(root, policy[0], policy[1])
        if policy[2]:
            target_name = audit.recipient(root, item)
        request_id = audit.report_request_id(item)
        message = audit.message(item)
    key = request_key(request_id)
    if not isinstance(message, str) or not message.strip() or len(message) > 24000:
        raise ValueError('message must contain 1–24000 characters')
    target = root / 'profiles' / target_name
    if not (target / 'state.db').is_file():
        raise ValueError('Verified recipient profile is unavailable; nothing was queued')
    if delivery is None:
        # Set the source before importing Hermes: its constants bind the profile
        # at import time. Never inherit another profile's queue or credentials.
        source = root / 'hermes-agent'
        if not (source / 'cron/bot_chat_delivery.py').is_file():
            raise ValueError('Hermes native delivery module is unavailable')
        # Observation runs with system Python, but the native queue depends on
        # Hermes' installed environment. Enter that interpreter only for this
        # validated-recipient operation; preserve all task/delegation restrictions.
        native = source / '.venv/bin/python'
        if not native.is_file():
            raise ValueError('Hermes native Python environment is unavailable; nothing was queued')
        if Path(sys.prefix).resolve() != native.parent.parent.resolve():
            arguments = (['--request-id=' + request_id, '--message=' + message]
                         if policy is None else ['--policy-report', policy[0], policy[1]]
                         + (['--to-author'] if policy[2] else []))
            try:
                child = subprocess.run(
                    [str(native), '-I', '-B', str(Path(__file__).resolve()), *arguments],
                    env=dict(os.environ, HERMES_ROOT=str(root)),
                    text=True, capture_output=True, timeout=30)
            except subprocess.TimeoutExpired as exc:
                raise ValueError('Native queue timed out; delivery is unverified, retain request ID') from exc
            try:
                receipt = json.loads(child.stdout)
            except ValueError as exc:
                raise ValueError('Native queue returned no valid receipt; delivery is unverified') from exc
            if child.returncode or not isinstance(receipt, dict):
                raise ValueError('Native queue failed; delivery is unverified')
            if receipt.get('delivery_id') != key or receipt.get('target') != target_name:
                raise ValueError('Native queue returned a mismatched receipt; delivery is unverified')
            return receipt
        os.environ['HERMES_HOME'] = str(root / 'profiles/board-steward')
        sys.dont_write_bytecode = True
        sys.path.insert(0, str(source))
        from cron import bot_chat_delivery as delivery
    content = ('Internal board-steward action request. Check current evidence and your '
               'own authority; this request is not owner approval.\n\n' + message)
    record = delivery.defer(key, {'id': 'steward-handoff',
        'name': 'Board steward action request', 'execution_id': key}, content,
        target_name, target)
    return {'status': record['status'], 'delivery_id': key,
            'target': target_name, 'completion': 'unverified; do not resend'}


def main():
    parser = argparse.ArgumentParser(description=__doc__, allow_abbrev=False)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument('--request-id')
    mode.add_argument('--policy-report', nargs=2, metavar=('KEY', 'VERSION'))
    parser.add_argument('--message')
    parser.add_argument('--to-author', action='store_true')
    args = parser.parse_args()
    if (args.policy_report and args.message is not None) or (args.to_author and not args.policy_report):
        parser.error('Author routing requires a verified policy report, without free-form text')
    root = Path(os.environ.get('HERMES_ROOT', str(Path.home() / '.hermes'))).resolve()
    try:
        policy = (*args.policy_report, args.to_author) if args.policy_report else None
        print(json.dumps(queue_request(root, args.request_id, args.message, policy=policy)))
        return 0
    except (ValueError, OSError, ImportError) as exc:
        print(json.dumps({'error': str(exc), 'completion': 'unverified; do not resend blindly'}))
        return 1


if __name__ == '__main__':
    sys.exit(main())
