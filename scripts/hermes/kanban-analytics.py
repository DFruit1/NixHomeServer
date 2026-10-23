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

Cohort discipline (same convention as kanban-performance.py): a window's
claim-waits measure cards created inside the window; lead-times measure cards
completed inside the window; tests compare same schema_version only.
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

SNAPSHOT_SCHEMA_VERSION = 2
SNAPSHOT_KEEP = 400
READ_DEADLINE_SECONDS = 8
MAX_EVENT_ROWS = 200000
MAX_RUN_ROWS = 20000
JSONL_TAIL_BYTES = 131072
MAX_SESSION_CHUNK = 400
DAY = 86400.0
RELEASE_KINDS = ('unblocked', 'claimed', 'spawned', 'completed')
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
    """Read-only connection that cannot run open-ended scans: a progress
    handler aborts queries past a deadline, so cron use cannot stall."""
    db = sqlite3.connect(path.resolve().as_uri() + '?mode=ro', uri=True, timeout=2)
    deadline = time.monotonic() + READ_DEADLINE_SECONDS
    try:
        db.execute('PRAGMA query_only=ON')
        db.set_progress_handler(lambda: int(time.monotonic() > deadline), 10000)
        db.execute('BEGIN')
        yield db
    finally:
        db.close()


def load_events(db, until):
    """All task_events up to `until`, grouped per card, bounded.

    Returns (per_task, truncated); truncated is True when the bound was hit,
    in which case event-derived metrics must be omitted rather than
    quietly overstated.
    """
    rows = db.execute(
        'SELECT task_id,kind,payload,created_at FROM task_events WHERE created_at<? '
        'ORDER BY task_id,created_at LIMIT ?', (until, MAX_EVENT_ROWS)).fetchall()
    per_task = defaultdict(list)
    for task_id, kind, payload, created_at in rows:
        per_task[task_id].append((created_at, kind, payload))
    return per_task, len(rows) >= MAX_EVENT_ROWS


def payload_value(payload, key):
    """First dict value of `key` in a JSON payload; non-dict payloads give None."""
    try:
        value = json.loads(payload)
    except (json.JSONDecodeError, TypeError):
        return None
    if isinstance(value, dict):
        return value.get(key)
    return None


def load_statuses(db):
    """Open-card snapshot grouped by status and block_kind (the small
    authored vocabulary -- capability, dependency, validation -- never the
    free-text blocked-event payloads)."""
    return db.execute(
        '''SELECT status,count(*),min(created_at),block_kind FROM tasks
           WHERE status NOT IN ('done','archived')
           GROUP BY status,block_kind''').fetchall()


def lifecycle(per_task, statuses, since, until, now):
    """Stage waits reconstructed from task_events; open-card ages from tasks.

    Claim-wait cohort: cards created inside the window. Lead-time cohort:
    cards completed inside the window.
    """
    created_in_window = 0
    claim_waits, lead_times, open_card_ages = [], [], []
    completed_cards = 0
    for card, events in sorted(per_task.items()):
        created = next((at for at, kind, _ in events if kind == 'created'), None)
        if created is not None and since <= created < until:
            created_in_window += 1
            claimed = next((at for at, kind, _ in events
                            if kind in ('claimed', 'spawned') and at >= created), None)
            if claimed is not None and claimed < until:
                claim_waits.append(max(0.0, claimed - created) / DAY)
        completed = max((at for at, kind, _ in events
                         if kind == 'completed' and since <= at < until), default=None)
        if completed is not None:
            completed_cards += 1
            if created is not None:
                lead_times.append(max(0.0, completed - created) / DAY)
        else:
            last_activity = max((at for at, _, _ in events), default=None)
            roots = [value for value in (created, last_activity) if value is not None]
            if roots:
                open_card_ages.append(max(0.0, now - min(roots)) / DAY)
    by_status = {}
    for status, count, oldest, block_kind in statuses:
        entry = by_status.setdefault(status, {'count': 0,
                                              'oldest_created_age_days': None,
                                              'block_kinds': {}})
        entry['count'] += count
        age = days(now - oldest)
        if entry['oldest_created_age_days'] is None or age < entry['oldest_created_age_days']:
            entry['oldest_created_age_days'] = age
        key = block_kind if isinstance(block_kind, str) and block_kind else 'unclassified'
        entry['block_kinds'][key] = entry['block_kinds'].get(key, 0) + count
    return {
        'created_in_window': created_in_window,
        'claim_wait_days': distribution(claim_waits, 2),
        'lead_time_days': distribution(lead_times, 2),
        'completed_cards': completed_cards,
        'open_card_current_age_days': distribution(open_card_ages, 2),
        'open_cards_by_status': by_status,
    }


