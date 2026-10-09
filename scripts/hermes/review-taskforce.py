#!/usr/bin/env python3
"""Hermes operations glue; stdlib Python matches the host's Hermes runtime.

No service/backend or new dependency is introduced. Board writes use the Hermes
CLI; locked, atomic file writes protect the reviewer's persisted documents.
Reads use SQLite read-only connections so delegated workers can inventory cards
without a writable CLI context.
"""
import argparse
from contextlib import closing, contextmanager
import fcntl
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import sqlite3
import subprocess
import sys
import tempfile
import time

TENANT = 'continuous-improvement'
OPPORTUNITY_TITLE = 'Review: choose a focused improvement audit'
CADENCES = {'off': 0, 'daily': 24, 'weekly': 168}
IMPLEMENTERS = {'standard-implementer', 'local-implementer'}
REVIEWER = 'feature-reviewer'
MUTATING_PROFILES = {'project-auditor'}
REPORT_PROFILES = {REVIEWER, 'project-auditor'}
TELEMETRY_PROFILES = {REVIEWER, 'project-auditor'}
ACTIVE_STATUSES = {'running'}
PENDING_STATUSES = {'ready', 'todo', 'blocked', 'review', 'scheduled'}
OUTCOMES = {'findings', 'clean', 'inconclusive', 'deferred_active_work'}
SEVERITIES = {'critical', 'high', 'medium', 'low'}
AXES = {'correctness', 'reliability', 'performance', 'security', 'simplicity', 'integration'}
CONFIDENCES = {'verified', 'inferred'}
FINDING_STATUSES = {'open', 'accepted', 'deferred', 'rejected', 'implemented', 'verified', 'failed'}
TASK_ROLES = {'audit', 'assessment', 'plan', 'gate', 'handoff', 'implementer', 'closure'}
DEFAULT_SUPPRESS_CLEAN_STREAK = 3
DEFAULT_MAX_AUDITS_PER_FINDING = 2
FINDING_ID = re.compile(r'[A-Za-z0-9][A-Za-z0-9._-]{2,}')
PLAN_NAME = re.compile(r'plans/[A-Za-z0-9][A-Za-z0-9_-]*\.md')
REPORT_NAME = re.compile(r'reports/[A-Za-z0-9][A-Za-z0-9._-]*\.md')
SECRET_MARKERS = ('-----BEGIN', 'PRIVATE KEY-----', 'AGE-SECRET-KEY-')
DEFAULT_CLASSIFY_RULES = {
    '1': {
        'label': 'architecture: boundaries, topology, data contracts, persistence',
        'paths': ('modules/Core_Modules', 'modules/Integrations', 'flake.nix', 'configuration.nix'),
        'basenames': (),
        'patterns': (r'(^|/)(core|platform|infrastructure)/',),
    },
    '2': {
        'label': 'software stack: dependencies, runtimes, build/deployment tooling',
        'paths': (),
        'basenames': ('Cargo.toml', 'Cargo.nix', 'Cargo.lock', 'package.json', 'pnpm-lock.yaml',
                      'package-lock.json', 'yarn.lock', 'go.mod', 'go.sum', 'Gemfile',
                      'requirements.txt', 'pyproject.toml', 'nuget-deps.json', 'flake.lock'),
        'patterns': (r'^flake/(flake|packages|checks)\.nix$',),
    },
    '3': {
        'label': 'frontend: rendered UI changes beyond authorised minimal controls',
        'paths': (),
        'basenames': (),
        'patterns': (r'\.(css|scss|less|tsx|jsx|vue|svelte)$', r'(^|/)(frontend|ui|client|web)/'),
    },
    '4': {
        'label': 'security/regression risk: auth, secrets, routing, persistence, privilege',
        'paths': ('secrets', 'modules/Core_Modules/kanidm', 'modules/Core_Modules/auth-gateway',
                  'modules/Core_Modules/backups', 'modules/Core_Modules/kopia',
                  'modules/Core_Modules/impermanence'),
        'basenames': ('age.pub',),
        'patterns': (r'(secret|credential|oauth|sudo|kanidm|agenix|password|passkey)',),
    },
}


