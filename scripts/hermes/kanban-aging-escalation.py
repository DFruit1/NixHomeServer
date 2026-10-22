#!/usr/bin/env python3
"""Aging escalation for open kanban cards, on the owner's standing policy.

Open work that quietly stops moving is the failure mode this guards: a card
sits in todo/blocked/scheduled while every dispatchable lane stays busy, and
nothing flags the drift until a human reads the board. The policy (owner
direction 2026-10-19) escalates by idle time -- time since the last
substantive board event, not card age:

  * idle >= 2 days  -- raise dispatch priority (the dispatcher orders lanes by
    ``priority DESC, created_at ASC``, so the bump is a real scheduling lever).
  * idle >= 3 days  -- raise priority further and add two measures: a
    project-auditor deep-dive commission (one per card, deduplicated by native
    idempotency key) that names the concrete resolution route, and a
    coordinator directive comment instructing head-coordinator to clear the
    card -- obtain the missing input, record a superseding decision, or close
    it with evidence.
  * auditor-reviewed >= 5 days -- a card the auditor has reviewed at least
    once, and that remains unresolved 5+ days after that review, gets a
    one-shot clearance directive to head-coordinator. The auditor's deep-dive
    did not clear it; further idle time will not. The coordinator must obtain
    the missing input, supersede it with evidence, or close it, and authors
    the owner gate itself if the supplier turns out to be the owner.

Every escalation action writes a board event (``reprioritized`` or
``commented``), which resets the card's idle clock. The job is therefore
self-damping: an escalated card re-enters escalation only after another full
quiet period. No extra state or dedupe scan is needed for cadence.

Exemptions: cards with a live worker (``running``), the deliberate
``[FEATURE TRACKER`` parking lot, and owner-gated cards. An owner gate waits
on the owner, not on dispatch order, so it receives only the coordinator
directive (a nudge to re-author or resolve the gate) -- never a priority bump
or an audit that could read as pressure to drop the gate. Only head-coordinator
authors or removes owner gates; this job never touches gate state.

An idle clock alone has a loophole: a card held open by perfunctory "still
waiting" comments never goes idle. Cards older than seven days therefore
escalate on age regardless of activity, mirroring the steward's
card-age basis alongside its current-spell basis.

The job mutates boards through the ``hermes kanban`` CLI and reads through
read-only SQLite connections, the same split the steward and owner-alert jobs
use. It creates no owner pages, subscriptions or timers.

Installing
----------
The cron engine runs the copy under ``$HERMES_ROOT/scripts``, not this file, so
an edited script has no effect until it is installed again:

  * ``--install-files`` copies the script to ``$HERMES_ROOT/scripts`` with mode
    0700 and changes nothing else. This is the update path for a host that
    already runs the job: it never calls ``hermes cron create``, so re-running
    it cannot leave a duplicate job behind.
  * ``--install`` does the same copy and then creates the paused, disabled
    ``kanban aging escalation`` job. It is for a new install only; it creates a
    job rather than checking for one.
"""
import argparse
import json
import os
from pathlib import Path
import re
import sqlite3
import subprocess
import sys
import time

PROFILE = 'head-coordinator'
AUDITOR = 'project-auditor'
JOB = 'kanban aging escalation'
CREATED_BY = 'aging-escalation'
DIRECTIVE_MARKER = '<!-- kanban-aging-escalation -->'
OWNER_ESCALATION_MARKER = '<!-- kanban-aging-clearance-escalation -->'
STALE_BLOCK_MARKER = '<!-- kanban-stale-block -->'

# Idle hours that trigger each tier. Environment-overridable like the
# steward's thresholds; an unusable override falls back to the default.
DEFAULT_PRIORITY_HOURS = 48.0
DEFAULT_ESCALATION_HOURS = 72.0
# Dispatch-order levels. 50 outranks the ordinary 0/1/10 field; 100 is the
# established high tier in this board's history. Bumps are monotone max().
PRIORITY_FLOOR = 50
ESCALATION_FLOOR = 100

OPEN_STATUSES = ('triage', 'todo', 'ready', 'scheduled', 'blocked', 'review')
# Automated churn that does not mean a human or agent touched the card.
NON_SUBSTANTIVE = {
    'heartbeat', 'dependency_wait', 'workspace_cleanup_deferred_shared',
    'terminal_worker_reaped', 'claim_rejected',
}
TRACKER_TITLE = re.compile(r'^\[FEATURE TRACKER', re.I)

