#!/usr/bin/env python3
"""Escalate repeated cron failure, denial and suppression loops.

Cron loops are easy to miss because every job looks healthy from the
dispatcher's side: the scheduler records the run, the incident ledger pings
once and then stays quiet, and a suppressed or failed run does not ever raise
the job's own priority. The 2026-10-10..21 owner-alert gap hid for twelve days
in exactly that shape -- every 15-minute run finished, printed nothing and
recorded ``suppressed``, while the delivery backlog it existed to send kept
growing. Nothing on the host watched the repetition itself. This monitor does
(owner direction 2026-10-22): repeated denials or suppressions are treated as a
deep-dive signal for ``project-auditor``, mirroring the aging escalation's
commissioning discipline, so the root cause is routed to head-coordinator for
an agent-side fix, or, when the supplier is genuinely the owner, the
coordinator authors the checked SimpleX gate through the existing
owner-alerts sender. The monitor itself never pages the owner.

Three detectors, over the durable execution ledger (read-only):

* a ``failure loop`` -- the same error signature failing repeatedly inside the
  window, for any job. The scheduler alerts each signature once; what no one
  observes is the signature still failing hours later.
* a ``delivery denial`` -- a trailing streak of outcomes in ``failed`` /
  ``not_configured`` persisting past the denial threshold; the channel the
  run tried to deliver through is configured-but-dead or missing for days.
* ``persistent silence`` for delivery-class jobs -- a job whose name matches
  the delivery pattern whose outcome trail inside the window is entirely
  ``suppressed``. Delivery-class jobs are the ones whose reason to exist is a
  delivery; for any other job a quiet run is healthy idleness, so the default
  pattern covers only alert/notification-class naming (aging escalation and
  idempotent monitors deliver locally by design and are excluded by default).

One deep-dive commission owns each (job, detector) episode, deduplicated
through the native ``idempotency_key``. Completion or failure of the audit does
not establish recovery. A new commission requires observed recovery after the
old commission, followed by a fresh qualifying episode.

Signals are damped only through the commission lifecycle; the monitor has no
own timers. Nothing here mutates jobs, boards or cards beyond creating the
commission card and reading with read-only connections.

Installing
----------
The cron engine runs the copy under ``$HERMES_ROOT/scripts``, not this file,
so an edited script has no effect until it is installed again:

  * ``--install-files`` copies the script to ``$HERMES_ROOT/scripts`` with
    mode 0700 and changes nothing else. Never calls ``hermes cron create``.
  * ``--install`` does the same copy and then creates the paused, disabled
    ``cron loop escalation`` job for a new install only.
"""
import argparse
import json
import os
from pathlib import Path
import re
import sqlite3
import subprocess
import time
from datetime import datetime

PROFILE = 'head-coordinator'
AUDITOR = 'project-auditor'
JOB = 'cron loop escalation'
CREATED_BY = 'cron-loop-monitor'
KEY_PREFIX = 'cron-loop-monitor'

# Detector thresholds. Environment-overridable like the aging thresholds; an
# unusable override falls back to the default.
DEFAULT_WINDOW_HOURS = 72.0
DEFAULT_FAILURE_MIN = 4
DEFAULT_DENIAL_HOURS = 24.0
DEFAULT_SUPPRESSION_HOURS = 36.0
# Jobs whose entire purpose is delivery. Anything matching stays healthy with
# quiet runs only until this monitor says otherwise; everything else is exempt
# from the silence detector because quiet local-only monitors are by design.
DEFAULT_DELIVERY_PATTERN = r'(?i)(alert|notif)'

# Outcome classes. A quiet run records 'suppressed'; 'suppressed_acked' means
# the scheduler withheld a repeat ping for a known signature -- still silence
# a delivery job must not keep. 'failed' and 'not_configured' are deliveries
# that could not happen at all.
DENIAL_OUTCOMES = ('failed', 'not_configured')
SILENT_OUTCOMES = ('suppressed', 'suppressed_acked')
# Non-terminal rows do not belong to any loop: a claimed/running execution may
# be resolving it, so the streak walk skips rather than breaks on them.
NON_TERMINAL_STATUSES = ('claimed', 'running')

DETECTORS = ('failure-loop', 'delivery-denial', 'persistent-silence')


def hours_env(name, default):
    raw = os.environ.get(name, '').strip()
    try:
        value = float(raw) if raw else default
    except ValueError:
        value = default
    return value if value > 0 else default


def pattern_env(name, default):
    raw = os.environ.get(name, '').strip()
    if not raw:
        return re.compile(default)
    try:
        return re.compile(raw)
    except re.error:
        return re.compile(default)


