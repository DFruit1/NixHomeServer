#!/usr/bin/env python3
"""Read-only Hermes historical analytics: what happened, and to which decision it speaks.

Sibling of kanban-performance.py. It answers workflow-policy questions the
performance report leaves open: where cards wait, how often first attempts
succeed, whether review and escalation levers actually move cards, what
recurring work costs in tokens, and whether the audit sweep cadence is
earning its hours. Every metric is paired with the decision it can change;
metrics without a decision rot into noise.

Inputs are opened strictly read-only (board kanban.db, profile state.db, the
board review/ JSONL streams). The only write is --snapshot, which appends one
JSON line per run to <root>/state/analytics/snapshots.jsonl under a bounded
retention rewrite, mirroring review-taskforce.py's append-only storage.
"""
import argparse
from collections import Counter, defaultdict
from contextlib import contextmanager
import datetime as dt
import json
import math
import os
from pathlib import Path
import sqlite3
import tempfile
import time

SNAPSHOT_SCHEMA_VERSION = 1
SNAPSHOT_KEEP = 400
MAX_EVENT_ROWS = 200000
MAX_RUN_ROWS = 20000
MAX_COMMENT_TAIL = 4000
JSONL_TAIL_BYTES = 131072
MAX_SESSION_CHUNK = 400
MAX_WAITS = 20000
DAY = 86400.0
RUN_FAILURE_STATUSES = {'failed', 'crashed', 'timed_out', 'spawn_failed', 'gave_up'}
FAILURE_CAUSE_FALLBACK = {'crashed': 'worker_crash', 'timed_out': 'timeout',
                          'spawn_failed': 'spawn_failure', 'gave_up': 'retry_exhausted'}


def distribution(values, scale=None):
    values = sorted(values)
    def out(value):
        return round(value, scale) if scale else value
    return {'n': len(values), **{name: out(values[math.ceil(len(values) * q) - 1])
                                 if values else None
                                 for name, q in [('p50', .5), ('p95', .95)]}}


def days(seconds):
    return round(seconds / DAY, 2) if seconds is not None else None


@contextmanager
def readonly(path):
    db = sqlite3.connect(path.resolve().as_uri() + '?mode=ro', uri=True, timeout=2)
    try:
        db.execute('PRAGMA query_only=ON')
        db.execute('BEGIN')
        yield db
    finally:
        db.close()


def jsonl_tail(path, since, until):
    """Bounded tail read of an append-only JSONL stream; entries need numeric 'at'."""
    try:
        with path.open('rb') as stream:
            stream.seek(0, 2)
            end = stream.tell()
            stream.seek(max(0, end - JSONL_TAIL_BYTES))
            if end > JSONL_TAIL_BYTES:
                stream.readline()  # drop a possibly truncated leading line
            lines = stream.read().decode('utf-8', 'replace').splitlines()
    except (OSError, UnicodeError):
        return None
    entries = []
    for line in lines:
        try:
            entry = json.loads(line)
        except json.JSONDecodeError:
            continue
        at = entry.get('at')
        if isinstance(at, (int, float)) and math.isfinite(at) and since <= at < until:
            entries.append(entry)
    return entries