# Owner escalation policy: a card the auditor has reviewed at least once, and
# that remains unresolved 5 days (default) after that review, gets a one-shot
# clearance directive to head-coordinator. This job never reclassifies the card:
# needs_input means owner-only, and only head-coordinator authors owner gates.
DEFAULT_OWNER_ESCALATION_DAYS = 5.0
# Repeat a clearance directive at most this often while the card is unchanged.
CLEARANCE_DAMP_DAYS = 5.0

# Triage aging: a card left in triage for more than this many days without
# being promoted to todo or done is flagged for coordinator disposition.
# Triage is a stopping point, not a resting place.
DEFAULT_TRIAGE_MAX_AGE_DAYS = 7.0


def hours_env(name, default):
    raw = os.environ.get(name, '').strip()
    try:
        value = float(raw) if raw else default
    except ValueError:
        value = default
    return value if value > 0 else default


def board_slugs(root):
    boards = root / 'kanban' / 'boards'
    if not boards.is_dir():
        return []
    return sorted(p.name for p in boards.iterdir()
                  if p.is_dir() and (p / 'kanban.db').exists()
                  and not p.name.startswith(('_', '.')))


def connect_ro(path):
    db = sqlite3.connect(path.resolve().as_uri() + '?mode=ro', uri=True)
    db.row_factory = sqlite3.Row
    db.execute('PRAGMA query_only=ON')
    return db


def last_substantive_at(db, task_id, created_at):
    """Newest substantive event timestamp, or card creation time.

    A missing or trimmed ``task_events`` table degrades to card age rather
    than inventing recency.
    """
    try:
        rows = db.execute(
            "SELECT kind, created_at FROM task_events WHERE task_id = ?",
            (task_id,)).fetchall()
    except sqlite3.Error:
        return created_at
    newest = created_at
    for kind, created in rows:
        if kind in NON_SUBSTANTIVE:
            continue
        newest = max(newest, created or 0)
    return newest


def is_owner_gate(db, task_id, body):
    """Owner gate = current needs_input block kind or a Hard Blocker line."""
    return gate_kind(db, task_id) == 'needs_input' or bool(
        re.search(r'^Hard Blocker\b', body or '', re.M | re.I))


def gate_kind(db, task_id):
    """The current gate kind recorded on the card, or None.

    ``tasks.block_kind`` exists on this schema; older boards without the
    column report no gate.
    """
    try:
        row = db.execute(
            "SELECT block_kind FROM tasks WHERE id = ?", (task_id,)).fetchone()
    except sqlite3.Error:
        return None
    return row['block_kind'] if row and row['block_kind'] else None


def recently_escalated(db, task_id, now, damp_seconds=3 * 86400):
    """Whether this job escalated the card within the damping window.

    Without this, the card-age backstop re-fires on every run forever: the
    card stays old no matter what the job does, so the job would repost its
    directive every tick. The job's own directive comment starts each
    card's quiet period again, uniformly for both escalation tiers.
    """
    try:
        row = db.execute(
            "SELECT created_at FROM task_comments WHERE task_id = ?"
            " AND author = ? ORDER BY id DESC LIMIT 1",
            (task_id, CREATED_BY)).fetchone()
    except sqlite3.Error:
        return False
    return bool(row and row['created_at']
                and now - row['created_at'] < damp_seconds)


def marker_posted_since(db, task_id, marker, now, damp_seconds):
    """Whether this job already posted a comment with ``marker`` recently.

    Clearance escalations need their own damping keyed on their own marker:
    a tier directive from the same tick must not suppress the clearance
    directive, and an unchanged clearance must not repost every six hours.
    """
    try:
        row = db.execute(
            "SELECT created_at FROM task_comments WHERE task_id = ?"
            " AND author = ? AND body LIKE ? ORDER BY id DESC LIMIT 1",
            (task_id, CREATED_BY, f'{marker}%')).fetchone()
    except sqlite3.Error:
        return False
    return bool(row and row['created_at']
                and now - row['created_at'] < damp_seconds)


def block_reason(db, task_id):
    """The newest blocked event's reason text, or ''."""
    try:
        row = db.execute(
            "SELECT payload FROM task_events WHERE task_id = ? AND kind = 'blocked'"
            ' ORDER BY id DESC LIMIT 1', (task_id,)).fetchone()
    except sqlite3.Error:
        return ''
    if not row:
        return ''
    try:
        return (json.loads(row['payload'] or '{}').get('reason') or '').strip()
    except (ValueError, AttributeError):
        return ''