def parse_when(text):
    """Parse a executions.claimed_at ISO string to epoch seconds.

    The scheduler writes local-time ISO stamps (naive or offset); naive values
    are read as local time, matching how they were written.
    """
    if not text:
        return None
    try:
        parsed = datetime.fromisoformat(str(text))
    except ValueError:
        return None
    if parsed.tzinfo is None:
        return parsed.timestamp()
    return parsed.timestamp()


def read_jobs(root):
    """Job id -> record, or an empty mapping when the journal is unreadable."""
    path = Path(root) / 'cron' / 'jobs.json'
    try:
        data = json.loads(path.read_text())
    except (OSError, ValueError):
        return {}
    jobs = data if isinstance(data, list) else data.get('jobs', [])
    return {j.get('id'): j for j in jobs
            if isinstance(j, dict) and j.get('id')}


def read_executions(root, cutoff_iso):
    """job_id ->[list of terminal execution rows] inside the window."""
    db_path = Path(root) / 'cron' / 'executions.db'
    if not db_path.exists():
        return {}
    db = sqlite3.connect(db_path.resolve().as_uri() + '?mode=ro', uri=True)
    db.row_factory = sqlite3.Row
    db.execute('PRAGMA query_only=ON')
    try:
        columns = {r[1] for r in db.execute('PRAGMA table_info(executions)')}
        select = 'claimed_at, status'
        select += ', error' if 'error' in columns else ', NULL AS error'
        select += (', delivery_outcome' if 'delivery_outcome' in columns
                   else ', NULL AS delivery_outcome')
        if 'job_id' not in columns:
            return {}
        rows = db.execute(
            f'SELECT job_id, {select} FROM executions '
            "WHERE status NOT IN ('claimed','running') AND claimed_at >= ?"
            ' ORDER BY claimed_at ASC', (cutoff_iso,)).fetchall()
        grouped = {}
        for row in rows:
            grouped.setdefault(row['job_id'], []).append(row)
        return grouped
    finally:
        db.close()


def signature(error):
    """Normalise an error into a comparable failure signature."""
    text = re.sub(r'\s+', ' ', str(error or '')).strip().lower()
    return text[:140]


def failure_loop(rows, minimum):
    """The dominant repeated signature when it trips the repeat threshold.

    A failed run can carry ``status='failed'`` or a failed delivery outcome;
    both count. Returns ``(count, latest_row, signature)`` for the most
    frequent signature since the last applicable recovery, with episode and
    recovery timestamps, or ``None`` under the threshold.
    """
    # Execution recovery and delivery recovery are different facts. A completed
    # self-sending job can legitimately be suppressed by the scheduler, while
    # suppression alone cannot establish that a denied delivery recovered.
    counts = {'execution': {}, 'delivery': {}}
    recovered = {'execution': None, 'delivery': None}
    for row in rows:
        if row['status'] in NON_TERMINAL_STATUSES:
            continue
        outcome = row['delivery_outcome'] or ''
        if row['status'] == 'completed':
            counts['execution'].clear()
            recovered['execution'] = row['claimed_at']
        if outcome in ('delivered', 'queued'):
            counts['delivery'].clear()
            recovered['delivery'] = row['claimed_at']
        kind = ('execution' if row['status'] == 'failed' else
                'delivery' if outcome in DENIAL_OUTCOMES else None)
        text = signature(row['error'])
        if kind and text:
            counts[kind].setdefault(text, []).append(row)
    best = None
    for kind, failures in counts.items():
        for text, group in failures.items():
            if len(group) >= minimum and (best is None
                                          or len(group) > len(best[0])):
                best = (group, group[-1], text, recovered[kind])
    if best is None:
        return None
    group, latest, text, recovery = best
    return len(group), latest, text, group[0]['claimed_at'], recovery


def trailing_streak(rows, outcomes):
    """(first_row, latest_row) of the trailing streak with one of ``outcomes``.

    The walk starts at the newest row and stops at the first terminal row
    whose outcome is outside ``outcomes``: the streak is what persisted since
    the last different outcome, not a histogram of the whole window.
    Non-terminal rows (claimed/running) are transparent -- an inflight run may
    be resolving the loop one way or the other, so it neither extends nor ends
    the streak. ``rows`` arrive ascending by claimed_at.
    """
    latest = first = None
    for row in reversed(rows):
        if row['status'] in NON_TERMINAL_STATUSES:
            continue
        if (row['delivery_outcome'] or '') not in outcomes:
            break
        latest = latest or row
        first = row
    return first, latest