def lifecycle(db, since, until, now):
    """Stage waits reconstructed from task_events; open-card ages from tasks.

    - claim_wait: created -> first claimed/spawn inside the window.
    - lead_time: created -> completed for cards completed inside the window.
    - review: cards that came back with changes_requested vs. cards whose
      first review_requested was followed directly by completion.
    """
    rows = db.execute(
        '''SELECT task_id,kind,payload,created_at FROM task_events
           WHERE created_at<? ORDER BY task_id,created_at
           LIMIT ?''', (until, MAX_EVENT_ROWS)).fetchall()
    if len(rows) >= MAX_EVENT_ROWS:
        return None
    per_task = defaultdict(list)
    for task_id, kind, payload, created_at in rows:
        per_task[task_id].append((created_at, kind))
    if len(per_task) >= MAX_EVENT_ROWS // 8:
        return None

    claim_waits, lead_times, open_card_ages = [], [], []
    review_rounds, review_repaired = [], 0
    completed_in_window = 0
    for card, events in per_task.items():
        created = next((at for at, kind in events if kind == 'created'), None)
        claimed = next((at for at, kind in events
                        if kind in ('claimed', 'spawned') and since <= at < until), None)
        if created is not None and claimed is not None:
            claim_waits.append(max(0.0, claimed - created) / DAY)
        completed = max((at for at, kind in events
                         if kind == 'completed' and since <= at < until), default=None)
        if completed is not None:
            completed_in_window += 1
            if created is not None:
                lead_times.append(max(0.0, completed - created) / DAY)
        if completed is None:
            last_activity = max((at for at, _ in events), default=None)
            roots = [value for value in (created, last_activity) if value is not None]
            if roots:
                open_card_ages.append(max(0.0, now - min(roots)) / DAY)
        changes = [at for at, kind in events if kind == 'changes_requested'
                   and since <= at < until]
        requested = [at for at, kind in events if kind == 'review_requested']
        if changes:
            review_repaired += 1
            review_rounds.append(len(changes))

    status_rows = db.execute(
        '''SELECT status,count(*),min(created_at) FROM tasks
           WHERE status NOT IN ('done','archived') GROUP BY status''').fetchall()
    by_status = {}
    for status, count, oldest in status_rows:
        by_status[status] = {'count': count, 'oldest_created_age_days': days(now - oldest)}
    return {
        'claim_wait_days': distribution(claim_waits, 2),
        'lead_time_days': distribution(lead_times, 2),
        'completed_cards': completed_in_window,
        'open_card_current_age_days': distribution(open_card_ages, 2),
        'review_changed_cards': review_repaired,
        'review_rounds_per_changed_card': distribution(review_rounds),
        'open_cards_by_status': by_status,
    }


def dependency_waits(db, until):
    """dependency_wait events name the blocking parent in payload.parent.

    Duration is approximated by the gap to the child's next event of any
    kind; an event with no later sibling still waits until the collection
    time, so open waits stay visible rather than vanishing.
    """
    rows = db.execute('''SELECT task_id,payload,created_at FROM task_events
        WHERE kind='dependency_wait' AND created_at<? ORDER BY task_id,created_at LIMIT ?''',
        (until, MAX_WAITS)).fetchall()
    waits, parents, cards = [], Counter(), set()
    per_task = defaultdict(list)
    for task_id, payload, created_at in rows:
        per_task[task_id].append((created_at, payload))
    for card, events in per_task.items():
        cards.add(card)
        times = [at for at, _ in events]
        for i, (at, payload) in enumerate(events):
            end = times[i + 1] if i + 1 < len(times) else until
            wait = (end - at) / DAY
            if 0 < wait <= 90:
                waits.append(wait)
            parent = None
            if payload:
                try:
                    parent = json.loads(payload).get('parent')
                except (json.JSONDecodeError, AttributeError):
                    parent = None
            parents[str(parent)[:64] if parent else 'unknown'] += 1
    return {'cards_with_dependency_waits': len(cards),
            'wait_days': distribution(waits, 2),
            'chronic_parents': [{'parent': name, 'waits': count}
                                for name, count in parents.most_common(5)]}


def rework(db, since, until):
    """First-pass yield, repeat attempts and failure causes from task_runs."""
    rows = db.execute('''SELECT task_id,status,outcome FROM task_runs
        WHERE started_at>=? AND started_at<? LIMIT ?''', (since, until, MAX_RUN_ROWS)).fetchall()
    if len(rows) >= MAX_RUN_ROWS:
        return None
    attempts = Counter(task for task, _, _ in rows)
    final = {}
    for task, status, outcome in rows:
        final[task] = outcome or status
    succeeded = {'completed', 'done'}
    completed = sum(1 for value in final.values() if value in succeeded)
    first_pass = sum(1 for task in final if final[task] in succeeded
                     and attempts[task] == 1)
    causes = Counter()
    for _, status, outcome in rows:
        if outcome in RUN_FAILURE_STATUSES or status in RUN_FAILURE_STATUSES:
            causes[FAILURE_CAUSE_FALLBACK.get(outcome) or
                   FAILURE_CAUSE_FALLBACK.get(status, 'unknown')] += 1
    return {'tasks_with_runs': len(attempts),
            'completed_tasks': completed,
            'first_pass_tasks': first_pass,
            'first_pass_yield': round(first_pass / completed, 2) if completed else None,
            'repeat_attempt_tasks': sum(n > 1 for n in attempts.values()),
            'failure_outcomes': dict(causes)}