def latest_verdict(db, task_id):
    """The newest verifier run's verdict metadata on a review card, or None."""
    try:
        row = db.execute(
            'SELECT r.metadata,r.profile,r.status,r.outcome,t.assignee FROM task_runs r'
            ' JOIN tasks t ON t.id=r.task_id WHERE r.task_id = ?'
            ' ORDER BY r.id DESC LIMIT 1', (task_id,)).fetchone()
    except sqlite3.Error:
        return None
    if (not row or row['profile'] != row['assignee'] or row['status'] != 'done'
            or row['outcome'] != 'completed'):
        return None
    try:
        data = json.loads(row['metadata'] or '{}')
    except (ValueError, AttributeError):
        return None
    if not isinstance(data, dict):
        return None
    if row['assignee'] == 'project-auditor':
        # This job only posts evidence; it never unblocks. Auditor planning
        # and self-review still cannot become a verified acceptance signal.
        independence = data.get('independence')
        checks = data.get('checks')
        if (not isinstance(independence, dict)
                or set(independence) != {'plan_author', 'implementer'}
                or independence['plan_author'] is not False
                or independence['implementer'] is not False
                or not isinstance(data.get('revision'), str) or not data['revision'].strip()
                or not isinstance(checks, list) or not checks
                or any(not isinstance(check, dict)
                       or not isinstance(check.get('command'), str) or not check['command'].strip()
                       or type(check.get('exit_code')) is not int
                       or (data.get('verdict') == 'accept' and check['exit_code'] != 0)
                       for check in checks)):
            return None
    verdict = data.get('verdict')
    return verdict if verdict in ('accept', 'request-changes') else None


def reviewer_is_done(db, task_id):
    """Whether the card is a completed verification in either qualified role."""
    try:
        row = db.execute(
            "SELECT assignee, tenant, status FROM tasks WHERE id = ?",
            (task_id,)).fetchone()
    except sqlite3.Error:
        return False
    return bool(row and row['status'] == 'done'
                and ((row['assignee'] == 'feature-reviewer'
                      and (row['tenant'] or '') not in {'continuous-improvement', 'review-question'})
                     or (row['assignee'] == 'project-auditor' and row['tenant'] == 'verification')))


def stale_block_evidence(db, task_id, reason):
    """Evidence that a blocked card's stated condition no longer holds.

    Two high-precision patterns are automatable; block reasons are otherwise
    prose, so anything else stays with the coordinator and the aging tiers
    rather than risking a false unblock:

    * the reason names a review card whose verdict was 'request-changes' at
      block time and that card's newest verifier verdict is now 'accept';
    * the card is a dependency block and none of its parents are open any
      more -- the exact shape the owner-blocker-authoring guard refuses to
      create, because a dependency block with no open prerequisite would
      otherwise degrade into a manufactured owner question.
    """
    if 'requested changes' in reason.lower():
        for ref in sorted(set(re.findall(r't_[0-9a-f]+', reason))):
            if not reviewer_is_done(db, ref):
                continue
            if latest_verdict(db, ref) == 'accept':
                return (f"the block reason names review {ref} with verdict"
                        f" 'request-changes', but {ref}'s newest verifier verdict"
                        " is now 'accept'")
    return None


def stale_dependency_block(db, task_id):
    """Whether a dependency block has outlived every open prerequisite."""
    try:
        kind = db.execute('SELECT block_kind FROM tasks WHERE id=?',
                          (task_id,)).fetchone()
        if not kind or kind['block_kind'] != 'dependency':
            return False
        open_parents = db.execute(
            "SELECT 1 FROM task_links l JOIN tasks p ON p.id=l.parent_id"
            " WHERE l.child_id=? AND p.status NOT IN ('done','archived') LIMIT 1",
            (task_id,)).fetchone()
    except sqlite3.Error:
        return False
    return open_parents is None