def owner_alerts_health(root, job):
    """Read only bounded, metadata-only evidence from the maintained sender."""
    if (not job or job.get('script') != 'kanban-owner-alerts.py'
            or job.get('no_agent') is not True):
        return {}
    try:
        path = Path(root) / 'kanban/owner-alerts/health.json'
        if path.stat().st_size > 4096:
            return {}
        health = json.loads(path.read_text())
        return health if isinstance(health, dict) and health.get('version') == 1 else {}
    except (OSError, ValueError):
        return {}


def owner_alerts_healthy(root, job, rows, now, *, health=None):
    """Qualify self-sender reconciliation, never infer handset delivery.

    Missing, stale, incomplete or previous-run evidence leaves silence visible.
    Only this maintained no-agent sender produces this receipt; other jobs keep
    the ordinary delivery detector.
    """
    if not rows:
        return False
    health = owner_alerts_health(root, job) if health is None else health
    try:
        started, completed = health.get('started_at'), health.get('completed_at')
        latest = parse_when(rows[-1]['claimed_at'])
        return (health.get('version') == 1
                and health.get('snapshot_complete') is True
                and type(health.get('errors')) is int and health['errors'] == 0
                and type(health.get('due_unsent')) is int and health['due_unsent'] == 0
                and type(started) in (int, float) and type(completed) in (int, float)
                and latest is not None and latest <= started <= completed <= now
                and now - completed <= 45 * 60)
    except (OSError, ValueError, TypeError):
        return False


def detection_for_job(job_id, job, rows, window_hours, now, *, sender_healthy=False,
                      sender_recovered_at=None):
    """One signal description per detector that tripped, for this job.

    Rows are window-filtered here as well as at the SQL boundary: the
    detection math must not silently depend on the caller pre-cutting
    history.
    """
    cutoff = now - window_hours * 3600
    scoped = []
    for row in rows:
        when = parse_when(row['claimed_at'])
        if when is not None and when >= cutoff:
            scoped.append(row)
    rows = scoped
    signals = []
    if not rows:
        return signals

    failed = failure_loop(rows, int(hours_env('CRON_LOOP_FAILURE_MIN',
                                              DEFAULT_FAILURE_MIN)))
    if failed:
        count, latest, text, started, recovered = failed
        signals.append({
            'detector': 'failure-loop',
            'headline': f'{count} failures repeat one error signature in {window_hours:.0f}h',
            'evidence': f'latest at {latest["claimed_at"]}: {text}',
            'episode_started_at': started,
            'recovered_at': recovered,
        })

    first, latest = trailing_streak(rows, DENIAL_OUTCOMES)
    if first:
        started = parse_when(first['claimed_at'])
        if started and now - started >= hours_env(
                'CRON_LOOP_DENIAL_HOURS', DEFAULT_DENIAL_HOURS) * 3600:
            signals.append({
                'detector': 'delivery-denial',
                'headline': f'delivery denied for {(now - started) / 3600:.1f}h '
                            f"({latest['delivery_outcome'] or latest['status']})",
                'evidence': f'latest at {latest["claimed_at"]}: '
                            f'{signature(latest["error"]) or latest["status"]}',
                'episode_started_at': first['claimed_at'],
                'recovered_at': next((r['claimed_at'] for r in reversed(rows)
                    if (r['delivery_outcome'] or '') in ('delivered', 'queued')), None),
            })

    delivery_pattern = pattern_env('CRON_LOOP_DELIVERY_PATTERN',
                                   DEFAULT_DELIVERY_PATTERN)
    name = (job or {}).get('name') or job_id
    recovery_epoch = parse_when(sender_recovered_at)
    silence_rows = [r for r in rows if recovery_epoch is None
                    or parse_when(r['claimed_at']) > recovery_epoch]
    if (len(silence_rows) >= 2 and not sender_healthy
            and delivery_pattern.search(name or '')):
        first, latest = trailing_streak(silence_rows, SILENT_OUTCOMES)
        if first:
            started = parse_when(first['claimed_at'])
            if started and now - started >= hours_env(
                    'CRON_LOOP_SUPPRESSION_HOURS', DEFAULT_SUPPRESSION_HOURS) * 3600:
                signals.append({
                    'detector': 'persistent-silence',
                    'headline': f'delivery-class job silent '
                                f'{(now - started) / 3600:.1f}h with no delivery',
                    'evidence': f'latest at {latest["claimed_at"]}',
                    'episode_started_at': first['claimed_at'],
                    'recovered_at': max([r['claimed_at'] for r in rows
                        if (r['delivery_outcome'] or '') in ('delivered', 'queued')]
                        + ([sender_recovered_at] if sender_recovered_at else []),
                        key=parse_when, default=None),
                })
    return signals


