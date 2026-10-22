#!/usr/bin/env python3
"""Queue a fixed-recipient steward request using Hermes' existing delivery lane.

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


def queue_request(root, request_id, message, delivery=None):
    key = request_key(request_id)
    if not isinstance(message, str) or not message.strip() or len(message) > 24000:
        raise ValueError('message must contain 1–24000 characters')
    target = root / 'profiles/head-coordinator'
    if not (target / 'state.db').is_file():
        raise ValueError('head-coordinator profile is unavailable; nothing was queued')
    if delivery is None:
        # Set the source before importing Hermes: its constants bind the profile
        # at import time. Never inherit another profile's queue or credentials.
        source = root / 'hermes-agent'
        if not (source / 'cron/bot_chat_delivery.py').is_file():
            raise ValueError('Hermes native delivery module is unavailable')
        # Observation runs with system Python, but the native queue depends on
        # Hermes' installed environment. Enter that interpreter only for this
        # fixed-recipient operation; preserve all task/delegation restrictions.
        native = source / '.venv/bin/python'
        if not native.is_file():
            raise ValueError('Hermes native Python environment is unavailable; nothing was queued')
        if Path(sys.prefix).resolve() != native.parent.parent.resolve():
            try:
                child = subprocess.run(
                    [str(native), '-I', '-B', str(Path(__file__).resolve()),
                     '--request-id=' + request_id, '--message=' + message],
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
            if receipt.get('delivery_id') != key or receipt.get('target') != 'head-coordinator':
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
        'head-coordinator', target)
    return {'status': record['status'], 'delivery_id': key,
            'target': 'head-coordinator', 'completion': 'unverified; do not resend'}


def main():
    parser = argparse.ArgumentParser(description=__doc__, allow_abbrev=False)
    parser.add_argument('--request-id', required=True)
    parser.add_argument('--message', required=True)
    args = parser.parse_args()
    root = Path(os.environ.get('HERMES_ROOT', str(Path.home() / '.hermes'))).resolve()
    try:
        print(json.dumps(queue_request(root, args.request_id, args.message)))
        return 0
    except (ValueError, OSError, ImportError) as exc:
        print(json.dumps({'error': str(exc), 'completion': 'unverified; do not resend blindly'}))
        return 1


if __name__ == '__main__':
    sys.exit(main())