def recheck_blocks(root, slug, now, dry_run, report):
    """Flag blocked cards whose stated condition verifiably no longer holds.

    Read-only evaluation; the action is a damped evidence comment for the
    coordinator. It never changes card status: unblocking is a decision, and
    only head-coordinator holds it.
    """
    db_path = root / 'kanban' / 'boards' / slug / 'kanban.db'
    env = os.environ.copy()
    env['HERMES_HOME'] = str(root)
    with connect_ro(db_path) as db:
        try:
            rows = db.execute(
                "SELECT id, title FROM tasks WHERE status = 'blocked'"
                ' ORDER BY created_at ASC').fetchall()
        except sqlite3.Error:
            return
        for row in rows:
            tid = row['id']
            evidence = None
            if stale_dependency_block(db, tid):
                evidence = ('this dependency block has no open prerequisite'
                            ' left; every parent is done or archived')
            else:
                reason = block_reason(db, tid)
                if reason:
                    evidence = stale_block_evidence(db, tid, reason)
            if not evidence:
                continue
            try:
                recent = db.execute(
                    'SELECT created_at FROM task_comments WHERE task_id = ?'
                    " AND author = ? AND body LIKE ?"
                    ' ORDER BY id DESC LIMIT 1',
                    (tid, CREATED_BY, f'{STALE_BLOCK_MARKER}%')).fetchone()
            except sqlite3.Error:
                recent = None
            if recent and recent['created_at'] and \
                    now - recent['created_at'] < 3 * 86400:
                continue
            report.append(f"[{slug}] {tid} (blocked) stale block: {evidence}")
            if dry_run:
                continue
            # Terminal parents may contain rejection or missing-input verdicts.
            # Preserve coordinator authority: evidence is a wake signal, never
            # sufficient proof that this consumer is safe to resume.
            comment = '\n'.join([
                STALE_BLOCK_MARKER,
                f"Stale block check: {evidence}. The stated condition no",
                "longer holds.",
                f"Decision owner: {PROFILE} -- unblock this card, or restate",
                "the current block reason so the next check is accurate.",
            ])
            run_cli(['kanban', '--board', slug, 'comment', tid, comment,
                     '--author', CREATED_BY], env)


def classify(db, row, now, priority_hours, escalation_hours,
             age_backstop_days=7.0):
    """Return (idle_days, tier, exempt, owner_gated) for one open card row.

    Two independent bases escalate, because they mean different things: idle
    time since the last substantive event catches quiet drift, while the
    card-age backstop catches the holding pattern -- a card kept "fresh" by
    perfunctory comments but with no decision for a week or more. The
    steward's spell-versus-card-age split is the same idea for blocked cards.
    """
    created = int(row['created_at'] or 0)
    idle_seconds = now - last_substantive_at(db, row['id'], created)
    idle_days = idle_seconds / 86400.0
    age_days = (now - created) / 86400.0
    owner_gated = gate_kind(db, row['id']) == 'needs_input' or bool(
        re.search(r'^Hard Blocker\b', row['body'] or '', re.M | re.I))
    exempt = (
        row['status'] == 'running'
        or bool(TRACKER_TITLE.match(row['title'] or ''))
    )
    if recently_escalated(db, row['id'], now):
        return idle_days, None, exempt, owner_gated
    if idle_days >= escalation_hours / 24.0 or age_days >= age_backstop_days:
        tier = 'escalate'
    elif idle_days >= priority_hours / 24.0:
        tier = 'bump'
    else:
        tier = None
    return idle_days, tier, exempt, owner_gated


def plan_card(row, idle_days, tier, exempt, owner_gated):
    """The concrete actions for one classified card, as display strings."""
    if tier is None or exempt:
        # Trackers are the deliberate parking lot; a running card has a live
        # worker (heartbeats), not a stalled one.
        return []
    actions = []
    if tier == 'bump':
        actions.append(f"priority -> >={PRIORITY_FLOOR}")
    elif tier == 'escalate':
        if owner_gated:
            # The wait is owner-supplied: nudge the coordinator about the
            # gate, never bump or audit pressure onto a live owner decision.
            actions.append('post coordinator clearing directive')
        else:
            actions.append(f"priority -> >={ESCALATION_FLOOR}")
            actions.append('commission auditor deep-dive')
            actions.append('post coordinator clearing directive')
    return actions


def directive_body(task_id, idle_days, commissioned):
    days = f"{idle_days:.1f}"
    evidence = f"deep-dive commission: {commissioned}" if commissioned else \
        "deep-dive commission: none this pass"
    return '\n'.join([
        DIRECTIVE_MARKER,
        f"Aging escalation: this card has been idle {days} days (policy: >3).",
        f"Decision owner: {PROFILE} -- clear it actively, do not just wait:",
        "obtain the missing input, record a superseding decision with",
        "evidence, or close it as descoped/superseded with a reason.",
        "Reply on this card with the disposition and route taken.",
        evidence,
    ])