def commission_body(signal, job_name, job_id):
    """Deep-dive commission: feature, one question, scope, stopping condition."""
    return '\n'.join([
        f"Goal: Root-cause the repeated cron {signal['detector']} on job "
        f"'{job_name}' ({job_id}) and name its concrete resolution route.",
        f"Evidence: {signal['headline']}. {signal['evidence']}",
        "Durable sources (read-only): ~/.hermes/cron/executions.db rows for",
        f"this job, ~/.hermes/cron/jobs.json record, and per-run output under",
        f"~/.hermes/cron/output/{job_id}/. Related repository scripts live in",
        "scripts/hermes/ of the NixHomeServer checkout.",
        "Scope: read-only evidence then one disposition; no source changes",
        "and no job mutation from this audit. Question: is the repetition a",
        "defect, a dead-but-live signal, or intended silence, and what exact",
        "change clears it for good?",
        "Verify: a disposition comment here naming one route -- agent-side",
        f"fix (name the exact change for {PROFILE}), owner-only step (name",
        "it so the coordinator authors the owner gate through the existing",
        "owner-alerts sender), or intended behaviour (record why the",
        "repetition is acceptable and what would make it unacceptable).",
        "Stopping condition: that disposition comment exists.",
        "Constraints:",
        "- Evidence-only audit: do not edit, pause or delete cron jobs,",
        "  boards or cards other than this disposition comment.",
        "- Never page the owner directly; if the supplier is the owner, the",
        f"  coordinator ({PROFILE}) authors the checked SimpleX gate via the",
        "  owner-alerts sender.",
        "- Preserve guards, owner gates and existing decisions.",
    ])


def commission_key(job_id, detector, sequence=0):
    base = f"{KEY_PREFIX}:{detector}:{job_id}"
    return base if sequence == 0 else f"{base}:r{sequence}"


def connect_ro(path):
    db = sqlite3.connect(path.resolve().as_uri() + '?mode=ro', uri=True)
    db.row_factory = sqlite3.Row
    db.execute('PRAGMA query_only=ON')
    return db


def commission_usable(status, created_at, recovered_at):
    """Whether an existing commission already covers this signal.

    Completing a diagnosis does not repair its cause. A terminal commission
    still owns that episode; only observed recovery followed by a new episode
    can re-arm it. Preserve failed commissions and their spent retry limits.
    """
    return (status not in ('done', 'archived', 'blocked')
            or recovered_at is None or created_at >= recovered_at)


def create_commission(root, slug, signal, job_name, job_id, env, report):
    """Create one deep-dive commission for a (job, detector) signal.

    Returns the commission card id, or a note when a commission already owns
    this episode. Rotation requires observed recovery, never a spent retry.

    Keyed on the stable ``job_id``, not the job name: a renamed job must not
    orphan its dedupe history, and a restored name must not inherit.
    """
    board_db = (Path(root) / 'kanban' / 'boards' / slug / 'kanban.db')
    if not board_db.exists():
        report.append(f"  !! board {slug} not found; commission not created")
        return ''
    base = f"{KEY_PREFIX}:{signal['detector']}:{job_id}"
    db = connect_ro(board_db)
    try:
        existing = {row['idempotency_key']: (row['status'], row['created_at'])
                    for row in db.execute(
            "SELECT idempotency_key, status, created_at FROM tasks"
            " WHERE idempotency_key LIKE ? || '%'", (base,)).fetchall()}
    finally:
        db.close()
    sequence = 0
    while True:
        entry = existing.get(commission_key(job_id, signal['detector'],
                                            sequence))
        if entry is None:
            break
        if commission_usable(*entry, parse_when(signal.get('recovered_at'))):
            return 'already commissioned'
        sequence += 1
    key = commission_key(job_id, signal['detector'], sequence)
    title = f"Deep-dive: repeated cron {signal['detector']} on {job_name}"
    body = commission_body(signal, job_name, job_id)
    result = run_cli([
        'kanban', '--board', slug, 'create', title,
        '--body', body, '--assignee', AUDITOR, '--workspace', 'scratch',
        '--idempotency-key', key, '--created-by', CREATED_BY,
    ], env)
    if result.returncode == 0:
        match = re.search(r't_[0-9a-f]+', result.stdout)
        return match.group(0) if match else 'created'
    combined = ((result.stderr or '') + (result.stdout or '')).lower()
    if 'idempotency' in combined or 'exists' in combined:
        return 'already commissioned'
    report.append(f"  !! commission failed for {job_name}: "
                  f"{combined.strip()[:200]}")
    return ''


