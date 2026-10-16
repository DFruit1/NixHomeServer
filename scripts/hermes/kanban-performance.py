#!/usr/bin/env python3
"""Read local Hermes performance counters without native APIs or new telemetry.

Python operations glue reuses stdlib SQLite; no backend, credentials or network.
Session/run cohorts START in [since, until); counters are their lifetime totals
as observed now. Card completions are events in that window, not feature delivery.
"""
import argparse
from collections import Counter, defaultdict
from contextlib import contextmanager
import datetime as dt
import hashlib
import json
import math
import os
from pathlib import Path
import re
import sqlite3
import time

FAILURE_CATEGORIES = {'provider_unavailable', 'provider_auth', 'provider_quota',
                      'provider_request', 'timeout', 'worker_crash', 'spawn_failure',
                      'tool_denied', 'validation_failed', 'workspace_failure', 'retry_exhausted'}
RUN_VALUES = {'running', 'done', 'completed', 'blocked', 'crashed', 'timed_out',
              'failed', 'released', 'spawn_failed', 'gave_up', 'reclaimed'}
MAX_MODEL_ROWS, MAX_MODEL_GROUPS, MAX_SESSION_IDS = 20000, 256, 100000


def model_usage(db, since, until):
    """Native per-model cohort counters include auxiliary calls; never add to sessions totals."""
    try:
        rows = db.execute('''SELECT u.model,u.billing_provider,
            CASE WHEN u.task='' THEN 'main'
                 WHEN u.task IN ('main','chat','background_review','skill_curator','auxiliary',
                                'vision','compression','title_generation')
                 THEN u.task ELSE 'other' END,
            u.api_call_count,u.input_tokens,u.output_tokens,u.cache_read_tokens,
            u.cache_write_tokens,u.reasoning_tokens,u.estimated_cost_usd,u.actual_cost_usd,u.cost_status
            FROM session_model_usage u JOIN sessions s ON s.id=u.session_id
            WHERE s.started_at>=? AND s.started_at<? LIMIT ?''', (since,until,MAX_MODEL_ROWS+1)).fetchall()
    except sqlite3.OperationalError:
        return None
    if len(rows)>MAX_MODEL_ROWS:
        return None
    counters = ('api_call_count','input_tokens','output_tokens','cache_read_tokens',
                'cache_write_tokens','reasoning_tokens')
    totals = Counter()
    groups = defaultdict(Counter)
    estimate_rows = actual_rows = 0
    estimate = actual = 0.0
    cost_statuses = Counter()
    label = lambda value: value if (isinstance(value,str) and '://' not in value
        and re.fullmatch(r'[A-Za-z0-9_./:-]{1,120}',value)) else 'unknown'
    for model,provider,kind,*values in rows:
        for key,value in zip(counters,values[:6]):
            if value is not None and (not isinstance(value,(int,float)) or not math.isfinite(value) or value<0):
                return None
            totals[key] += value or 0
            groups[(label(model),label(provider),kind)][key] += value or 0
        if len(groups)>MAX_MODEL_GROUPS:
            return None
        status = values[8] if values[8] in {'actual','estimated','included','unknown'} else 'unknown'
        cost_statuses[status]+=1
        for index in (6,7):
            value = values[index]
            # Native storage defaults missing costs to zero. A positive
            # accumulated value or the matching explicit latest status is
            # evidence; zero alone is not. Status is not per-call coverage.
            if (isinstance(value,(int,float)) and math.isfinite(value) and value>=0
                    and (value>0 or status==('estimated' if index==6 else 'actual'))):
                if index==6:
                    estimate_rows+=1; estimate+=value
                else:
                    actual_rows+=1; actual+=value
    return {**{k:totals[k] for k in counters}, 'rows':len(rows),
            'estimated_cost_rows':estimate_rows, 'actual_cost_rows':actual_rows,
            'cost_status_rows':dict(cost_statuses),
            'estimated_cost_usd':estimate if estimate_rows else None,
            'actual_cost_usd':actual if actual_rows else None,
            'by_model':[{'model':m,'provider':p,'task':t,**dict(v)}
                        for (m,p,t),v in sorted(groups.items())]}


def stored_session_ids(db):
    if 'id' not in {r[1] for r in db.execute('PRAGMA table_info(sessions)')}:
        return None
    rows = db.execute('SELECT id FROM sessions LIMIT ?', (MAX_SESSION_IDS+1,)).fetchall()
    return {r[0] for r in rows} if len(rows)<=MAX_SESSION_IDS else None


@contextmanager
def readonly(path):
    db = sqlite3.connect(path.resolve().as_uri() + '?mode=ro', uri=True, timeout=2)
    try:
        db.execute('PRAGMA query_only=ON')
        deadline = time.monotonic() + 8
        db.set_progress_handler(lambda: int(time.monotonic() > deadline), 10000)
        db.execute('BEGIN')
        yield db
    finally:
        db.close()


