#!/usr/bin/env python3
"""Admit compact, scoped facts through Hermes' existing pre-tool hook.

Python operations glue uses read-only SQLite and the native hook protocol. It
checks provenance and common pollution patterns, not semantic truth. No model,
new service, credential output or permission grant is introduced.
"""
import copy
from contextlib import closing
import json
import os
from pathlib import Path
import re
import sqlite3
import sys
import time

READONLY = {'board-steward', 'local-implementer'}
OWNER_WRITERS = {'default', 'head-coordinator'}
ROLES = OWNER_WRITERS | READONLY | {'feature-reviewer', 'standard-implementer', 'project-auditor'}
POLLUTION = re.compile(
    r'\bt_[a-z0-9_]+\b|\b[0-9a-f]{40,64}\b|\bkanban_\w+\b|\.stamp\b|'
    r'\b(?:verdict|dossier|receipts?|task[_ -]?id|FINDINGS\.md|metadata\.\w+|run_tests)\b|'
    r'\b(?:approved|authori[sz](?:ed|ation)|permissions?|grants?|waiv\w*|bypass\w*|override\w*|unrestricted|standing approval|higher priority|priority over|highest priority|top priority|takes precedence)\b|'
    r'\b(?:can|may|allowed to|free to)\s+(?:deploy|publish|push|delete|unblock|execute|run|modify|change|approve)\b|'
    r'\b(?:password|api[ _-]?key|access[ _-]?token|private[ _-]?key|credentials?|secrets?)\b|'
    r'(?:^|[.!?]\s+)(?:always|never|before|after|run|use|must|do not)\b', re.I)


def normalized(text):
    return ' '.join(re.findall(r'[\w]+', text.casefold()))


def owner_session(session, root):
    if session['parent_session_id']:
        return False
    if session['source'] in {'cli', 'desktop'}:
        return True
    if session['source'] != 'simplex' or session['chat_type'] != 'dm':
        return False
    # Match the existing owner-alert sender's checked private destination.
    values = {}
    path = root / 'profiles/head-coordinator/.env'
    for line in path.read_text().splitlines():
        match = re.fullmatch(r'\s*(SIMPLEX_[A-Z_]+)\s*=\s*(.*?)\s*', line)
        if match:
            values[match[1]] = match[2].strip('"\'')
    owner = values.get('SIMPLEX_HOME_CHANNEL', '')
    return (bool(re.fullmatch(r'[0-9]+', owner)) and str(session['user_id']) == owner
            and owner in values.get('SIMPLEX_ALLOWED_USERS', '').split(',')
            and not values.get('SIMPLEX_ALLOW_ALL_USERS') and not values.get('SIMPLEX_GROUP_ALLOWED'))


def candidate(text, target, profile, db, session_id, latest_user, root, session, canonical):
    if not isinstance(text, str):
        raise ValueError('New facts need Fact, Scope and Evidence lines')
    lines = text.splitlines()
    fields = {}
    for line in lines:
        key, separator, value = line.partition(':')
        if not separator or key not in {'Fact', 'Scope', 'Evidence'} or key in fields:
            raise ValueError('Use exactly one Fact, Scope and Evidence line; keep procedures on cards or in skills')
        fields[key] = value.strip()
    if set(fields) != {'Fact', 'Scope', 'Evidence'} or not all(fields.values()):
        raise ValueError('New facts need non-empty Fact, Scope and Evidence lines')
    fact, scope, evidence = fields['Fact'], fields['Scope'], fields['Evidence']
    if len(fact) > 300 or POLLUTION.search(fact) or '\n' in fact:
        raise ValueError('Keep a short declarative fact; task receipts, workflows, priorities, permissions and credentials do not belong in memory')
    if target == 'user':
        if scope != 'owner' or profile not in OWNER_WRITERS or not owner_session(session, root):
            raise ValueError('User preferences may be learned only by the owner-facing profiles in a direct owner conversation')
    elif scope not in {'workstation', 'server', 'fleet', profile}:
        raise ValueError('Scope environment facts to workstation, server, fleet or this profile')
    kind, separator, reference = evidence.partition(':')
    if kind == 'owner' and separator:
        if (not owner_session(session, root) or len(reference.strip()) < 4
                or normalized(reference) not in normalized(latest_user['content'])):
            raise ValueError('Owner evidence must quote the current real owner message, not a task specification or inferred preference')
        if target == 'user':
            quote=reference.strip().rstrip('.')
            match=re.fullmatch(r'I (prefer|want|expect|value) (.+)',quote,re.I)
            verbs={'prefer':'prefers','want':'wants','expect':'expects','value':'values'}
            expected=(f'The owner {verbs[match[1].lower()]} {match[2]}' if match else 'Owner statement: '+quote)
            if normalized(fact)!=normalized(expected):
                raise ValueError('Keep the owner statement verbatim: render I prefer/want/expect/value as The owner prefers/wants/expects/values; otherwise use Owner statement: <exact quote>')
            if POLLUTION.search(quote):
                raise ValueError('Quoted permissions, priorities, task instructions or credentials are not owner-profile preferences')
    elif target == 'memory' and kind == 'tool' and separator:
        row = db.execute("SELECT tool_name,content FROM messages WHERE session_id=? AND role='tool' "
                         'AND tool_call_id=? AND timestamp>=? ORDER BY id DESC LIMIT 1',
                         (session_id, reference, latest_user['timestamp'])).fetchone()
        if not row or not row['content'] or row['tool_name'] not in {'read_file', 'terminal', 'search', 'search_files'}:
            raise ValueError('Tool evidence must identify a real read/probe result from this turn')
        try:
            result = json.loads(row['content'])
        except (ValueError, TypeError):
            result = None
        if isinstance(result, dict) and (result.get('error') or result.get('success') is False
                                        or result.get('exit_code', 0) not in (None, 0)):
            raise ValueError('A failed probe cannot verify an environment fact')
    else:
        raise ValueError('Evidence must be owner:<exact quote> or, for environment facts, tool:<current tool_call_id>')
    if target == 'memory' and not normalized(fact).startswith(normalized(scope) + ' '):
        fact = scope.capitalize() + ': ' + fact
    unscoped = normalized(fact.split(':', 1)[-1])
    if len(unscoped) >= 25 and any(unscoped in normalized(text) for text in canonical):
        raise ValueError('This fact already has a canonical instruction home; keep that source authoritative')
    return fact