def run_cli(args, root_env):
    result = subprocess.run(['hermes', *args], env=root_env,
                            capture_output=True, text=True, timeout=120)
    return result


def board_slug(root):
    """The commission target board: override, infra default, or any board."""
    slug = os.environ.get('CRON_LOOP_BOARD', '').strip()
    if slug:
        return slug
    slug = 'nixhomeserver'
    if (Path(root) / 'kanban' / 'boards' / slug / 'kanban.db').exists():
        return slug
    boards = root / 'kanban' / 'boards'
    if boards.is_dir():
        for candidate in sorted(p.name for p in boards.iterdir()
                                if p.is_dir() and (p / 'kanban.db').exists()
                                and not p.name.startswith(('_', '.'))):
            return candidate
    return slug


def install_files(root):
    """Copy this script to ``<root>/scripts`` with mode 0700; touch no job.

    The cron engine executes the installed copy, not the checkout, so every
    script edit needs this step. Separate from job creation so a refresh
    never duplicates the live job.
    """
    source = Path(__file__).resolve()
    scripts = Path(root) / 'scripts'
    scripts.mkdir(parents=True, exist_ok=True)
    target = scripts / source.name
    data = source.read_bytes()
    if not target.exists() or target.read_bytes() != data:
        target.write_bytes(data)
    target.chmod(0o700)
    return target


def create_job(root):
    """Create the paused cron job for a new install."""
    source = Path(__file__).resolve()
    env = os.environ.copy()
    env['HERMES_HOME'] = str(root)
    subprocess.run(['hermes', '--profile', 'default', 'cron', 'create',
                    'every 1h', '--name', JOB, '--script', source.name,
                    '--no-agent', '--deliver', 'local', '--workdir',
                    str(source.parent.parent), '--paused',
                    '--paused-reason',
                    'Validate cron loop escalation with --dry-run before'
                    ' activation'],
                   check=True, timeout=60, env=env)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    actions = parser.add_mutually_exclusive_group()
    actions.add_argument('--dry-run', action='store_true')
    actions.add_argument('--install', action='store_true',
                         help='Install the script and create the paused job')
    actions.add_argument('--install-files', action='store_true',
                         help='Install the script only; never touch cron jobs')
    args = parser.parse_args()

    root = Path(os.environ.get('HERMES_ROOT', str(Path.home() / '.hermes')))
    window_hours = hours_env('CRON_LOOP_WINDOW_HOURS', DEFAULT_WINDOW_HOURS)
    now = time.time()

    if args.install_files:
        target = install_files(root)
        print(f"installed {target}; no cron job created")
        return

    if args.install:
        target = install_files(root)
        create_job(root)
        print(f"installed {target} and created the paused '{JOB}' job")
        return

    cutoff = datetime.fromtimestamp(now - window_hours * 3600)
    cutoff_iso = cutoff.isoformat(timespec='seconds')
    jobs = read_jobs(root)
    executions = read_executions(root, cutoff_iso)
    if not executions:
        print("cron loop escalation: nothing to escalate")
        return

    slug = board_slug(root)
    env = os.environ.copy()
    env['HERMES_HOME'] = str(root)
    report = []
    for job_id in sorted(executions):
        rows = executions[job_id]
        health = owner_alerts_health(root, jobs.get(job_id))
        recovered = health.get('last_success_at')
        sender_recovered_at = (datetime.fromtimestamp(recovered).isoformat()
            if type(recovered) in (int, float) and 0 < recovered <= now else None)
        signals = detection_for_job(job_id, jobs.get(job_id), rows,
                                    window_hours, now,
                                    sender_healthy=owner_alerts_healthy(
                                        root, jobs.get(job_id), rows, now, health=health),
                                    sender_recovered_at=sender_recovered_at)
        if not signals:
            continue
        name = (jobs.get(job_id) or {}).get('name') or job_id
        for signal in signals:
            report.append(f"[cron] {name} ({job_id}): "
                          f"{signal['detector']} -- {signal['headline']}")
            report.append(f"  -> commission project-auditor deep-dive"
                          f" on {slug}")
            if args.dry_run:
                continue
            created = create_commission(root, slug, signal, name, job_id,
                                        env, report)
            if created:
                report.append(f"  -> commission: {created}")

    if not report:
        print("cron loop escalation: nothing to escalate")
    else:
        print('\n'.join(report))


if __name__ == '__main__':
    main()