def distribution(values):
    values = sorted(values)
    return {'n': len(values), **{name: values[math.ceil(len(values)*q)-1] if values else None
                                for name, q in [('p50', .5), ('p95', .95)]}}


def session_stats(db, since, until):
    fields = ('input_tokens', 'output_tokens', 'cache_read_tokens', 'cache_write_tokens',
              'api_call_count', 'tool_call_count')
    rows = db.execute('SELECT ' + ','.join(fields) + ', length(CAST(system_prompt AS BLOB)) '
                      'FROM sessions WHERE started_at>=? AND started_at<?', (since, until)).fetchall()
    result = {'count': len(rows), 'usage_reported_sessions': sum(any((v or 0)>0 for v in r[:5]) for r in rows)}
    result.update({field: sum(r[i] or 0 for r in rows) for i, field in enumerate(fields)})
    result['persisted_prompt_bytes'] = distribution([r[-1] for r in rows if r[-1] is not None])
    # Long-lived Bot Chat sessions may predate the cohort. Keep a separate
    # cumulative view for baselines; never label it as spending in the window.
    totals = db.execute('SELECT count(*),' + ','.join(f'sum({field})' for field in fields) + ' FROM sessions').fetchone()
    result['all_stored_sessions'] = {'count': totals[0], **dict(zip(fields, totals[1:]))}
    result['model_usage'] = model_usage(db,since,until)
    return result


def run_stats(rows, until, known_sessions=None):
    attempts = Counter((r[0], r[1]) for r in rows)  # board/task identities never leave this process.
    failures = {'failed', 'crashed', 'timed_out', 'spawn_failed', 'gave_up'}
    failed = [r for r in rows if r[4] in failures or r[5] in failures]
    causes = Counter()
    fallback = {'crashed':'worker_crash','timed_out':'timeout','spawn_failed':'spawn_failure','gave_up':'retry_exhausted'}
    for r in failed:
        causes[r[8] if r[8] in FAILURE_CATEGORIES else fallback.get(r[5],fallback.get(r[4],'unknown'))]+=1
    return {
        'count': len(rows), 'tasks': len(attempts),
        'repeat_attempt_tasks': sum(n>1 for n in attempts.values()),
        'repeat_attempts': sum(n-1 for n in attempts.values()),
        'failures': len(failed), 'failure_causes':dict(causes),
        'reported_failure_category_runs':sum(r[8] in FAILURE_CATEGORIES for r in failed),
        'statuses':dict(Counter(r[4] if r[4] in RUN_VALUES else 'unknown' for r in rows)),
        'outcomes':dict(Counter(r[5] if r[5] in RUN_VALUES else 'unknown' for r in rows)),
        'unfinished_at_window_end': sum(r[3] is None or r[3]>=until for r in rows),
        'worker_session_id_present': sum(bool(r[6]) for r in rows),
        'worker_session_id_matched': None if known_sessions is None else sum(r[6] in known_sessions for r in rows if r[6]),
        'reported_verdicts': dict(Counter(r[7] for r in rows if r[7] in {'accept', 'request-changes'})),
        'elapsed_seconds': distribution([r[3]-r[2] for r in rows
                                         if r[3] is not None and r[2]<=r[3]<until]),
    }