def guard(payload, root):
    tool, profile = payload.get('tool_name'), payload.get('profile')
    if tool not in {'memory', 'skill_manage'}:
        return {}
    try:
        if profile not in ROLES:
            raise ValueError('Unknown profile; do not write persistent learning state')
        if profile in READONLY:
            raise ValueError('This role reads curated knowledge but cannot write memories or skills; report a scoped proposal to the coordinator')
        if tool != 'memory':
            return {}
        home = root if profile == 'default' else root / 'profiles' / profile
        args = copy.deepcopy(payload.get('tool_input') or {})
        target = args.get('target') or 'memory'
        session_id = payload.get('session_id')
        if target not in {'memory', 'user'} or not isinstance(session_id, str) or not session_id:
            raise ValueError('Provide a known memory target and actual session identity')
        with closing(sqlite3.connect((home / 'state.db').resolve().as_uri() + '?mode=ro', uri=True, timeout=.1)) as db:
            db.row_factory = sqlite3.Row
            db.execute('PRAGMA query_only=ON')
            deadline = time.monotonic() + .5
            db.set_progress_handler(lambda: int(time.monotonic() > deadline), 1000)
            db.execute('BEGIN')
            session = db.execute('SELECT source,chat_type,user_id,parent_session_id FROM sessions WHERE id=?', (session_id,)).fetchone()
            latest = db.execute("SELECT content,timestamp FROM messages WHERE session_id=? AND role='user' ORDER BY id DESC LIMIT 1", (session_id,)).fetchone()
            if not session or not latest:
                raise ValueError('Persistent facts require a recorded session and current user turn')
            if target == 'user' and (profile not in OWNER_WRITERS or not owner_session(session, root)):
                raise ValueError('Task workers and scheduled jobs cannot rewrite the owner profile')
            canonical = [p.read_text() for p in (home / 'SOUL.md', root / 'scripts/hermes-fleet-policy.md') if p.exists()]
            operations = args.get('operations') if args.get('operations') is not None else [args]
            if not isinstance(operations, list) or not operations or any(not isinstance(op, dict) for op in operations):
                raise ValueError('Use a valid single operation or atomic operations list')
            for op in operations:
                if op.get('target', target) != target:
                    raise ValueError('A batch has one target')
                if op.get('action') in {'add', 'replace'}:
                    fact = candidate(op.get('content') or op.get('new_text'), target, profile, db,
                                     session_id, latest, root, session, canonical)
                    op['content'] = fact
                    op.pop('new_text', None)
                elif op.get('action') != 'remove':
                    raise ValueError('Only native add, replace and remove operations are supported')
        return {'action': 'modify', 'args': args}
    except (ValueError, TypeError, AttributeError, OSError, sqlite3.Error) as exc:
        message = str(exc) if isinstance(exc, ValueError) else 'Context is unavailable; leave memory unchanged'
        return {'action': 'block', 'message': 'Memory admission: ' + message + '. Do not bypass the guard; keep task-specific evidence on its card.'}


if __name__ == '__main__':
    try:
        root = Path(os.environ.get('HERMES_ROOT', str(Path(__file__).resolve().parents[1])))
        print(json.dumps(guard(json.load(sys.stdin), root)))
    except Exception:
        print(json.dumps({'action': 'block', 'message': 'Memory admission unavailable; leave persistent learning unchanged.'}))