def dependency_waits(per_task, until, now):
    """Pair each dependency_wait with the card's next release-kind event.

    A wait ends at unblocked/claimed/spawned/completed; consecutive
    dependency_wait events with no release between end at the next wait
    event (re-trigger). A waiter with neither is still open, counted
    separately, so it stays visible rather than being cut off at `until`.
    """
    waits, open_waits = [], 0
    parents, unattributed = Counter(), 0
    cards = set()
    for card, events in per_task.items():
        wait_events = [(at, payload) for at, kind, payload in events
                       if kind == 'dependency_wait']
        if not wait_events:
            continue
        cards.add(card)
        release_times = sorted(at for at, kind, _ in events if kind in RELEASE_KINDS)
        times = [at for at, _ in wait_events]
        for i, (at, payload) in enumerate(wait_events):
            parent = payload_value(payload, 'parent')
            if parent:
                parents[str(parent)[:64]] += 1
            else:
                unattributed += 1
            next_wait = times[i + 1] if i + 1 < len(times) else None
            release = next((t for t in release_times if t > at), None)
            ends = [t for t in (next_wait, release) if t is not None and t > at]
            if ends:
                waits.append(min(min(ends) - at, 90 * DAY) / DAY)
            else:
                open_waits += 1
    return {'cards_with_dependency_waits': len(cards),
            'resolved_wait_days': distribution(waits, 2),
            'open_waits_still_blocked': open_waits,
            'chronic_parents': [{'parent': name, 'waits': count}
                                for name, count in parents.most_common(5)],
            'unattributed_waits': unattributed,
            'note': ('old events predate payload parents; unknown share rises '
                     'with window size, not with current decomposition quality')}


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


def jsonl_status(path, since, until):
    """Bounded tail read with explicit absence vs truly empty, so a missing
    findings/sweeps stream is never reported as 'nothing happened'."""
    if not path.exists():
        return {'status': 'stream_missing'}
    entries = jsonl_tail(path, since, until)
    if entries is None:
        return {'status': 'unreadable'}
    return {'status': 'ok', 'entries': len(entries), 'outcomes': {}}


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

    def stream(name):
        info = jsonl_status(review_dir / name, since, until)
        if info['status'] != 'ok':
            return {'status': info['status'], 'entries': 0, 'outcomes': {}}
        raw = jsonl_tail(review_dir / name, since, until) or []
        outcomes = Counter(entry.get('outcome') for entry in raw
                           if isinstance(entry.get('outcome'), str))
        merged = {'status': 'empty' if not raw else 'ok', 'entries': len(raw),
                  'outcomes': dict(outcomes)}
        if name == 'sweeps.jsonl':
            streak = 0
            for entry in reversed(raw):
                if entry.get('outcome') == 'no_candidate':
                    streak += 1
                else:
                    break
            merged['current_no_candidate_streak'] = streak
        return merged
    return {'verdicts': dict(verdicts),
            'repair_rate': round(repairs / max(1, repairs + accepts), 2)
            if (repairs + accepts) else None,
            'audit_findings': stream('findings.jsonl'),
            'sweeps': stream('sweeps.jsonl'),
            'decision': ('verdicts show review value only when repair_rate>0 and '
                         'findings outcomes are novel; repeated identical findings '
                         'mean audit scope, not card quality, is off')}


