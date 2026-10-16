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
import sqlite3
import time


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
    return result


def run_stats(rows, until):
    attempts = Counter((r[0], r[1]) for r in rows)  # board/task identities never leave this process.
    failures = {'failed', 'crashed', 'timed_out', 'spawn_failed', 'gave_up'}
    return {
        'count': len(rows), 'tasks': len(attempts),
        'repeat_attempt_tasks': sum(n>1 for n in attempts.values()),
        'failures': sum(r[4] in failures or r[5] in failures for r in rows),
        'unfinished_at_window_end': sum(r[3] is None or r[3]>=until for r in rows),
        'worker_session_id_present': sum(bool(r[6]) for r in rows),
        'reported_verdicts': dict(Counter(r[7] for r in rows if r[7] in {'accept', 'request-changes'})),
        'elapsed_seconds': distribution([r[3]-r[2] for r in rows
                                         if r[3] is not None and r[2]<=r[3]<until]),
    }


def report(root, since, until):
    collection_started = time.monotonic()
    if not all(math.isfinite(v) for v in (since, until)) or since>=until:
        raise ValueError('Expected a finite increasing window')
    profiles, boards, warnings, seen = {}, {}, [], set()

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
        profiles[name] = {'standing_prompt': standing,
                          'sessions': read(home/'state.db', 'sessions:'+name,
                                           lambda db: session_stats(db, since, until)), 'runs': None}

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
                CASE WHEN json_valid(metadata) THEN json_extract(metadata,'$.worker_session_id') IS NOT NULL ELSE 0 END,
                CASE WHEN json_valid(metadata) THEN json_extract(metadata,'$.verdict') END
                FROM task_runs WHERE started_at>=? AND started_at<?''', (since, until)).fetchall()
            events = dict(db.execute('''SELECT kind,count(*) FROM task_events
                WHERE created_at>=? AND created_at<? AND kind IN
                ('completed','claimed','assigned','changes_requested','blocked','dependency_wait',
                 'rate_limited','timed_out','crashed') GROUP BY kind''', (since, until)))
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
            profile['runs'] = run_stats(runs_by_profile[name], until)
    return {'schema_version': 1, 'generated_at': time.time(), 'since': since, 'until': until,
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
                f"run-seconds p50/p95={runs['elapsed_seconds']['p50']}/{runs['elapsed_seconds']['p95']}")
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