def reblocks(db, since, until):
    """Churn between blocked and unblocked: repeated stalls per card."""
    rows = db.execute('''SELECT task_id,kind FROM task_events
        WHERE kind IN ('blocked','unblocked') AND created_at>=? AND created_at<?
        ORDER BY task_id,created_at''', (since, until)).fetchall()
    cycles, re_stall = 0, 0
    state = {}
    for task, kind in rows:
        if kind == 'blocked':
            cycles += 1
            if state.get(task) == 'blocked':
                re_stall += 1
        state[task] = kind
    return {'block_events': cycles, 'blocks_on_already_blocked_cards': re_stall,
            'cards_with_blocks': len({task for task, _ in rows})}


def review_loop(db, since, until, review_dir):
    """Reviewer verdicts plus what came out of the audit streams."""
    rows = db.execute(
        '''SELECT CASE WHEN json_valid(metadata)
                  AND json_type(metadata,'$.verdict')='text'
                  THEN json_extract(metadata,'$.verdict') END
           FROM task_runs WHERE started_at>=? AND started_at<? LIMIT ?''',
        (since, until, MAX_RUN_ROWS)).fetchall()
    verdicts = Counter(row[0] for row in rows
                       if row[0] in {'accept', 'request-changes'})
    repairs = verdicts.get('request-changes', 0)
    accepts = verdicts.get('accept', 0)
    findings_entries = jsonl_tail(review_dir / 'findings.jsonl', since, until)
    findings_outcomes = Counter(entry.get('outcome') for entry in findings_entries or []
                                if isinstance(entry.get('outcome'), str))
    sweeps_entries = jsonl_tail(review_dir / 'sweeps.jsonl', since, until)
    sweeps = None
    if sweeps_entries is not None:
        outcome_counts = Counter(entry.get('outcome') for entry in sweeps_entries
                                 if isinstance(entry.get('outcome'), str))
        streak = 0
        for entry in reversed(sweeps_entries):
            if entry.get('outcome') == 'no_candidate':
                streak += 1
            else:
                break
        sweeps = {'entries': len(sweeps_entries), 'outcomes': dict(outcome_counts),
                  'current_no_candidate_streak': streak}
    return {'verdicts': dict(verdicts),
            'repair_rate': round(repairs / max(1, repairs + accepts), 2) if (repairs + accepts) else None,
            'audit_findings': {'entries': len(findings_entries or []),
                               'outcomes': dict(findings_outcomes)},
            'sweeps': sweeps,
            'decision': ('verdicts show review value only when repair_rate>0 and findings outcomes are novel; '
                         'repeated identical findings mean audit scope, not card quality, is off')}


def escalation(db, since, until, now):
    """Did aging-escalation markers and reprioritizations move their card?

    A card is 'released' when it is claimed, spawned or completed after the
    marker; 'acted' adds another-party comments. Percentages are honest only
    when enough markers exist.
    """
    marks = defaultdict(list)
    for task, created_at in db.execute(
            '''SELECT task_id,created_at FROM task_comments
               WHERE author='aging-escalation' AND created_at>=? AND created_at<?''',
            (since, until)).fetchall():
        marks[task].append(created_at)
    events = defaultdict(list)
    for task, kind, created_at in db.execute(
            '''SELECT task_id,kind,created_at FROM task_events
               WHERE kind IN ('claimed','spawned','completed')
                 AND created_at>=? AND created_at<?''', (since, until)).fetchall():
        events[task].append((kind, created_at))
    comments_by_others = defaultdict(list)
    for task, created_at in db.execute(
            '''SELECT task_id,created_at FROM task_comments
               WHERE author!='aging-escalation' AND created_at>=? AND created_at<?''',
            (since, until)).fetchall():
        comments_by_others[task].append(created_at)
    released, acted, response_times = 0, 0, []
    for task, times in marks.items():
        for mark in times:
            claim = any(kind in ('claimed', 'spawned') and at > mark
                        for kind, at in events.get(task, []))
            other = any(at > mark for at in comments_by_others.get(task, []))
            response = min([at for kind, at in events.get(task, []) if at > mark]
                           + [at for at in comments_by_others.get(task, []) if at > mark],
                           default=None)
            if response is not None and response - mark <= 30 * DAY:
                response_times.append((response - mark) / 3600.0)
            if claim:
                released += 1
                acted += 1
            elif other:
                acted += 1
    markers = sum(len(times) for times in marks.values())
    return {'escalation_markers': markers,
            'cards_released_after_marker': released,
            'cards_actively_responded': acted,
            'release_rate': round(released / markers, 2) if markers else None,
            'first_action_hours': distribution(response_times, 1) if response_times
            else {'n': 0, 'p50': None, 'p95': None},
            'decision': ('low release_rate or long p95 means escalation is '
                         'relabeling stale cards rather than speeding pickup; '
                         'then tune thresholds or route blockers instead')}


