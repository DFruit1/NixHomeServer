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
import shlex
import sqlite3
import time
from itertools import islice

from agent_usage_report import read_summary

FAILURE_CATEGORIES = {'provider_unavailable', 'provider_auth', 'provider_quota',
                      'provider_request', 'timeout', 'worker_crash', 'spawn_failure',
                      'tool_denied', 'validation_failed', 'workspace_failure', 'retry_exhausted'}
RUN_VALUES = {'running', 'done', 'completed', 'blocked', 'crashed', 'timed_out',
              'failed', 'released', 'spawn_failed', 'gave_up', 'reclaimed'}
MAX_MODEL_ROWS, MAX_MODEL_GROUPS, MAX_SESSION_IDS = 20000, 256, 100000


def cron_health(root,name):
    path=root/'scripts/hermes-cron-policy.json'
    if not path.exists():return None
    try:
        entries=json.loads(path.read_text())['jobs']
        jobs=[key for key,value in entries.items() if value['profile']==name]
        if not jobs:return None
        observed=pending=exhausted=errors=0
        report_chars={}
        for key,value in entries.items():
            if value['profile']!=name:continue
            if not re.fullmatch(r'[a-f0-9]+',key):raise ValueError('Invalid journal key')
            journal=root/'state/cron-policy'/(key+'.json')
            if not journal.exists():continue
            state=json.loads(journal.read_text());observed+=1
            pending+=bool(state.get('pending') or state.get('stall_pending'))
            exhausted+=bool(state.get('budget_exhausted'));errors+=bool(state.get('collection_error'))
            if value.get('kind') in ('daily','stall'):
                latest=int(state.get('last_chars') or 0)
                if latest:report_chars[value['kind']]=max(report_chars.get(value['kind'],0),latest)
        return {'status':'attention' if pending or exhausted or errors else 'ok' if observed==len(jobs) else 'unobserved',
                'jobs':len(jobs),'observed':observed,'pending':pending,'budget_stops':exhausted,'collection_errors':errors,
                'chars':report_chars or None}
    except (ValueError,OSError,KeyError,TypeError):return {'status':'unknown'}


def owner_alert_limit_checks(root):
    """Fleet counter for owner-summary/gate length validations (owned by
    kanban-owner-alerts's note_limit_check). Totals only; never message text.
    Unknown stays None, never zero."""
    path = root / 'state' / 'owner-alerts' / 'limit-checks.json'
    if not path.exists():
        return None
    try:
        state = json.loads(path.read_text())
    except (ValueError, OSError):
        return None
    total = state.get('total')
    rejections = state.get('rejections')
    return {'checks': total if isinstance(total, int) and total >= 0 else None,
            'rejections': rejections if isinstance(rejections, dict) else None,
            'latest': state.get('latest') if isinstance(state.get('latest'), dict) else None}