def commission_body(ids, slug, cards):
    """Audit commissioning body: feature, single question, scope, stopping
    condition, per the project-auditor lane shape in hermes-card-authoring."""
    if len(ids) == 1:
        tid = ids[0]
        lines = [
            f"Goal: Name the concrete route to clear aged card {tid}.",
            f"Scope: read-only evidence on {slug}:{tid} -- body, comments,",
            "events, dependencies and the referenced artifacts. No source",
            "changes. Question: is the card still worth doing as written,",
            "and what single fact or action unblocks or retires it?",
            f"Verify: a disposition comment on {tid} naming one route --",
            "missing input (name the supplier), supersede (name the",
            "replacement), or close (name the reason).",
            "Stopping condition: that disposition comment exists.",
        ]
    else:
        listing = ' '.join(ids)
        lines = [
            f"Goal: Name the concrete route to clear each of {len(ids)}",
            "linked aged cards that have stalled together.",
            f"Scope: read-only evidence on {slug} cards {listing} --",
            "bodies, comments, events, dependency graph and referenced",
            "artifacts. No source changes. Question: which of these remain",
            "worth doing as written, and what single fact or action",
            "unblocks or retires each?",
            "Verify: a disposition comment on every member card naming one",
            "route -- missing input (name the supplier), supersede (name the",
            "replacement), or close (name the reason).",
            "Stopping condition: every member card has that comment.",
        ]
    lines.extend([
        "Constraints:",
        "- Evidence-only: preserve worker pins, gates and decision",
        f"  ownership; the coordinator ({PROFILE}) routes outcomes.",
        "- Do not unblock, complete, re-assign or edit member cards.",
    ])
    return '\n'.join(lines)


def run_cli(args, root_env):
    result = subprocess.run(['hermes', *args], env=root_env,
                            capture_output=True, text=True, timeout=120)
    return result


def escalated_components(db, tids):
    """Group escalated cards into dependency clusters.

    Cards joined by a parent/child link share one fate -- the cluster waits
    and clears together -- so they take one shared deep-dive commission
    instead of flooding the auditor lane with per-card duplicates. Isolated
    cards are their own component. Edges are read read-only; a board without
    ``task_links`` degrades to singleton clusters.
    """
    components = {tid: [tid] for tid in tids}
    if not tids:
        return []
    try:
        edges = db.execute(
            f"SELECT parent_id, child_id FROM task_links"
            f" WHERE parent_id IN ({','.join('?' * len(tids))})"
            f" OR child_id IN ({','.join('?' * len(tids))})",
            (*tids, *tids)).fetchall()
    except sqlite3.Error:
        edges = []
    for parent, child in [(r['parent_id'], r['child_id']) for r in edges]:
        if parent not in components or child not in components or parent == child:
            continue
        target, source = components[parent], components[child]
        if target is source:
            continue
        target.extend(source)
        for member in source:
            components[member] = target
    seen = set()
    ordered = []
    for tid in tids:
        marker = components[tid][0]
        if marker not in seen:
            seen.add(marker)
            ordered.append(components[tid])
    return ordered


def commission_key(slug, ids, sequence=0):
    """Dedupe key for one commission; sequence rotates past dead attempts."""
    base = f"aging-deepdive:{slug}:{'-'.join(sorted(ids))}"
    return base if sequence == 0 else f"{base}:r{sequence}"


def commission_usable(status, failures):
    """Whether an existing commission already covers this cluster."""
    # A live commission (ready/review/running/todo/blocked-untripped) still
    # owns the audit. A done one means the cluster re-armed and needs a fresh
    # audit; a breaker-tripped one (blocked with failures) means the attempt
    # dead-ended and the key must rotate so a replacement can exist at all.
    return status not in ('done', 'archived', 'blocked') or (
        status == 'blocked' and not failures)