def token_effort(db, home, since, until, completed_cards):
    """Tokens on worker sessions matched to runs, against completed cards."""
    if db is None or not completed_cards:
        return None
    session_ids = []
    for (session_id,) in db.execute(
            '''SELECT CASE WHEN json_valid(metadata)
                      AND json_type(metadata,'$.worker_session_id')='text'
                      THEN json_extract(metadata,'$.worker_session_id') END
               FROM task_runs WHERE started_at>=? AND started_at<? LIMIT ?''',
            (since, until, MAX_RUN_ROWS)).fetchall():
        if session_id:
            session_ids.append(session_id)
    if not session_ids or home is None or not (home / 'state.db').exists():
        return None
    touched = 0.0
    tokens_in = tokens_out = 0
    try:
        with readonly(home / 'state.db') as state_db:
            for i in range(0, len(session_ids), MAX_SESSION_CHUNK):
                chunk = session_ids[i:i + MAX_SESSION_CHUNK]
                marks = ','.join('?' * len(chunk))
                rows = state_db.execute(
                    f'SELECT input_tokens,output_tokens FROM sessions WHERE id IN ({marks})',
                    chunk).fetchall()
                for in_tokens, out_tokens in rows:
                    touched += 1
                    tokens_in += in_tokens or 0
                    tokens_out += out_tokens or 0
    except (sqlite3.Error, OSError):
        return None
    if not touched:
        return None
    return {'worker_sessions_matched': int(touched),
            'tokens_per_completed_card': {
                'input': round(tokens_in / completed_cards),
                'output': round(tokens_out / completed_cards)},
            'note': 'matched worker-session tokens divided by completed cards; estimate'}


def board_report(db_path, review_dir, home, since, until, now):
    with readonly(db_path) as db:
        life = lifecycle(db, since, until, now)
        result = {
            'lifecycle': life,
            'dependencies': dependency_waits(db, until),
            'rework': rework(db, since, until),
            'reblocks': reblocks(db, since, until),
            'review': review_loop(db, since, until, review_dir),
            'escalation': escalation(db, since, until, now),
        }
        completed = (life or {}).get('completed_cards') or 0
        result['token_effort'] = token_effort(db, home, since, until, completed) \
            if home is not None else None
    return result


def snapshot_path(root):
    return root / 'state' / 'analytics' / 'snapshots.jsonl'


def append_snapshot(root, entry, keep=SNAPSHOT_KEEP):
    """Append one line under bounded retention; atomic rewrite, 0600."""
    path = snapshot_path(root)
    path.parent.mkdir(parents=True, exist_ok=True)
    os.chmod(path.parent, 0o700)
    entries = []
    try:
        entries = [line for line in path.read_text().splitlines() if line.strip()]
    except (OSError, UnicodeError):
        entries = []
    entries.append(json.dumps(entry, sort_keys=True))
    entries = entries[-keep:]
    fd, temporary = tempfile.mkstemp(dir=str(path.parent), prefix='.snapshots.')
    with os.fdopen(fd, 'w') as stream:
        stream.write('\n'.join(entries) + '\n')
        stream.flush()
        os.fsync(stream.fileno())
    os.chmod(temporary, 0o600)
    os.replace(temporary, path)


def evidence_from(snapshot):
    """Headline figures reusable across snapshots, for trend comparison."""
    headline = {}
    for slug, board in (snapshot.get('boards') or {}).items():
        lifecycle = (board or {}).get('lifecycle') or {}
        rework_stats = (board or {}).get('rework') or {}
        review = (board or {}).get('review') or {}
        headline[slug] = {
            'lead_p95_days': (lifecycle.get('lead_time_days') or {}).get('p95'),
            'claim_wait_p95_days': (lifecycle.get('claim_wait_days') or {}).get('p95'),
            'first_pass_yield': rework_stats.get('first_pass_yield'),
            'review_repair_rate': review.get('repair_rate'),
        }
    return headline