def escalation(db, per_task, since, until, claim_p50_days=None):
    """Did aging-escalation markers move their card -- and were they even
    movable?

    Per marker: released (claim/spawn after the marker), responded (another
    party commented), or open. Markers on cards currently gated by block_kind
    could not release by escalation alone, so release_rate is reported both
    overall and excluding currently-gated cards, against the board's
    unescalated claim-wait p50 as reference.
    """
    marks = defaultdict(list)
    for task, created_at in db.execute(
            '''SELECT task_id,created_at FROM task_comments
               WHERE author='aging-escalation' AND created_at>=? AND created_at<?''',
            (since, until)).fetchall():
        marks[task].append(created_at)
    gates = {row[0]: row[1] for row in db.execute(
        '''SELECT id,block_kind FROM tasks WHERE id IN
           (SELECT DISTINCT task_id FROM task_comments
            WHERE author='aging-escalation' AND created_at>=? AND created_at<?)''',
        (since, until)).fetchall()}
    events = {task: [(kind, at) for at, kind, _ in items]
              for task, items in per_task.items()}
    comments_by_others = defaultdict(list)
    for task, created_at in db.execute(
            '''SELECT task_id,created_at FROM task_comments
               WHERE author!='aging-escalation' AND created_at>=? AND created_at<?''',
            (since, until)).fetchall():
        comments_by_others[task].append(created_at)
    released, released_gated, responded, open_unmoved = 0, 0, 0, 0
    response_times = []
    for task, times in marks.items():
        gated = gates.get(task) is not None
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
                released_gated += 1 if gated else 0
            elif gated:
                open_unmoved += 1  # gated card: escalation alone could not release it
            elif other:
                responded += 1
            else:
                open_unmoved += 1
    markers = sum(len(times) for times in marks.values())
    gated_markers = sum(len(times) for task, times in marks.items()
                        if gates.get(task) is not None)
    unmarked = markers - gated_markers
    return {'escalation_markers': markers,
            'markers_on_currently_gated_cards': gated_markers,
            'markers_released': released,
            'markers_released_on_gated_cards': released_gated,
            'markers_responded': responded,
            'markers_open_unmoved': open_unmoved,
            'release_rate': round(released / markers, 2) if markers else None,
            'release_rate_excluding_currently_gated':
                round((released - released_gated) / unmarked, 2) if unmarked else None,
            'first_action_hours': distribution(response_times, 1) if response_times
            else {'n': 0, 'p50': None, 'p95': None},
            'claim_wait_p50_days_reference': claim_p50_days,
            'decision': ('open+unmoved and low release_rate mean escalation is '
                         'relabeling stale cards rather than speeding pickup; '
                         'gated markers release only when their gate does')}


def token_effort(db, root, since, until):
    """Per-card token attribution: for each card completed in the window,
    the sum of tokens on that card's matched worker sessions.

    The per-card average is suppressed (None) when under half the sessions
    matched, because a mismatched denominator would overstate the estimate;
    coverage is always reported.
    """
    runs = db.execute(
        '''SELECT task_id,
                  CASE WHEN json_valid(metadata)
                       AND json_type(metadata,'$.worker_session_id')='text'
                       THEN json_extract(metadata,'$.worker_session_id') END
           FROM task_runs WHERE started_at>=? AND started_at<? LIMIT ?''',
        (since, until, MAX_RUN_ROWS)).fetchall()
    session_of_card = defaultdict(list)
    session_ids = set()
    present = 0
    for task_id, session_id in runs:
        if session_id:
            present += 1
            session_of_card[task_id].append(session_id)
            session_ids.add(session_id)
    if not session_ids or root is None:
        return None
    if not (root / 'state.db').exists() and not (root / 'profiles').exists():
        return None
        return None
    usage = {}
    homes = [root] if (root / 'state.db').exists() else []
    if (root / 'profiles').exists():
        homes += [p for p in sorted((root / 'profiles').iterdir())
                  if (p / 'state.db').exists()]
    try:
        for home in homes:
            with readonly(home / 'state.db') as state_db:
                remaining = sorted(session_ids - set(usage))
                for i in range(0, len(remaining), MAX_SESSION_CHUNK):
                    chunk = remaining[i:i + MAX_SESSION_CHUNK]
                    places = ','.join('?' * len(chunk))
                    rows = state_db.execute(
                        f'SELECT id,input_tokens,output_tokens FROM sessions '
                        f'WHERE id IN ({places})', chunk).fetchall()
                    for session_id, in_tokens, out_tokens in rows:
                        usage[session_id] = (in_tokens or 0, out_tokens or 0)
    except (sqlite3.Error, OSError):
        return None
    matched = sum(1 for session_id in session_ids if session_id in usage)
    coverage = round(matched / len(session_ids), 2) if session_ids else None
    completed = {row[0] for row in db.execute(
        '''SELECT DISTINCT task_id FROM task_events
           WHERE kind='completed' AND created_at>=? AND created_at<?''',
        (since, until)).fetchall()}
    cards_backed = sum(1 for card in completed
                       if any(session_id in usage
                              for session_id in session_of_card.get(card, [])))
    tokens_in = tokens_out = 0
    if cards_backed:
        for card in completed:
            for session_id in session_of_card.get(card, []):
                if session_id in usage:
                    tokens_in += usage[session_id][0]
                    tokens_out += usage[session_id][1]
    return {'runs_with_session_id': present,
            'matched_sessions': matched,
            'session_coverage': coverage,
            'completed_cards_with_matched_tokens': cards_backed,
            'tokens_per_completed_card': (
                {'input': round(tokens_in / cards_backed),
                 'output': round(tokens_out / cards_backed)}
                if cards_backed and coverage is not None and coverage >= 0.5 else None),
            'note': 'matched worker-session tokens attributed per card; estimate'}