def create_commission(slug, cluster, cards, db, env, report):
    """Create one deep-dive commission for a cluster of aged cards.

    ``cards`` maps task id -> its escalation metadata. Returns the commission
    card id, or a note when a usable commission already exists.
    """
    ids = sorted(cluster)
    base = f"aging-deepdive:{slug}:{'-'.join(ids)}"
    existing = {}
    try:
        rows = db.execute(
            "SELECT idempotency_key, status, consecutive_failures FROM tasks"
            " WHERE idempotency_key LIKE ? || '%'", (base,)).fetchall()
        for row in rows:
            existing[row['idempotency_key']] = (row['status'],
                                                row['consecutive_failures'])
    except sqlite3.Error:
        existing = {}
    sequence = 0
    while True:
        key = commission_key(slug, ids, sequence)
        entry = existing.get(key)
        if entry is None:
            break
        status, failures = entry
        if commission_usable(status, failures):
            return 'already commissioned'
        sequence += 1
    key = commission_key(slug, ids, sequence)
    label = (f"aged {ids[0]}" if len(ids) == 1
             else f"aged cluster of {len(ids)} linked cards")
    title = f"Deep-dive: route to clear {label}"
    body = commission_body(ids, slug, cards)
    result = run_cli([
        'kanban', '--board', slug, 'create', title,
        '--body', body, '--assignee', AUDITOR, '--workspace', 'scratch',
        '--idempotency-key', key, '--created-by', CREATED_BY,
    ], env)
    if result.returncode == 0:
        match = re.search(r't_[0-9a-f]+', result.stdout)
        return match.group(0) if match else 'created'
    # A duplicate idempotency key is success for this job: the commission
    # already exists. Anything else is a real failure worth reporting.
    combined = ((result.stderr or '') + (result.stdout or '')).lower()
    if 'idempotency' in combined or 'exists' in combined:
        return 'already commissioned'
    report.append(f"  !! commission failed for {label}: "
                  f"{combined.strip()[:200]}")
    return ''


def escalate_board(root, slug, now, dry_run, priority_hours, escalation_hours,
                   report):
    db_path = root / 'kanban' / 'boards' / slug / 'kanban.db'
    env = os.environ.copy()
    env['HERMES_HOME'] = str(root)
    with connect_ro(db_path) as db:
        rows = db.execute(
            f"SELECT id, title, body, status, priority, created_at FROM tasks"
            f" WHERE status IN ({','.join('?' * len(OPEN_STATUSES))})"
            f" ORDER BY priority DESC, created_at ASC", OPEN_STATUSES).fetchall()
        escalated = []
        for row in rows:
            idle_days, tier, exempt, owner_gated = classify(
                db, row, now, priority_hours, escalation_hours)
            if tier is None:
                continue
            actions = plan_card(row, idle_days, tier, exempt, owner_gated)
            if not actions:
                continue
            escalated.append({'row': row, 'idle_days': idle_days,
                              'tier': tier, 'owner_gated': owner_gated,
                              'actions': actions})
            age_days = (now - int(row['created_at'] or 0)) / 86400.0
            report.append(f"[{slug}] {row['id']} ({row['status']},"
                          f" idle {idle_days:.1f}d, age {age_days:.1f}d,"
                          f" prio {row['priority']}) {row['title'][:50]}")
            for action in actions:
                report.append(f"  -> {action}")
        if dry_run or not escalated:
            return
        for item in escalated:
            tid = item['row']['id']
            for action in item['actions']:
                if action.startswith('priority'):
                    floor = (ESCALATION_FLOOR if item['tier'] == 'escalate'
                             else PRIORITY_FLOOR)
                    target = max(int(item['row']['priority'] or 0), floor)
                    run_cli(['kanban', '--board', slug, 'edit', tid,
                             '--priority', str(target)], env)
        # One commission per dependency cluster, one directive per card.
        commissionable = [item['row']['id'] for item in escalated
                          if 'commission auditor deep-dive' in item['actions']]
        cards = {item['row']['id']: item for item in escalated}
        clusters = {tid: group for group in escalated_components(db, commissionable)
                    for tid in group}
        commissions = {}
        for item in escalated:
            tid = item['row']['id']
            if 'post coordinator clearing directive' not in item['actions']:
                continue
            if tid in commissionable:
                cluster_key = tuple(sorted(clusters[tid]))
                if cluster_key not in commissions:
                    commissions[cluster_key] = create_commission(
                        slug, list(cluster_key), cards, db, env, report)
                evidence = commissions[cluster_key]
            elif item['owner_gated']:
                evidence = 'owner-gated card, audit not commissioned'
            else:
                evidence = None
            directive = directive_body(tid, item['idle_days'], evidence)
            run_cli(['kanban', '--board', slug, 'comment', tid, directive,
                     '--author', CREATED_BY], env)


def last_auditor_review_at(db, task_id):
    """The newest timestamp the auditor reviewed this card, or None.

    A review is a comment by project-auditor on the card itself (not a
    separate audit card). This distinguishes 'the auditor looked at this card'
    from 'an audit was commissioned somewhere else'.
    """
    try:
        row = db.execute(
            "SELECT created_at FROM task_comments WHERE task_id = ?"
            " AND author = ? ORDER BY id DESC LIMIT 1",
            (task_id, AUDITOR)).fetchone()
    except sqlite3.Error:
        return None
    return row['created_at'] if row and row['created_at'] else None