def report(root, since, until):
    collection_started = time.monotonic()
    if not all(math.isfinite(v) for v in (since, until)) or since>=until:
        raise ValueError('Expected a finite increasing window')
    profiles, boards, warnings, seen, session_ids = {}, {}, [], set(), {}

    def read(path, label, callback):
        try:
            identity = (path.stat().st_dev, path.stat().st_ino)
            if identity in seen:
                warnings.append({'source': label, 'reason': 'shared_database'})
                return None
            seen.add(identity)
            with readonly(path) as db:
                return callback(db)
        except (OSError, sqlite3.Error, ValueError, TypeError):
            warnings.append({'source': label, 'reason': 'missing_unreadable_or_unsupported'})
            return None

    homes = [('default', root)]
    if (root/'profiles').exists():
        homes.extend((p.name, p) for p in sorted((root/'profiles').iterdir())
                     if p.is_dir() and not p.name.startswith('.'))
    for name, home in homes:
        if name == 'default' and not (home/'SOUL.md').exists() and not (home/'state.db').exists():
            continue
        if name != 'default' and not (home/'SOUL.md').exists():
            continue
        standing = None
        try:
            content = (home/'SOUL.md').read_bytes()
            standing = {'bytes': len(content), 'words': len(content.decode().split()),
                        'sha256': hashlib.sha256(content).hexdigest()}
        except (OSError, UnicodeError):
            warnings.append({'source': 'role:'+name, 'reason': 'missing_unreadable_or_unsupported'})
        snapshot = read(home/'state.db', 'sessions:'+name,
                        lambda db:(session_stats(db,since,until),stored_session_ids(db)))
        session_ids[name] = snapshot[1] if snapshot else None
        profiles[name] = {'standing_prompt': standing,'sessions':snapshot[0] if snapshot else None,'runs':None}

    runs_by_profile = defaultdict(list)
    paths = set((root/'kanban/boards').glob('*/kanban.db'))
    paths.update(p.with_name('kanban.db') for p in (root/'kanban/boards').glob('*/board.json'))
    if not paths:
        warnings.append({'source': 'boards', 'reason': 'no_active_sources'})
    for path in sorted(paths):
        slug = path.parent.name
        if slug.startswith(('_', '.')):
            continue

        def board_stats(db):
            runs = db.execute('''SELECT task_id,profile,started_at,ended_at,status,outcome,
                CASE WHEN json_valid(metadata) AND json_type(metadata,'$.worker_session_id')='text'
                     THEN json_extract(metadata,'$.worker_session_id') END,
                CASE WHEN json_valid(metadata) THEN json_extract(metadata,'$.verdict') END,
                CASE WHEN json_valid(metadata) THEN json_extract(metadata,'$.failure_category') END
                FROM task_runs WHERE started_at>=? AND started_at<?''', (since, until)).fetchall()
            events = dict(db.execute('''SELECT kind,count(*) FROM task_events
                WHERE created_at>=? AND created_at<? AND kind IN
                ('completed','claimed','assigned','changes_requested','blocked','dependency_wait',
                 'rate_limited','timed_out','crashed','spawn_failed','gave_up','review_requested',
                 'respawn_guarded','block_loop_detected') GROUP BY kind''', (since, until)))
            completed = db.execute("SELECT count(DISTINCT task_id) FROM task_events WHERE kind='completed' "
                                   'AND created_at>=? AND created_at<?', (since, until)).fetchone()[0]
            return runs, {'completed_cards': completed, 'events': events}

        result = read(path, 'board:'+slug, board_stats)
        if result is None:
            continue
        runs, boards[slug] = result
        for task, profile, *values in runs:
            # Attribution is by recorded run profile, not the card's current assignee.
            runs_by_profile[profile or 'unknown'].append((slug, task, *values))
    if boards:
        for name in sorted(set(profiles) | set(runs_by_profile)):
            profile = profiles.setdefault(name, {'standing_prompt': None, 'sessions': None})
            profile['runs'] = run_stats(runs_by_profile[name], until,session_ids.get(name))
    return {'schema_version': 2, 'generated_at': time.time(), 'since': since, 'until': until,
            'collection_seconds': time.monotonic()-collection_started,
            'profiles': profiles, 'boards': boards, 'warnings': warnings}


def render(data):
    stamp = lambda value: dt.datetime.fromtimestamp(value, dt.timezone.utc).isoformat(timespec='seconds')
    lines = [f"HERMES PERFORMANCE {stamp(data['since'])} .. {stamp(data['until'])} (start cohorts; lifetime counters)"]
    for name, profile in sorted(data['profiles'].items()):
        sessions, runs = profile['sessions'], profile['runs']
        usage = ('usage unknown' if sessions is None else
                 f"sessions={sessions['count']} usage={sessions['usage_reported_sessions']}/{sessions['count']} "
                 f"input/output={sessions['input_tokens']}/{sessions['output_tokens']} api={sessions['api_call_count']}")
        work = ('runs unknown' if runs is None else
                f"runs={runs['count']} failed={runs['failures']} repeat-cards={runs['repeat_attempt_tasks']} "
                f"run-seconds p50/p95={runs['elapsed_seconds']['p50']}/{runs['elapsed_seconds']['p95']} "
                f"session-links={runs['worker_session_id_matched']}/{runs['worker_session_id_present']} "
                f"failure-causes={json.dumps(runs['failure_causes'],sort_keys=True,separators=(',',':'))}")
        lines.append(f'@{name}: {usage}; {work}')
    completions = sum(b['completed_cards'] for b in data['boards'].values()) if data['boards'] else 'unknown'
    lines.append('Card completions (not features; readable boards only): ' + str(completions))
    if data['warnings']:
        lines.append(f"Coverage warnings: {len(data['warnings'])}; inspect --json before drawing conclusions.")
    return '\n'.join(lines)


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
    parser.add_argument('--days', type=float, default=1)
    parser.add_argument('--since', type=instant)
    parser.add_argument('--until', type=instant)
    parser.add_argument('--json', action='store_true')
    args = parser.parse_args(argv)
    until = args.until if args.until is not None else time.time()
    since = args.since if args.since is not None else until-args.days*86400
    if not math.isfinite(since) or not math.isfinite(until) or not 0<until-since<=90*86400:
        parser.error('Use an increasing window of at most 90 days')
    data = report(Path(os.environ.get('HERMES_ROOT', str(Path.home()/'.hermes'))), since, until)
    print(json.dumps(data, sort_keys=True) if args.json else render(data))


if __name__ == '__main__':
    main(None)