def maintenance_outcomes(db, since, until):
    """Bounded native facts; worker elapsed time is not cost or owner time saved."""
    rows=db.execute("SELECT t.id,t.tenant,t.created_by,r.started_at,r.ended_at,r.outcome,r.metadata "
                    "FROM task_runs r JOIN tasks t ON t.id=r.task_id "
                    "WHERE r.ended_at>=? AND r.ended_at<? LIMIT 10001",(since,until)).fetchall()
    if len(rows)>10000:
        return {'status':'truncated'}
    completed=0;maintenance=0;elapsed=0;deliveries=set();invalid=0
    for tid,tenant,creator,started,ended,outcome,raw in rows:
        is_maintenance=(tenant in {'technical-recovery','continuous-improvement'}
                        or creator in {'fleet-supervisor','deadlock-recovery-monitor','aging-escalation','cron-loop-monitor'})
        if outcome=='completed':
            completed+=1
            maintenance+=int(is_maintenance)
        if is_maintenance and isinstance(started,(int,float)) and isinstance(ended,(int,float)):
            elapsed+=max(0,ended-started)
        try:
            metadata=json.loads(raw or '{}')
            delivery=metadata.get('feature_delivery',{})
            if (outcome=='completed' and isinstance(delivery,dict) and delivery.get('state')=='delivered_scope'
                    and isinstance(delivery.get('tracker'),str) and isinstance(delivery.get('evidence_version'),str)):
                deliveries.add((delivery['tracker'],delivery.get('scope'),delivery.get('revision',delivery['evidence_version'])))
        except (ValueError,TypeError,AttributeError):
            invalid+=1
    unfinished=db.execute("SELECT COUNT(*) FROM tasks WHERE title LIKE '[FEATURE TRACKER%' "
                          "AND status NOT IN ('done','archived')").fetchone()[0]
    repeats=db.execute("SELECT COUNT(*) FROM task_events WHERE kind='blocked' AND created_at>=? AND created_at<? "
                       "GROUP BY task_id HAVING COUNT(*)>1 LIMIT 10001",(since,until)).fetchall()
    if len(repeats)>10000:
        return {'status':'truncated'}
    return dict(status='observed',window_seconds=until-since,completed_runs=completed,
                maintenance_completed_runs=maintenance,maintenance_elapsed_seconds=round(elapsed),
                recorded_scope_deliveries=len(deliveries),unfinished_feature_trackers=unfinished,
                repeat_blocked_tasks=len(repeats),repeat_block_events=sum(r[0]-1 for r in repeats),
                malformed_run_metadata=invalid,
                note='Recorded delivery scopes are not live acceptance; summed worker elapsed includes waits and parallel work. Billing unknown.')


def board_report(db_path, review_dir, home, since, until, now):
    with readonly(db_path) as db:
        per_task, truncated = load_events(db, until)
        if truncated:
            return {'truncated': True}
        statuses = load_statuses(db)
        life = lifecycle(per_task, statuses, since, until, now)
        return {
            'lifecycle': life,
            'dependencies': dependency_waits(per_task, until, now),
            'rework': rework(db, since, until),
            'reblocks': reblocks(db, since, until),
            'review': review_loop(db, since, until, review_dir),
            'escalation': escalation(db, per_task, since, until,
                                     (life['claim_wait_days'] or {}).get('p50')),
            'token_effort': token_effort(db, home, since, until),
            'maintenance': maintenance_outcomes(db,since,until),
        }


def snapshot_path(root):
    return root / 'state' / 'analytics' / 'snapshots.jsonl'