def owner_escalation_candidates(db, now, owner_escalation_days):
    """Cards the auditor reviewed that remain unresolved past the owner threshold.

    Returns a list of (task_id, review_age_days, last_reason) tuples. Only
    cards still in an open status are returned -- done and archived cards
    resolved themselves and need no owner nudge.
    """
    try:
        rows = db.execute(
            "SELECT id, status, block_kind, created_at FROM tasks"
            f" WHERE status IN ({','.join('?' * len(OPEN_STATUSES))})"
            " AND status != 'running'",
            OPEN_STATUSES).fetchall()
    except sqlite3.Error:
        return []
    candidates = []
    threshold_seconds = owner_escalation_days * 86400.0
    for row in rows:
        # A scheduled hold is the coordinator's deliberate time wait, and an
        # existing owner gate already waits on the owner; neither is a card
        # left unattended. Escalating them would paper over a live decision.
        if row['status'] == 'scheduled':
            continue
        if gate_kind(db, row['id']) == 'needs_input':
            continue
        if marker_posted_since(db, row['id'], OWNER_ESCALATION_MARKER, now,
                               CLEARANCE_DAMP_DAYS * 86400):
            continue
        reviewed_at = last_auditor_review_at(db, row['id'])
        if not reviewed_at:
            continue
        age = now - reviewed_at
        if age < threshold_seconds:
            continue
        reason = block_reason(db, row['id']) or 'no recorded block reason'
        candidates.append((row['id'], age / 86400.0, reason))
    return candidates


def force_owner_escalation(root, slug, now, owner_escalation_days, dry_run, report):
    """Escalate auditor-reviewed stale cards to the coordinator, once.

    A card the auditor has reviewed at least once, and that remains unresolved
    after the escalation threshold, is not clearing on its own. The auditor's
    deep-dive did not resolve it, and further idle time will not change that.

    The job does not reclassify the card. ``needs_input`` means only the owner
    can decide or act, and only head-coordinator authors owner gates after the
    supplier test; a cron cannot know which supplier is missing. So this posts
    one directive asking the coordinator to clear the card or author a checked
    gate, and leaves status and block kind untouched. A deliberate ``scheduled``
    time wait and an existing owner gate are never overridden.
    """
    db_path = root / 'kanban' / 'boards' / slug / 'kanban.db'
    env = os.environ.copy()
    env['HERMES_HOME'] = str(root)
    with connect_ro(db_path) as db:
        candidates = owner_escalation_candidates(db, now, owner_escalation_days)
        for task_id, age_days, reason in candidates:
            title = ''
            try:
                row = db.execute("SELECT title FROM tasks WHERE id=?", (task_id,)).fetchone()
                title = row['title'] if row else ''
            except sqlite3.Error:
                pass
            report.append(
                f"[{slug}] {task_id} (auditor-reviewed {age_days:.1f}d ago)"
                f" clearance escalation: {title[:50]}")
            report.append(
                f"  -> post coordinator clearing directive"
                f" (block reason: {reason[:80]})")
            if dry_run:
                continue
            directive = '\n'.join([
                OWNER_ESCALATION_MARKER,
                f"Clearance escalation: the auditor reviewed this card"
                f" {age_days:.1f} days ago and it remains unresolved.",
                "Further idle time will not clear it. Do not park it unchanged.",
                f"Decision owner: {PROFILE} -- obtain the missing input, record",
                "a superseding decision with evidence, or close it as",
                "descoped/superseded with a reason.",
                "If the missing supplier is the owner, author the checked gate",
                "through the existing sender; this job does not create one.",
                f"Prior block reason: {reason[:200]}",
            ])
            run_cli(['kanban', '--board', slug, 'comment', task_id, directive,
                     '--author', CREATED_BY], env)


def triage_aging_candidates(db, now, triage_max_age_days):
    """Cards in triage longer than the triage age limit.

    Triage is a stopping point for cards awaiting classification, not a
    resting place. Returns ``(cards, trackers)``: cards need a per-card
    promote-or-archive disposition, while ``[FEATURE TRACKER`` cards are the
    deliberate parking lot and are reported as one aggregate line so a large
    tracker backlog stays visible without burying the real triage signal.
    """
    try:
        rows = db.execute(
            "SELECT id, title, created_at FROM tasks"
            " WHERE status = 'triage' ORDER BY created_at ASC").fetchall()
    except sqlite3.Error:
        return [], []
    cards, trackers = [], []
    threshold_seconds = triage_max_age_days * 86400.0
    for row in rows:
        age = now - int(row['created_at'] or 0)
        if age < threshold_seconds:
            continue
        item = (row['id'], age / 86400.0, row['title'])
        if TRACKER_TITLE.match(row['title'] or ''):
            trackers.append(item)
        else:
            cards.append(item)
    return cards, trackers