def trend_text(current, before):
    before_head, current_head = None, None
    if before:
        before_head = evidence_from(before).get('nixhomeserver') \
            or next(iter(evidence_from(before).values()), None)
    current_head = evidence_from(current).get('nixhomeserver') \
        or next(iter(evidence_from(current).values()), None)
    if not before_head or not current_head:
        return 'no comparable prior snapshot'
    deltas = []
    for key in ('lead_p95_days', 'claim_wait_p95_days'):
        a, b = current_head.get(key), before_head.get(key)
        if a is not None and b is not None:
            drop = f' ({round(a - b, 2)}d)' if (isinstance(a, (int, float))
                                                and isinstance(b, (int, float))) else ''
            deltas.append(f'{key} {b}->{a}{drop}')
    for key in ('first_pass_yield', 'review_repair_rate'):
        a, b = current_head.get(key), before_head.get(key)
        if a is not None and b is not None:
            deltas.append(f'{key} {b}->{a}')
    return '; '.join(deltas) if deltas else 'no comparable prior snapshot'


def render(data):
    stamp = lambda value: (dt.datetime.fromtimestamp(value, dt.timezone.utc)
                           .isoformat(timespec='seconds'))
    lines = [f"HERMES ANALYTICS {stamp(data['since'])} .. {stamp(data['until'])}"]
    for slug, board in sorted(data['boards'].items()):
        if board is None:
            lines.append(f'[{slug}] unreadable')
            continue
        lines.append(f'[{slug}]')
        lifecycle = board['lifecycle']
        if lifecycle is None:
            lines.append('  flow: event volume exceeds read bounds; results omitted')
        else:
            claim, lead = lifecycle['claim_wait_days'], lifecycle['lead_time_days']
            lines.append(
                f"  flow: claim-wait-d p50/p95={claim['p50']}/{claim['p95']}"
                f" lead-time-d p50/p95={lead['p50']}/{lead['p95']}"
                f" completed={lifecycle['completed_cards']}"
                " (aging thresholds 48h/72h should match these, not constants)")
            statuses = ' '.join(f"{status}={value['count']}" for status, value
                                in sorted(lifecycle['open_cards_by_status'].items()))
            lines.append('  open cards: ' + (statuses or 'none'))
        deps = board['dependencies']
        lines.append('  dependencies: cards=' + str(deps['cards_with_dependency_waits'])
                     + ' wait-d p50/p95=' + str(deps['wait_days']['p50']) + '/'
                     + str(deps['wait_days']['p95'])
                     + ' chronic=' + json.dumps(deps['chronic_parents'],
                                                sort_keys=True, separators=(',', ':')))
        rework_stats = board['rework']
        if rework_stats is None:
            lines.append('  rework: run volume exceeds read bounds; results omitted')
        else:
            lines.append('  rework: first-pass-yield=' + str(rework_stats['first_pass_yield'])
                         + f" ({rework_stats['first_pass_tasks']}/"
                           f"{rework_stats['completed_tasks']})"
                         + ' repeat-cards=' + str(rework_stats['repeat_attempt_tasks'])
                         + ' failures=' + json.dumps(rework_stats['failure_outcomes'],
                                                     sort_keys=True, separators=(',', ':')))
            churn = board['reblocks']
            lines.append('  churn: block-events=' + str(churn['block_events'])
                         + ' stall-repeats=' + str(churn['blocks_on_already_blocked_cards']))
        review = board['review']
        lines.append('  review: verdicts=' + json.dumps(review['verdicts'],
                                                        sort_keys=True, separators=(',', ':'))
                     + ' repair-rate=' + str(review['repair_rate'])
                     + ' audit=' + json.dumps(review['audit_findings'],
                                              sort_keys=True, separators=(',', ':'))
                     + ' sweeps=' + json.dumps(review['sweeps'],
                                               sort_keys=True, separators=(',', ':')))
        esc = board['escalation']
        lines.append('  escalation: markers=' + str(esc['escalation_markers'])
                     + ' release-rate=' + str(esc['release_rate'])
                     + ' first-action-h p50/p95=' + str(esc['first_action_hours']['p50'])
                     + '/' + str(esc['first_action_hours']['p95']))
        effort = board.get('token_effort')
        if effort:
            lines.append('  cost: ' + json.dumps(effort, sort_keys=True, separators=(',', ':')))
    lines.append('Trend vs previous snapshot: ' + data['trend'])
    if data['warnings']:
        lines.append(f"Coverage warnings: {len(data['warnings'])}; check --json before decisions.")
    return '\n'.join(lines)