def review_dir(root, board):
    if not re.fullmatch(r'[a-zA-Z0-9][a-zA-Z0-9_-]*', board):
        raise ValueError('Invalid board slug')
    path = root / 'kanban/boards' / board
    if not (path / 'board.json').is_file():
        raise ValueError(f'Unknown board: {board}')
    return path / 'review-taskforce'


@contextmanager
def locked(path):
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    with (path / '.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        yield


def atomic_write(path, content):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, name = tempfile.mkstemp(prefix='.write-', dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as stream:
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def is_relative_path(value):
    if not isinstance(value, str) or value in {'', '.'}:
        return False
    path = Path(value)
    return not path.is_absolute() and '..' not in path.parts


def read_jsonl(path):
    if not path.is_file():
        return []
    entries = []
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            entry = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(entry, dict):
            entries.append(entry)
    return entries


def write_jsonl(path, entries):
    with locked(path.parent):
        atomic_write(path, ''.join(json.dumps(entry, sort_keys=True) + '\n' for entry in entries))


def append_jsonl(path, entry):
    with locked(path.parent):
        entry = dict(entry)
        entry.setdefault('at', int(time.time()))
        with path.open('a') as stream:
            stream.write(json.dumps(entry, sort_keys=True) + '\n')
            stream.flush()
            os.fsync(stream.fileno())


def findings_index(root, board):
    return review_dir(root, board) / 'findings.jsonl'


def metrics_index(root, board):
    return review_dir(root, board) / 'metrics.jsonl'


def load_config(root, board):
    directory = review_dir(root, board)
    path = directory / 'config.json'
    if not path.is_file():
        return {'cadence': 'off', 'interval_hours': 0,
                'suppress_clean_streak': DEFAULT_SUPPRESS_CLEAN_STREAK,
                'max_audits_per_finding': DEFAULT_MAX_AUDITS_PER_FINDING}
    config = json.loads(path.read_text())
    config.setdefault('suppress_clean_streak', DEFAULT_SUPPRESS_CLEAN_STREAK)
    config.setdefault('max_audits_per_finding', DEFAULT_MAX_AUDITS_PER_FINDING)
    return config


def configure(root, board, cadence, interval_hours=None,
              suppress_clean_streak=DEFAULT_SUPPRESS_CLEAN_STREAK,
              max_audits_per_finding=DEFAULT_MAX_AUDITS_PER_FINDING):
    if cadence not in {*CADENCES, 'custom'}:
        raise ValueError('Cadence must be off, daily, weekly or custom')
    hours = CADENCES.get(cadence, interval_hours)
    if not isinstance(hours, int) or isinstance(hours, bool) or hours < 0 or (cadence == 'custom' and hours < 1):
        raise ValueError('Custom interval_hours must be a positive integer')
    if not isinstance(suppress_clean_streak, int) or isinstance(suppress_clean_streak, bool) or suppress_clean_streak < 0:
        raise ValueError('suppress_clean_streak must be a non-negative integer')
    if not isinstance(max_audits_per_finding, int) or isinstance(max_audits_per_finding, bool) or max_audits_per_finding < 1:
        raise ValueError('max_audits_per_finding must be a positive integer')
    directory = review_dir(root, board)
    with locked(directory):
        existing = {}
        config_file = directory / 'config.json'
        if config_file.is_file():
            existing = json.loads(config_file.read_text())
        config = {**existing, 'cadence': cadence, 'interval_hours': hours,
                  'suppress_clean_streak': suppress_clean_streak,
                  'max_audits_per_finding': max_audits_per_finding}
        atomic_write(config_file, json.dumps(config, indent=2) + '\n')
        if not (directory / 'FINDINGS.md').exists():
            atomic_write(directory / 'FINDINGS.md',
                         f'# {board} continuous improvement findings\n\n'
                         'Owner: `project-auditor`. Other profiles submit reports on their cards.\n\n'
                         'No findings assessed yet. Preserve accepted, deferred, rejected and verified outcomes.\n')


def hermes(board, *args):
    command = ['hermes', '--profile', 'default', 'kanban', '--board', board, *args, '--json']
    env = os.environ.copy()
    if env.get('HERMES_ROOT'):
        env['HERMES_HOME'] = env['HERMES_ROOT']
    result = subprocess.run(command, check=True, capture_output=True, text=True, timeout=60, env=env)
    return json.loads(result.stdout)


def board_tasks(root, board):
    """Read durable task state without CLI initialization or readiness promotion.

    Hermes CLI reads may enter a write transaction, which delegated terminal
    subprocesses correctly reject. A SQLite mode=ro connection preserves that
    write fence and reads the requested board regardless of inherited DB pins.
    Missing databases fail closed; never create or migrate them here.
    """
    database = review_dir(root, board).parent / 'kanban.db'
    with closing(sqlite3.connect(database.resolve().as_uri() + '?mode=ro', uri=True,
                                   timeout=10)) as connection:
        connection.row_factory = sqlite3.Row
        connection.execute('PRAGMA query_only = ON')
        return [dict(row) for row in connection.execute(
            'SELECT id, title, body, assignee, status, tenant, created_by FROM tasks')]


def tick(root, now=None):
    now = int(time.time()) if now is None else now
    errors = []
    for board_file in sorted((root / 'kanban/boards').glob('*/board.json')):
        try:
            tick_board(root, board_file, now)
        except (ValueError, OSError, RuntimeError, sqlite3.Error, subprocess.SubprocessError) as exc:
            errors.append(f'{board_file.parent.name}: {exc}')
    if errors:
        raise RuntimeError('; '.join(errors))


def board_state_line(root, board):
    findings = read_jsonl(findings_index(root, board))
    open_findings = sum(1 for entry in findings
                        if entry.get('status') not in {'rejected', 'verified', 'failed'})
    metrics = read_jsonl(metrics_index(root, board))
    if not metrics:
        return f'State: {open_findings} open findings; no recorded audits.'
    last = metrics[-1]
    outcome = last.get('outcome', 'unknown')
    count = last.get('findings')
    detail = '' if not isinstance(count, int) else f' ({count} finding{"s" if count != 1 else ""})'
    return f'State: {open_findings} open findings; last audit {last.get("task", "?")}: {outcome}{detail}.'


def opportunity_body(root, board):
    return '\n'.join([
        'Goal: Choose one worthwhile question about an existing, idle feature.',
        'Change: review-taskforce/FINDINGS.md:1 — assess coverage and pending findings.',
        'Verify: python3 ~/.hermes/scripts/review-taskforce.py status — report real exit.',
        board_state_line(root, board),
        'Constraints:',
        '- Follow the Continuous improvement taskforce policy in your SOUL.md.',
        '- Commission at most one focused audit, or close with a reason to do nothing.',
        '- Assess urgency; forward any already-approved worthwhile batch.',
        '- Preserve findings; do not implement or deploy.',
        '- Run chain-check before any follow-up audit of a known finding.',
    ])


def suppressed_by_clean_streak(root, board):
    config = load_config(root, board)
    limit = config.get('suppress_clean_streak', DEFAULT_SUPPRESS_CLEAN_STREAK)
    if not isinstance(limit, int) or isinstance(limit, bool) or limit < 2:
        return False
    outcomes = [entry.get('outcome') for entry in read_jsonl(metrics_index(root, board))[-limit:]]
    return len(outcomes) >= limit and all(outcome == 'clean' for outcome in outcomes)


def tick_board(root, board_file, now):
    board = board_file.parent.name
    if board.startswith('_'):
        return
    directory = review_dir(root, board)
    config_file = directory / 'config.json'
    if not config_file.exists():
        return
    with locked(directory):
        config = json.loads(config_file.read_text())
        hours = config['interval_hours']
        if not isinstance(hours, int) or isinstance(hours, bool) or hours < 0:
            raise ValueError(f'Invalid cadence for {board}')
        if not hours:
            return
        if suppressed_by_clean_streak(root, board):
            return
        state_file = directory / 'schedule.json'
        state = json.loads(state_file.read_text()) if state_file.exists() else {}
        if now - state.get('last_created_at', 0) < hours * 3600:
            return
        tasks = board_tasks(root, board)
        if any(t.get('tenant') == TENANT and (t.get('title') == OPPORTUNITY_TITLE
               or t.get('created_by') == 'review-taskforce-scheduler')
               and t['status'] not in {'done', 'archived'} for t in tasks):
            return
        board_info = json.loads(board_file.read_text())
        workdir = Path(board_info.get('default_workdir') or '')
        if not workdir.is_absolute() or not workdir.is_dir():
            raise ValueError(f'Board {board} needs an existing absolute default_workdir')
        is_git = subprocess.run(['git', '-C', str(workdir), 'rev-parse', '--git-dir'],
                                capture_output=True).returncode == 0
        body = opportunity_body(root, board)
        if len(body) > 1000 or len(body.splitlines()) > 15:
            body = body.replace(board_state_line(root, board), 'State: see FINDINGS.md.')
        # Hermes deduplicates retries even if creation succeeded but our state write failed.
        key = f'taskforce-opportunity:{board}:{now // (hours * 3600)}'
        created = hermes(board, 'create', OPPORTUNITY_TITLE, '--assignee', 'project-auditor',
                         '--tenant', TENANT, '--created-by', 'review-taskforce-scheduler',
                         '--priority', '-10', '--workspace', 'worktree' if is_git else f'dir:{workdir}',
                         '--idempotency-key', key, '--body', body)
        task_id = created['id']
        atomic_write(state_file, json.dumps({'last_created_at': now, 'task_id': task_id}) + '\n')
        print(f'{board}: opportunity check {task_id}')


def owned_paths(task):
    """Collect file scope from Change/Scope lines; an unscoped card guards everything."""
    text = task.get('body') or ''
    owned = []
    for match in re.finditer(r'^\s*-?\s*(?:Change|Scope):\s*(.+)$', text, re.M):
        owned += re.findall(r'(?<![\w/])(?:[\w.-]+/)+[\w.*-]*', match.group(1))
    return [path.rstrip('/') for path in owned]


def paths_overlap(paths, owned):
    return not owned or any(a.rstrip('/').startswith(b.rstrip('/') + '/')
        or b.rstrip('/').startswith(a.rstrip('/') + '/') or a.rstrip('/') == b.rstrip('/')
        for a in paths for b in owned)


def active_overlaps(root, board, paths, statuses):
    """Implementer cards in the given statuses whose owned files overlap the audit scope."""
    if not paths or any(not is_relative_path(p) for p in paths):
        raise ValueError('Name explicit project-relative paths to audit')
    paths = [Path(p).as_posix() for p in paths]
    own = json.loads((review_dir(root, board).parent / 'board.json').read_text())
    project = own.get('default_workdir')
    overlaps = {}
    # Cross-board cards sharing the same checkout are also protected.
    for board_file in sorted((root / 'kanban/boards').glob('*/board.json')):
        other = board_file.parent.name
        if other.startswith('_'):
            continue
        info = json.loads(board_file.read_text())
        if other != board and (not project or info.get('default_workdir') != project):
            continue
        for task in board_tasks(root, other):
            if task.get('status') not in statuses or task.get('assignee') not in IMPLEMENTERS:
                continue
            if paths_overlap(paths, owned_paths(task)):
                overlaps[task['id']] = {'board': other, 'task_id': task['id'],
                                       'assignee': task['assignee'], 'status': task['status']}
    return list(overlaps.values())


def scope_conflicts(root, board, paths):
    return active_overlaps(root, board, paths, ACTIVE_STATUSES)


def pending_overlaps(root, board, paths):
    return active_overlaps(root, board, paths, PENDING_STATUSES)


def classified_rules(root, board):
    rules = {rule_id: dict(rule) for rule_id, rule in DEFAULT_CLASSIFY_RULES.items()}
    path = review_dir(root, board) / 'classify.json'
    if path.is_file():
        override = json.loads(path.read_text()).get('rules', {})
        for rule_id, rule in override.items():
            rules[rule_id] = rule
    return rules


def classify_paths(root, board, paths):
    """Tripwire against the approval rules; a hit demands an approval or a reason."""
    if not paths or any(not is_relative_path(p) for p in paths):
        raise ValueError('Name explicit project-relative paths to classify')
    rules = classified_rules(root, board)
    hits = []
    for raw in paths:
        path = Path(raw).as_posix()
        basename = PurePosixPath(path).name
        for rule_id in sorted(rules):
            rule = rules[rule_id]
            reasons = []
            for prefix in rule.get('paths', ()):
                prefix = prefix.rstrip('/')
                if path == prefix or path.startswith(prefix + '/'):
                    reasons.append(f'under {prefix}/')
            if basename in rule.get('basenames', ()):
                reasons.append(f'manifest {basename}')
            for pattern in rule.get('patterns', ()):
                if re.search(pattern, path):
                    reasons.append(f'matches {pattern}')
            if reasons:
                hits.append({'rule': rule_id, 'label': rule.get('label', ''), 'path': path,
                             'reasons': reasons})
    return hits


def findings_load(root, board):
    return read_jsonl(findings_index(root, board))


def finding_entry(root, board, finding_id):
    for entry in findings_load(root, board):
        if entry.get('id') == finding_id:
            return entry
    return None


def require_profile(profile, allowed):
    if os.environ.get('HERMES_PROFILE') not in allowed:
        raise PermissionError(f'Only {sorted(allowed)} may run this command')


def findings_mint(root, board, finding_id=None, feature='', question='', source_task=''):
    require_profile('write', MUTATING_PROFILES)
    entries = findings_load(root, board)
    known = {entry.get('id') for entry in entries}
    if finding_id is None:
        numbers = [int(match.group(1)) for entry in entries
                   for match in [re.fullmatch(r'CI-(\d{3})', str(entry.get('id', '')))] if match]
        finding_id = f'CI-{(max(numbers) + 1) if numbers else 1:03d}'
    if not FINDING_ID.fullmatch(finding_id):
        raise ValueError('Finding IDs start with a letter/digit and use only . _ - characters')
    if finding_id in known:
        raise ValueError(f'Finding {finding_id} already exists in the index')
    entry = {'id': finding_id, 'status': 'open', 'feature': feature, 'question': question,
             'source_task': source_task, 'tasks': [], 'created_at': int(time.time())}
    append_jsonl(findings_index(root, board), entry)
    print(finding_id)
    return entry


def findings_link(root, board, finding_id, task_id, role):
    require_profile('link', MUTATING_PROFILES)
    if role not in TASK_ROLES:
        raise ValueError(f'Role must be one of {sorted(TASK_ROLES)}')
    entry = finding_entry(root, board, finding_id)
    if entry is None:
        raise ValueError(f'Unknown finding: {finding_id}; mint it first')
    entries = findings_load(root, board)
    for candidate in entries:
        if candidate.get('id') != finding_id:
            continue
        tasks = candidate.setdefault('tasks', [])
        if not any(task.get('task_id') == task_id and task.get('role') == role for task in tasks):
            tasks.append({'task_id': task_id, 'role': role, 'at': int(time.time())})
    write_jsonl(findings_index(root, board), entries)


def findings_set_status(root, board, finding_id, status):
    require_profile('status', MUTATING_PROFILES)
    if status not in FINDING_STATUSES:
        raise ValueError(f'Status must be one of {sorted(FINDING_STATUSES)}')
    entries = findings_load(root, board)
    for candidate in entries:
        if candidate.get('id') == finding_id:
            candidate['status'] = status
            candidate['status_history'] = candidate.get('status_history', []) + [
                {'status': status, 'at': int(time.time())}]
            write_jsonl(findings_index(root, board), entries)
            return
    raise ValueError(f'Unknown finding: {finding_id}')


def finding_audit_count(root, board, finding_id):
    """Count commissioned audits for a finding: reviewer cards citing it plus index links."""
    tasks = {task['id'] for task in board_tasks(root, board)
             if task.get('tenant') == TENANT and task.get('assignee') == REVIEWER
             and finding_id in (task.get('body') or '')}
    entry = finding_entry(root, board, finding_id)
    if entry:
        tasks |= {task['task_id'] for task in entry.get('tasks', []) if task.get('role') == 'audit'}
    return tasks


def chain_check(root, board, finding_id):
    config = load_config(root, board)
    limit = config.get('max_audits_per_finding', DEFAULT_MAX_AUDITS_PER_FINDING)
    audits = finding_audit_count(root, board, finding_id)
    allowed = len(audits) < limit
    print(json.dumps({'finding': finding_id, 'audits': sorted(audits), 'count': len(audits),
                      'limit': limit, 'allowed': allowed}, indent=2))
    return allowed


REQUIRED_METADATA = ('slice', 'question', 'scope_paths', 'revision', 'outcome',
                     'findings', 'checked_and_clean', 'unknowns', 'checks')
REQUIRED_FINDING = ('file', 'line', 'severity', 'axis', 'evidence', 'suggested_fix',
                    'benefit', 'tradeoffs', 'verification', 'confidence')


def validate_report(metadata):
    """Return violations for a reviewer report; high/critical claims need executed checks."""
    violations = []
    if not isinstance(metadata, dict):
        return ['report metadata must be a JSON object']

    def note(problem):
        violations.append(problem)

    for key in REQUIRED_METADATA:
        if key not in metadata:
            note(f'missing required key: {key}')
    for key in ('slice', 'question', 'revision'):
        if not isinstance(metadata.get(key), str) or not metadata.get(key, '').strip():
            note(f'{key} must be a non-empty string')
    if metadata.get('outcome') not in OUTCOMES:
        note(f'outcome must be one of {sorted(OUTCOMES)}')
    paths = metadata.get('scope_paths')
    if not isinstance(paths, list) or not paths:
        note('scope_paths must be a non-empty list')
    else:
        violations.extend(f'scope_paths entry is not project-relative: {p}' for p in paths if not is_relative_path(p))

    checks = metadata.get('checks')
    executed = []
    if not isinstance(checks, list):
        note('checks must be a list of {command, exit_code}')
    else:
        for index, check in enumerate(checks):
            if not isinstance(check, dict) or not isinstance(check.get('command'), str):
                note(f'checks[{index}] needs a command string')
                continue
            if isinstance(check.get('exit_code'), int) and not isinstance(check.get('exit_code'), bool):
                executed.append(check)
            else:
                note(f'checks[{index}] needs an integer exit_code from a real run')

    findings = metadata.get('findings')
    if findings is None:
        findings = []
    if not isinstance(findings, list):
        note('findings must be a list')
        findings = []
    if metadata.get('outcome') == 'findings' and not findings:
        note('outcome findings requires at least one finding')
    for index, finding in enumerate(findings):
        if not isinstance(finding, dict):
            note(f'findings[{index}] must be an object')
            continue
        for key in REQUIRED_FINDING:
            if key not in finding:
                note(f'findings[{index}] missing required key: {key}')
        if not is_relative_path(finding.get('file', '')):
            note(f'findings[{index}].file must be a project-relative path')
        if not isinstance(finding.get('line'), int) or isinstance(finding.get('line'), bool) or finding.get('line', 0) < 1:
            note(f'findings[{index}].line must be a positive integer')
        if finding.get('severity') not in SEVERITIES:
            note(f'findings[{index}].severity must be one of {sorted(SEVERITIES)}')
        elif finding.get('severity') in {'critical', 'high'}:
            if finding.get('confidence') != 'verified':
                note(f'findings[{index}] severity {finding["severity"]} requires confidence verified')
            if not executed:
                note(f'findings[{index}] severity {finding["severity"]} requires an executed check '
                     'in checks[] with a real exit code')
        if finding.get('axis') not in AXES:
            note(f'findings[{index}].axis must be one of {sorted(AXES)}')
        if finding.get('confidence') not in CONFIDENCES:
            note(f'findings[{index}].confidence must be one of {sorted(CONFIDENCES)}')

    for key in ('checked_and_clean', 'unknowns'):
        value = metadata.get(key)
        if key in metadata and not isinstance(value, list):
            note(f'{key} must be a list')

    def scan(value, where):
        if isinstance(value, str):
            if any(marker in value for marker in SECRET_MARKERS):
                note(f'possible secret material in {where}')
        elif isinstance(value, list):
            for index, item in enumerate(value):
                scan(item, f'{where}[{index}]')
        elif isinstance(value, dict):
            for key, item in value.items():
                scan(item, f'{where}.{key}')

    scan(metadata, 'report')
    return violations


def record_audit(root, board, task, metadata=None, outcome=None, slice_name=None,
                  revision=None, findings=None, duration_seconds=None):
    require_profile('record', TELEMETRY_PROFILES)
    if metadata is not None:
        data = json.loads(Path(metadata).read_text())
        if not isinstance(data, dict):
            raise ValueError('Report metadata must be a JSON object')
        slice_name = slice_name or data.get('slice')
        outcome = outcome or data.get('outcome')
        revision = revision or data.get('revision')
        findings = len(data.get('findings') or []) if findings is None else findings
    if outcome not in OUTCOMES:
        raise ValueError(f'outcome must be one of {sorted(OUTCOMES)}')
    entry = {'task': task, 'slice': slice_name, 'outcome': outcome, 'revision': revision,
             'findings': findings, 'duration_seconds': duration_seconds}
    append_jsonl(metrics_index(root, board), entry)
    print(json.dumps(entry, sort_keys=True))


def write_document(root, board, name, content, expected):
    if name == 'FINDINGS.md':
        allowed = MUTATING_PROFILES
    elif PLAN_NAME.fullmatch(name):
        allowed = MUTATING_PROFILES
    elif REPORT_NAME.fullmatch(name):
        allowed = REPORT_PROFILES
    else:
        raise ValueError('Use FINDINGS.md, plans/<batch-name>.md or reports/<task-slug>.md')
    if os.environ.get('HERMES_PROFILE') not in allowed:
        raise PermissionError(f'Only {sorted(allowed)} may publish {name}')
    if not content.strip():
        raise ValueError('Document must not be empty')
    directory = review_dir(root, board)
    with locked(directory):
        path = directory / name
        if name == 'FINDINGS.md':
            actual = digest(path) if path.exists() else 'missing'
            if not expected or actual != expected:
                raise ValueError('Findings changed; reread and merge before publishing')
        elif path.exists():
            if path.read_text() == content:
                return path
            raise ValueError(f'{name} is immutable; publish a new revision')
        atomic_write(path, content)
        return path


def board_status(root, board):
    directory = review_dir(root, board)
    config_file = directory / 'config.json'
    findings = directory / 'FINDINGS.md'
    index = findings_load(root, board)
    metrics = read_jsonl(metrics_index(root, board))
    by_status = {}
    for entry in index:
        by_status[entry.get('status', 'open')] = by_status.get(entry.get('status', 'open'), 0) + 1
    return {'board': board, 'directory': str(directory),
            'config': load_config(root, board) if config_file.exists() else
                      {'cadence': 'off', 'interval_hours': 0,
                       'suppress_clean_streak': DEFAULT_SUPPRESS_CLEAN_STREAK,
                       'max_audits_per_finding': DEFAULT_MAX_AUDITS_PER_FINDING},
            'findings_sha256': digest(findings) if findings.exists() else 'missing',
            'findings': {'total': len(index), 'by_status': by_status,
                         'ids': [entry.get('id') for entry in index]},
            'audits': {'count': len(metrics), 'last': metrics[-1] if metrics else None},
            'tasks': [{key: task.get(key) for key in ('id', 'title', 'status', 'assignee', 'tenant')}
                      for task in board_tasks(root, board) if task['status'] not in {'done', 'archived'}]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--board', default=os.environ.get('HERMES_KANBAN_BOARD'))
    commands = parser.add_subparsers(dest='command', required=True)
    configure_parser = commands.add_parser('configure')
    configure_parser.add_argument('--cadence', choices=[*CADENCES, 'custom'], required=True)
    configure_parser.add_argument('--interval-hours', type=int)
    configure_parser.add_argument('--suppress-clean-streak', type=int,
                                  default=DEFAULT_SUPPRESS_CLEAN_STREAK)
    configure_parser.add_argument('--max-audits-per-finding', type=int,
                                  default=DEFAULT_MAX_AUDITS_PER_FINDING)
    commands.add_parser('tick')
    commands.add_parser('status')
    scope = commands.add_parser('check-scope')
    scope.add_argument('paths', nargs='+')
    classify = commands.add_parser('classify')
    classify.add_argument('paths', nargs='+')
    validate = commands.add_parser('validate-report')
    validate.add_argument('--metadata', required=True, help='path to the report metadata JSON')
    chain = commands.add_parser('chain-check')
    chain.add_argument('--finding', required=True)
    findings = commands.add_parser('findings')
    findings_commands = findings.add_subparsers(dest='findings_command', required=True)
    mint = findings_commands.add_parser('mint')
    mint.add_argument('--id')
    mint.add_argument('--feature', default='')
    mint.add_argument('--question', default='')
    mint.add_argument('--source-task', default='')
    link = findings_commands.add_parser('link')
    link.add_argument('--id', required=True)
    link.add_argument('--task', required=True)
    link.add_argument('--role', required=True, choices=sorted(TASK_ROLES))
    findings_commands.add_parser('list')
    show = findings_commands.add_parser('show')
    show.add_argument('--id', required=True)
    set_status = findings_commands.add_parser('set-status')
    set_status.add_argument('--id', required=True)
    set_status.add_argument('--status', required=True, choices=sorted(FINDING_STATUSES))
    record = commands.add_parser('record-audit')
    record.add_argument('--task', required=True)
    record.add_argument('--metadata', help='path to the report metadata JSON')
    record.add_argument('--outcome', choices=sorted(OUTCOMES))
    record.add_argument('--slice')
    record.add_argument('--revision')
    record.add_argument('--findings', type=int)
    record.add_argument('--duration-seconds', type=int)
    write = commands.add_parser('write')
    write.add_argument('--source', type=Path, required=True)
    write.add_argument('--name', default='FINDINGS.md')
    write.add_argument('--expected-sha256')
    args = parser.parse_args()
    root = Path(os.environ.get('HERMES_ROOT', str(Path.home() / '.hermes')))
    if args.command == 'tick':
        tick(root)
        return 0
    review_dir(root, args.board or '')
    if args.command == 'configure':
        configure(root, args.board, args.cadence, args.interval_hours,
                  args.suppress_clean_streak, args.max_audits_per_finding)
    elif args.command == 'status':
        print(json.dumps(board_status(root, args.board), indent=2))
    elif args.command == 'check-scope':
        conflicts = scope_conflicts(root, args.board, args.paths)
        pending = pending_overlaps(root, args.board, args.paths)
        print(json.dumps({'safe_to_audit': not conflicts, 'conflicts': conflicts,
                          'pending_overlap': pending}, indent=2))
        return 1 if conflicts else 0
    elif args.command == 'classify':
        hits = classify_paths(root, args.board, args.paths)
        print(json.dumps({'decision': 'required' if hits else 'automatic',
                          'paths': [Path(p).as_posix() for p in args.paths], 'hits': hits}, indent=2))
        return 1 if hits else 0
    elif args.command == 'validate-report':
        violations = validate_report(json.loads(Path(args.metadata).read_text()))
        print(json.dumps({'valid': not violations, 'violations': violations}, indent=2))
        return 2 if violations else 0
    elif args.command == 'chain-check':
        return 0 if chain_check(root, args.board, args.finding) else 1
    elif args.command == 'findings':
        if args.findings_command == 'mint':
            findings_mint(root, args.board, args.id, args.feature, args.question, args.source_task)
        elif args.findings_command == 'link':
            findings_link(root, args.board, args.id, args.task, args.role)
        elif args.findings_command == 'list':
            print(json.dumps(findings_load(root, args.board), indent=2))
        elif args.findings_command == 'show':
            entry = finding_entry(root, args.board, args.id)
            if entry is None:
                print(f'taskforce: unknown finding: {args.id}', file=sys.stderr)
                return 2
            print(json.dumps(entry, indent=2))
        elif args.findings_command == 'set-status':
            findings_set_status(root, args.board, args.id, args.status)
    elif args.command == 'record-audit':
        record_audit(root, args.board, args.task, args.metadata, args.outcome,
                     args.slice, args.revision, args.findings, args.duration_seconds)
    elif args.command == 'write':
        print(write_document(root, args.board, args.name, args.source.read_text(), args.expected_sha256))
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (ValueError, PermissionError, OSError, RuntimeError, sqlite3.Error, subprocess.SubprocessError) as exc:
        print(f'taskforce: {exc}', file=sys.stderr)
        sys.exit(2)