def install_files(root):
    """Copy this script to ``<root>/scripts`` with mode 0700; touch no cron job.

    The cron engine executes the installed copy, not the checkout, so every
    script edit needs this step. It is separate from job creation so an
    existing install can be refreshed without ``hermes cron create`` running
    again -- which is how a refresh used to leave a duplicate job behind.
    """
    source = Path(__file__).resolve()
    scripts = root / 'scripts'
    scripts.mkdir(parents=True, exist_ok=True)
    target = scripts / source.name
    data = source.read_bytes()
    if not target.exists() or target.read_bytes() != data:
        target.write_bytes(data)
    target.chmod(0o700)
    return target


def create_job(root):
    """Create the paused ``kanban aging escalation`` job for a new install."""
    source = Path(__file__).resolve()
    env = os.environ.copy()
    env['HERMES_HOME'] = str(root)
    subprocess.run(['hermes', '--profile', 'default', 'cron', 'create',
                    'every 6h', '--name', JOB, '--script', source.name,
                    '--no-agent', '--deliver', 'local', '--workdir',
                    str(source.parent.parent), '--paused',
                    '--paused-reason',
                    'Validate aging escalation with --dry-run before activation'],
                   check=True, timeout=60, env=env)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    actions = parser.add_mutually_exclusive_group()
    actions.add_argument('--dry-run', action='store_true')
    actions.add_argument('--install', action='store_true',
                         help='Install the script and create the paused job')
    actions.add_argument('--install-files', action='store_true',
                         help='Install the script only; never touch cron jobs')
    parser.add_argument('--board', help='restrict to one board slug')
    args = parser.parse_args()

    root = Path(os.environ.get('HERMES_ROOT', str(Path.home() / '.hermes')))
    priority_hours = hours_env('AGING_PRIORITY_HOURS', DEFAULT_PRIORITY_HOURS)
    escalation_hours = hours_env('AGING_ESCALATION_HOURS',
                                 DEFAULT_ESCALATION_HOURS)
    if escalation_hours <= priority_hours:
        escalation_hours = priority_hours + 24.0
    owner_escalation_days = hours_env('AGING_OWNER_ESCALATION_DAYS',
                                      DEFAULT_OWNER_ESCALATION_DAYS)
    triage_max_age_days = hours_env('AGING_TRIAGE_MAX_AGE_DAYS',
                                    DEFAULT_TRIAGE_MAX_AGE_DAYS)

    if args.install_files:
        target = install_files(root)
        print(f"installed {target}; no cron job created")
        return

    if args.install:
        target = install_files(root)
        create_job(root)
        print(f"installed {target} and created the paused '{JOB}' job")
        return

    slugs = [args.board] if args.board else board_slugs(root)
    now = int(time.time())
    report = []
    for slug in slugs:
        recheck_blocks(root, slug, now, args.dry_run, report)
        escalate_board(root, slug, now, args.dry_run, priority_hours,
                       escalation_hours, report)
        force_owner_escalation(root, slug, now, owner_escalation_days,
                               args.dry_run, report)
        # Triage aging: cards left in triage too long get flagged. Trackers
        # are aggregated so a parking-lot backlog cannot drown the real signal.
        db_path = root / 'kanban' / 'boards' / slug / 'kanban.db'
        with connect_ro(db_path) as db:
            triage_cards, triage_trackers = triage_aging_candidates(
                db, now, triage_max_age_days)
        for task_id, age_days, title in triage_cards:
            report.append(
                f"[{slug}] {task_id} (triage, age {age_days:.1f}d)"
                f" exceeds triage limit: {title[:50]}")
            report.append(f"  -> promote to todo, or archive with reason")
        if triage_trackers:
            oldest = max(age_days for _, age_days, _ in triage_trackers)
            report.append(
                f"[{slug}] {len(triage_trackers)} [FEATURE TRACKER] cards"
                f" exceed triage limit (oldest {oldest:.1f}d)")
            report.append(
                "  -> keep as tracker, promote one to todo, or archive with reason")
    if not report:
        print("aging escalation: nothing to escalate")
    else:
        print('\n'.join(report))


if __name__ == '__main__':
    main()