def collect(root, since, until, only_board=None):
    if not all(math.isfinite(v) for v in (since, until)) or since >= until:
        raise ValueError('Expected a finite increasing window')
    if until - since > 366 * DAY:
        raise ValueError('Window must be at most 366 days')
    now = time.time()
    warnings = []
    boards = {}
    paths = sorted((root / 'kanban' / 'boards').glob('*/kanban.db'))
    if only_board:
        paths = [p for p in paths if p.parent.name == only_board]
        if not paths:
            raise ValueError(f'Board {only_board} is missing or unreadable')
    for db_path in paths:
        slug = db_path.parent.name
        if slug.startswith(('_', '.')):
            continue
        review_dir = db_path.parent / 'review'
        try:
            boards[slug] = board_report(db_path, review_dir, root, since, until, now)
        except (sqlite3.Error, OSError, ValueError, json.JSONDecodeError):
            warnings.append({'source': 'board:' + slug, 'reason': 'unreadable_or_unsupported'})
    data = {'schema_version': SNAPSHOT_SCHEMA_VERSION, 'generated_at': now,
            'since': since, 'until': until, 'boards': boards,
            'trend': '', 'warnings': warnings}
    data['trend'] = trend_text(data, previous_snapshot(root, until))
    return data


def previous_snapshot(root, until):
    try:
        with snapshot_path(root).open() as stream:
            entries = [json.loads(line) for line in stream if line.strip()]
    except (OSError, json.JSONDecodeError):
        return None
    earlier = [entry for entry in entries
               if isinstance(entry.get('until'), (int, float))
               and entry['until'] < until
               and isinstance(entry.get('boards'), dict)]
    return earlier[-1] if earlier else None


def install_files(root):
    """Copy this script to <root>/scripts mode 0700; touch no cron job.

    The cron engine executes the installed copy, not the checkout, so every
    script edit needs this step. Inventing or enabling the cron job is a
    deliberate separate action (mirrors kanban-aging-escalation.py).
    """
    source = Path(__file__).resolve()
    scripts = root / 'scripts'
    scripts.mkdir(parents=True, exist_ok=True)
    target = scripts / source.name
    if not target.exists() or target.read_bytes() != source.read_bytes():
        target.write_bytes(source.read_bytes())
    target.chmod(0o700)
    return target


def instant(text):
    try:
        value = dt.datetime.fromisoformat(text.replace('Z', '+00:00'))
        if value.tzinfo is None:
            raise ValueError()
        return value.timestamp()
    except ValueError:
        raise argparse.ArgumentTypeError('Use an ISO timestamp with timezone') from None


def main(argv=()):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--days', type=float, default=7)
    parser.add_argument('--since', type=instant)
    parser.add_argument('--until', type=instant)
    parser.add_argument('--board', help='restrict report to one board slug')
    parser.add_argument('--json', action='store_true')
    parser.add_argument('--snapshot', action='store_true',
                        help='append one line to state/analytics/snapshots.jsonl')
    parser.add_argument('--install-files', action='store_true',
                        help='copy this script to <root>/scripts mode 0700 and exit')
    args = parser.parse_args(argv)

    root = Path(os.environ.get('HERMES_ROOT', str(Path.home() / '.hermes')))
    if args.install_files:
        target = install_files(root)
        print(f'installed {target}; no cron job created')
        return

    until = args.until if args.until is not None else time.time()
    since = args.since if args.since is not None else until - args.days * DAY
    try:
        data = collect(root, since, until, only_board=args.board)
    except ValueError as error:
        parser.error(str(error))
    if args.snapshot:
        append_snapshot(root, {'at': int(time.time()),
                               'schema_version': SNAPSHOT_SCHEMA_VERSION,
                               'since': since, 'until': until,
                               'boards': data['boards']})
        print('snapshot appended to ' + str(snapshot_path(root)))
    if args.json:
        print(json.dumps(data, sort_keys=True))
    else:
        print(render(data))


if __name__ == '__main__':
    main(None)