def append_snapshot(root, entry, keep=SNAPSHOT_KEEP):
    """Append one line under bounded retention; atomic rewrite, 0600.

    Duplicate guard: the newest entry with the same window and identical
    board payload is skipped, so a cron double-tick cannot double-count.
    """
    path = snapshot_path(root)
    path.parent.mkdir(parents=True, exist_ok=True)
    os.chmod(path.parent, 0o700)
    entries = []
    try:
        entries = [line for line in path.read_text().splitlines() if line.strip()]
    except (OSError, UnicodeError):
        entries = []
    encoded = json.dumps(entry, sort_keys=True)
    if entries:
        try:
            last = json.loads(entries[-1])
        except json.JSONDecodeError:
            last = {}
        window_matches = all(
            isinstance(last.get(key), (int, float)) and
            isinstance(entry.get(key), (int, float)) and
            abs(last[key] - entry[key]) <= 300
            for key in ('since', 'until'))
        boards_match = (isinstance(last.get('boards'), dict)
                        and isinstance(entry.get('boards'), dict)
                        and json.dumps(last['boards'], sort_keys=True)
                        == json.dumps(entry['boards'], sort_keys=True))
        if window_matches and boards_match:
            return False
    entries.append(encoded)
    entries = entries[-keep:]
    fd, temporary = tempfile.mkstemp(dir=str(path.parent), prefix='.snapshots.')
    with os.fdopen(fd, 'w') as stream:
        stream.write('\n'.join(entries) + '\n')
        stream.flush()
        os.fsync(stream.fileno())
    os.chmod(temporary, 0o600)
    os.replace(temporary, path)
    return True


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
    """Movement between the two snapshots. Only same-schema snapshots are
    compared: earlier versions carried different cohort definitions."""
    def head_of(snapshot):
        if not snapshot or snapshot.get('schema_version') != SNAPSHOT_SCHEMA_VERSION:
            return None
        evidence = evidence_from(snapshot)
        return evidence.get('nixhomeserver') or next(iter(evidence.values()), None)
    current_head, before_head = head_of(current), head_of(before)
    if not before_head or not current_head:
        return 'no comparable prior snapshot'
    deltas = []
    for key in ('lead_p95_days', 'claim_wait_p95_days'):
        a, b = current_head.get(key), before_head.get(key)
        if a is not None and b is not None:
            drop = f' ({round(a - b, 2)}d)' if a != b else ''
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
        if board.get('truncated'):
            lines.append(f'[{slug}] event volume exceeds read bounds; results omitted')
            continue
        lines.append(f'[{slug}]')
        lifecycle = board['lifecycle']
        claim, lead = lifecycle['claim_wait_days'], lifecycle['lead_time_days']
        lines.append(
            f"  flow: claim-wait-d p50/p95={claim['p50']}/{claim['p95']}"
            f" lead-time-d p50/p95={lead['p50']}/{lead['p95']}"
            f" completed={lifecycle['completed_cards']}"
            f" (cohort: {lifecycle['created_in_window']} created in window)"
            " (aging thresholds 48h/72h should match these, not constants)")
        statuses = ' '.join(
            f"{status}={value['count']}"
            + ('[' + ','.join(f'{k}:{v}' for k, v in sorted(value['block_kinds'].items()))
               + ']' if value.get('block_kinds') else '')
            for status, value in sorted(lifecycle['open_cards_by_status'].items()))
        lines.append('  open cards: ' + (statuses or 'none'))
        deps = board['dependencies']
        lines.append('  dependencies: cards=' + str(deps['cards_with_dependency_waits'])
                     + ' resolved-wait-d p50/p95=' + str(deps['resolved_wait_days']['p50'])
                     + '/' + str(deps['resolved_wait_days']['p95'])
                     + ' still-open=' + str(deps['open_waits_still_blocked'])
                     + ' unattributed=' + str(deps['unattributed_waits'])
                     + ' chronic=' + json.dumps(deps['chronic_parents'],
                                                sort_keys=True, separators=(',', ':')))
        rework_stats = board['rework']
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
        lines.append('  review: verdicts='
                     + json.dumps(review['verdicts'], sort_keys=True, separators=(',', ':'))
                     + ' repair-rate=' + str(review['repair_rate'])
                     + ' audit=' + json.dumps(review['audit_findings'],
                                              sort_keys=True, separators=(',', ':'))
                     + ' sweeps=' + json.dumps(review['sweeps'],
                                               sort_keys=True, separators=(',', ':')))
        esc = board['escalation']
        lines.append('  escalation: markers=' + str(esc['escalation_markers'])
                     + ' gated=' + str(esc['markers_on_currently_gated_cards'])
                     + ' released=' + str(esc['markers_released'])
                     + ' release-rate=' + str(esc['release_rate'])
                     + ' excl-gated=' + str(esc['release_rate_excluding_currently_gated'])
                     + ' first-action-h p50/p95=' + str(esc['first_action_hours']['p50'])
                     + '/' + str(esc['first_action_hours']['p95'])
                     + ' claim-wait-p50-ref=' + str(esc['claim_wait_p50_days_reference']))
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
               if entry.get('schema_version') == SNAPSHOT_SCHEMA_VERSION
               and isinstance(entry.get('until'), (int, float))
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
        appended = append_snapshot(root, {'at': int(time.time()),
                                          'schema_version': SNAPSHOT_SCHEMA_VERSION,
                                          'since': since, 'until': until,
                                          'boards': data['boards']})
        if appended:
            print('snapshot appended to ' + str(snapshot_path(root)))
        else:
            print('snapshot identical to latest; skipped')
    if args.json:
        print(json.dumps(data, sort_keys=True))
    else:
        print(render(data))


if __name__ == '__main__':
    main(None)