def memory_health(home):
    """Bounded current-state counters, never memory/config/proposal contents.

    Unknown is explicit. Capacity and queue age trigger investigation, never
    automatic deletion; file age does not establish that a fact is invalid.
    YAML is optional so older/minimal report environments still collect usage.
    """
    def small(path):
        if path.is_symlink() or path.stat().st_size>65536:
            raise ValueError('Unsupported input')
        with path.open() as stream:
            value=stream.read(65537)
        if len(value)>65536:raise ValueError('Unsupported input')
        return value

    try:
        try:
            from hermes_yaml import safe_load
        except ImportError:
            from yaml import safe_load
        config=safe_load(small(home/'config.yaml'))
        memory=config.get('memory',{})
        if not isinstance(memory,dict):raise ValueError('Unsupported memory configuration')
        stores={}
        for target,filename,flag,key,default in (
                ('memory','MEMORY.md','memory_enabled','memory_char_limit',2200),
                ('user','USER.md','user_profile_enabled','user_char_limit',1375)):
            limit=memory.get(key,default);enabled=memory.get(flag,True)
            if type(limit) is not int or limit<=0 or type(enabled) is not bool:
                raise ValueError('Unsupported memory configuration')
            path=home/'memories'/filename
            text=small(path).strip() if path.exists() else ''
            entries=text.split('\n§\n') if text else []
            normalized=[' '.join(re.findall(r'\w+',entry.casefold())) for entry in entries]
            stores[target]={'enabled':enabled,'chars':len(text),'limit':limit,'entries':len(entries),
                'normalized_duplicates':len(entries)-len(set(normalized)),
                'capacity_pressure':enabled and len(text)>=limit*.8}
        directory=home/'pending/memory'
        paths=list(islice(directory.glob('*.json'),257))
        if len(paths)>256:raise ValueError('Queue exceeds inspection bound')
        ages=[max(0,(time.time()-p.stat().st_mtime)/86400) for p in paths if not p.is_symlink()]
        if len(ages)!=len(paths):raise ValueError('Unsupported queue input')
        pending={'count':len(paths),'older_than_seven_days':sum(age>=7 for age in ages),
                 'oldest_days':round(max(ages),1) if ages else None}
        root=home.parent.parent if home.parent.name=='profiles' else home
        command=shlex.join(['python3',str(root/'scripts/memory-policy.py')])
        guard_present=(root/'scripts/memory-policy.py').is_file() and any(
            isinstance(h,dict) and h.get('command')==command and h.get('fail_closed') is True
            and h.get('matcher')=='^(memory|skill_manage)$'
            for h in config.get('hooks',{}).get('pre_tool_call',[]))
        event_driven=memory.get('nudge_interval')==0 and config.get('skills',{}).get('creation_nudge_interval')==0
        attention=(not guard_present or not event_driven or pending['older_than_seven_days']
                   or any(s['capacity_pressure'] or s['normalized_duplicates'] for s in stores.values()))
        return {'status':'attention' if attention else 'ok','stores':stores,'pending':pending,
                'guard_present':guard_present,'event_driven':event_driven}
    except Exception:
        # Parser exceptions can contain sensitive snippets. Keep the existing
        # performance report usable and expose no raw exception or input text.
        return {'status':'unknown','stores':None,'pending':None}


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
    rows = db.execute('SELECT ' + ','.join(fields) +
                      ' FROM sessions WHERE started_at>=? AND started_at<?', (since, until)).fetchall()
    result = {'count': len(rows), 'usage_reported_sessions': sum(any((v or 0)>0 for v in r[:5]) for r in rows)}
    result.update({field: sum(r[i] or 0 for r in rows) for i, field in enumerate(fields)})
    # Persisted system-prompt bytes were retired: the native sessions table
    # carries the column but no write path populates it, and a permanently
    # null distribution in a self-audit report trains readers to skim.
    # Reinstate only if the runtime begins persisting prompts.
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
        cause = r[8] if r[8] in FAILURE_CATEGORIES else (
            'provider_terminal' if r[9] else fallback.get(r[5],fallback.get(r[4],'unknown')))
        causes[cause]+=1
    return {
        'count': len(rows), 'tasks': len(attempts),
        'repeat_attempt_tasks': sum(n>1 for n in attempts.values()),
        'repeat_attempts': sum(n-1 for n in attempts.values()),
        'failures': len(failed), 'failure_causes':dict(causes),
        'reported_failure_category_runs':sum(r[8] in FAILURE_CATEGORIES for r in failed),
        'terminal_provider_runs':sum(bool(r[9]) for r in failed),
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
        profiles[name] = {'standing_prompt': standing,'sessions':snapshot[0] if snapshot else None,'runs':None,
                          'memory':memory_health(home),'scheduled_inspections':cron_health(root,name)}

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
                CASE WHEN json_valid(metadata) THEN json_extract(metadata,'$.failure_category') END,
                CASE WHEN json_valid(metadata) THEN
                    json_type(metadata,'$.terminal_provider')='true'
                    AND json_extract(metadata,'$.exit_kind')='terminal_provider'
                    ELSE 0 END
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
    # Fleet-level, but mentally owned by head-coordinator: it is the sole author
    # of owner-facing blocker summaries and gates, and the guard checks its writes.
    profiles.setdefault('head-coordinator', {'standing_prompt': None, 'sessions': None})[
        'owner_alert_limit_checks'] = owner_alert_limit_checks(root)
    return {'schema_version': 3, 'generated_at': time.time(), 'since': since, 'until': until,
            'collection_seconds': time.monotonic()-collection_started,
            'profiles': profiles, 'boards': boards, 'warnings': warnings,
            'agent_usage':read_summary(root/'state/agent-usage/summary.json')}


def profile_lines(name, profile, digest=False):
    sessions, runs = profile['sessions'], profile['runs']
    usage = ('usage unknown' if sessions is None else
             f"sessions={sessions['count']} usage={sessions['usage_reported_sessions']}/{sessions['count']} "
             f"input/output={sessions['input_tokens']}/{sessions['output_tokens']} api={sessions['api_call_count']}")
    work = ('runs unknown' if runs is None else
            f"runs={runs['count']} failed={runs['failures']} repeat-cards={runs['repeat_attempt_tasks']} "
            f"run-seconds p50/p95={runs['elapsed_seconds']['p50']}/{runs['elapsed_seconds']['p95']} "
            f"session-links={runs['worker_session_id_matched']}/{runs['worker_session_id_present']} "
            f"failure-causes={json.dumps(runs['failure_causes'],sort_keys=True,separators=(',',':'))}")
    lines = [f'@{name}: {usage}; {work}']
    if (cron:=profile.get('scheduled_inspections')) is not None:
        if not digest or cron.get('status') != 'ok':
            lines.append('  scheduled-inspections='+json.dumps(cron,sort_keys=True,separators=(',',':')))
    if (memory:=profile.get('memory')) is not None:
        if digest and memory.get('status') == 'ok' and not (memory.get('pending') or {}).get('older_than_seven_days'):
            return lines
        stores=memory.get('stores') or {}
        counts=' '.join(f"{key}={store['chars']}/{store['limit']}" for key,store in stores.items() if store['enabled'])
        pending=memory.get('pending') or {}
        lines.append(f"  learning={memory['status']} {counts} pending={pending.get('count','unknown')} "
                     f"pending-over-7d={pending.get('older_than_seven_days','unknown')} "
                     f"guard={memory.get('guard_present','unknown')} event-driven={memory.get('event_driven','unknown')}")
    return lines


def digest_attention(profile):
    """True when a profile carries something the owner may need to act on."""
    runs = profile.get('runs') or {}
    cron = profile.get('scheduled_inspections') or {}
    memory = profile.get('memory') or {}
    pending = memory.get('pending') or {}
    blocks = profile.get('owner_alert_limit_checks') or {}
    rejected = blocks.get('rejections') or {}
    return bool(runs.get('failures')
                or cron.get('status') == 'attention'
                or memory.get('status') == 'attention'
                or pending.get('older_than_seven_days')
                or any(int(v or 0) > 0 for v in rejected.values()))


def render_digest(data):
    """One fleet line plus only profiles with failures or attention."""
    stamp = lambda value: dt.datetime.fromtimestamp(value, dt.timezone.utc).isoformat(timespec='seconds')
    profiles = data['profiles']
    lines = [f"HERMES PERFORMANCE {stamp(data['since'])} .. {stamp(data['until'])} (digest)"]
    session_counts = [p['sessions']['count'] for p in profiles.values() if p.get('sessions') is not None]
    unknown_sessions = sum(p.get('sessions') is None for p in profiles.values())
    failures = sum((p.get('runs') or {}).get('failures', 0) for p in profiles.values())
    repeats = sum((p.get('runs') or {}).get('repeat_attempt_tasks', 0) for p in profiles.values())
    budget_stops = sum((p.get('scheduled_inspections') or {}).get('budget_stops', 0)
                       for p in profiles.values())
    learning = [p.get('memory') for p in profiles.values() if p.get('memory')]
    memory_status = ('attention' if any(m.get('status') == 'attention' for m in learning)
                     else 'unknown' if any(m.get('status') == 'unknown' for m in learning)
                     else 'ok')
    lines.append(f"fleet: sessions={sum(session_counts)}"
                 + (f"+{unknown_sessions} unknown" if unknown_sessions else '')
                 + f" failed={failures} repeat-cards={repeats}"
                 f" budget-stops={budget_stops} learning={memory_status}")
    if data.get('agent_usage',{}).get('status')!='unavailable':
        lines.append('Langfuse usage='+data.get('agent_usage',{}).get('status','unknown')
                     +'; inspect agent-usage.py --report for native client/engine coverage.')
    attention = [(name, profile) for name, profile in sorted(profiles.items())
                 if digest_attention(profile)]
    for name, profile in attention:
        lines.extend(profile_lines(name, profile, digest=True))
    if not attention:
        lines.append('profiles=ok')
    if data['warnings']:
        lines.append(f"Coverage warnings: {len(data['warnings'])}; inspect --json before drawing conclusions.")
    return '\n'.join(lines)


def render(data, digest=False):
    if digest:
        return render_digest(data)
    stamp = lambda value: dt.datetime.fromtimestamp(value, dt.timezone.utc).isoformat(timespec='seconds')
    lines = [f"HERMES PERFORMANCE {stamp(data['since'])} .. {stamp(data['until'])} (start cohorts; lifetime counters)"]
    for name, profile in sorted(data['profiles'].items()):
        lines.extend(profile_lines(name, profile))
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
    parser.add_argument('--digest', action='store_true',
                        help='One fleet line plus only profiles with failures or attention')
    args = parser.parse_args(argv)
    until = args.until if args.until is not None else time.time()
    since = args.since if args.since is not None else until-args.days*86400
    if not math.isfinite(since) or not math.isfinite(until) or not 0<until-since<=90*86400:
        parser.error('Use an increasing window of at most 90 days')
    data = report(Path(os.environ.get('HERMES_ROOT', str(Path.home()/'.hermes'))), since, until)
    print(json.dumps(data, sort_keys=True) if args.json else render(data, digest=args.digest))


if __name__ == '__main__':
    main(None)
