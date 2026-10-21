#!/usr/bin/env python3
"""Collect a read-only daily snapshot of every Hermes kanban board.

Injected into the daily board-steward cron prompt. It never mutates a board:
the steward reports findings and proposed remedies using real state. Existing
Python/SQLite operations glue; no new backend or dependency. Output is compact text.
"""

from __future__ import annotations

import datetime as dt
import json
import os
import sqlite3
import time
from pathlib import Path

# Boards live under the shared/default root (HERMES_ROOT), not a profile home:
# a per-profile cron job still inspects every board on the host.
ROOT = Path(os.environ.get("HERMES_ROOT", str(Path.home() / ".hermes")))
BOARDS = ROOT / "kanban" / "boards"

# A blocked spell older than this is reported as long-blocked. The owner
# overrides it with STEWARD_LONG_BLOCKED_HOURS when a board's normal cycle is
# longer; the runbook owns the default.
DEFAULT_LONG_BLOCKED_HOURS = 4.0

# A *card* older than this counts as long-standing even when its current
# blocked spell is short: re-blocking an old card is a stalled feature wearing
# a fresh block, and a spell-only threshold hides exactly the work the owner
# wants surfaced.
DEFAULT_STALE_CARD_HOURS = 20.0


def _hours(name: str, default: float) -> float:
    raw = os.environ.get(name, "")
    try:
        value = float(raw)
    except ValueError:
        return default
    return value if value > 0 else default


def long_blocked_hours() -> float:
    """The long-blocked current-spell threshold, ignoring an unusable override."""
    return _hours("STEWARD_LONG_BLOCKED_HOURS", DEFAULT_LONG_BLOCKED_HOURS)


def stale_card_hours() -> float:
    """The long-standing card-age threshold, ignoring an unusable override."""
    return _hours("STEWARD_STALE_CARD_HOURS", DEFAULT_STALE_CARD_HOURS)


def board_slugs() -> list[str]:
    # Any underscore or dot prefixed slug is hermes bookkeeping (the same rule
    # the durability sync and board-health enumerators use), not a board.
    if not BOARDS.is_dir():
        return []
    return sorted(
        p.name for p in BOARDS.iterdir()
        if p.is_dir() and not p.name.startswith(("_", "."))
    )


def one(conn: sqlite3.Connection, sql: str, args: tuple = ()) -> list:
    return conn.execute(sql, args).fetchall()


def columns(conn: sqlite3.Connection, table: str) -> set:
    """Column names for a table; empty when the table itself is absent."""
    try:
        return {row[1] for row in conn.execute(f"pragma table_info({table})")}
    except sqlite3.Error:
        return set()


def blocked_spells(conn: sqlite3.Connection, task_ids: list[str]) -> dict:
    """Map task id to (blocked_since, reason) for the *current* blocked spell.

    Age is derived from status history, not card age: a card unblocked and
    re-blocked has a short current spell even when the card itself is old. The
    newest ``blocked`` event starts the current spell. A board without
    ``task_events`` (an older or trimmed schema) falls back to no entry, so the
    caller degrades to card age and says so rather than inventing a duration.
    """
    if not task_ids:
        return {}
    marks = {tid: None for tid in task_ids}
    placeholders = ",".join("?" * len(task_ids))
    try:
        rows = conn.execute(
            f"select task_id, kind, payload, created_at from task_events"
            f" where kind='blocked' and task_id in ({placeholders})"
            f" order by created_at desc",
            tuple(task_ids),
        ).fetchall()
    except sqlite3.Error:
        return {}
    for tid, _kind, payload, created_at in rows:
        if marks[tid] is not None:
            continue  # An older blocked mark cannot start the current spell.
        try:
            reason = (json.loads(payload or "{}").get("reason") or "").strip()
        except (ValueError, AttributeError):
            reason = ""
        marks[tid] = (created_at, reason)
    return {tid: value for tid, value in marks.items() if value is not None}


def _age(seconds: int) -> str:
    """Compact age: minutes below an hour, whole hours above it."""
    return f"{seconds // 60}m" if seconds < 3600 else f"{seconds // 3600}h"


def long_blocked_lines(conn: sqlite3.Connection, blocked: list) -> list[str]:
    """Report blocked work that has stayed blocked too long.

    Two independent bases qualify a card, because they mean different things
    and a spell-only threshold hides the second:

    * ``spell`` - the *current* blocked spell outlived the threshold. The card
      is stuck in place right now.
    * ``card`` - the card itself outlived the longer stale threshold even
      though it was unblocked since. The feature keeps being re-blocked, so
      the stall outlives any single block.

    Each line carries the age, the UTC instant the current spell started, the
    recorded cause, whether an owner gate already exists and the repeat count.
    Longest-standing first: that card is the finding.
    """
    if not blocked:
        return []
    now = int(time.time())
    spell_limit = long_blocked_hours() * 3600
    card_limit = stale_card_hours() * 3600
    spells = blocked_spells(conn, [row[0] for row in blocked])
    stale = []
    for row in blocked:
        tid, who, kind, recur, fails, err, created, body = row
        spell = spells.get(tid)
        if spell is None:
            started = int(created or 0)
            spell_reason = ""
            history = False
        else:
            started, spell_reason = spell
            history = True
        if not started:
            # Neither status history nor card age is available. An unknown age
            # is not a long block; the card still appears in BLOCKED above.
            continue
        spell_age = now - started
        card_age = now - int(created or 0)
        bases = [
            name
            for name, limit in (("spell", spell_limit), ("card", card_limit))
            if (spell_age if name == "spell" else card_age) >= limit
        ]
        if not bases:
            continue
        reason = (spell_reason or err or kind or "").strip().replace("\n", " ")[:200]
        gate = "yes" if (kind == "needs_input" or "Hard Blocker" in (body or "")) else "no"
        stale.append(
            (
                max(spell_age, card_age),
                tid, who, kind, recur, fails, gate,
                spell_age, card_age, started, "+".join(bases), history, reason,
            )
        )
    if not stale:
        return []
    stale.sort(reverse=True)
    hours = int(spell_limit // 3600) or 1
    card_hours = int(card_limit // 3600) or 1
    lines = [
        f"LONG BLOCKED (spell>={hours}h or card>={card_hours}h, {len(stale)}):"
    ]
    for (_rank, tid, who, kind, recur, fails, gate, spell_age, card_age, started,
         bases, history, reason) in stale:
        since = dt.datetime.fromtimestamp(started, dt.timezone.utc).isoformat(timespec="minutes")
        if not history:
            since += "(no status history; age is card age)"
        lines.append(
            f"- {tid} @{who or '?'} basis={bases} spell={_age(spell_age)}"
            f" card={_age(card_age)} since={since} kind={kind or '?'}"
            f" recur={recur} fails={fails} owner_gate={gate} :: {reason}"
        )
    lines.append(
        "  (new or materially changed cards need a full owner-authority prompt;"
        " unchanged cards carry forward; the remedy is the underlying cause,"
        " never a guard or permission change)"
    )
    return lines


def snapshot_board(slug: str) -> list[str]:
    db = BOARDS / slug / "kanban.db"
    if not db.exists():
        return []
    out: list[str] = [f"[board {slug}]"]
    # Read-only: never create or lock the live DB.
    uri = f"file:{db}?mode=ro"
    conn = sqlite3.connect(uri, uri=True, timeout=5)
    try:
        counts = dict(one(conn, "select status, count(*) from tasks group by status"))
        out.append("counts: " + ", ".join(f"{k}={v}" for k, v in sorted(counts.items())))

        since = int(time.time()) - 24 * 60 * 60

        # A board whose schema predates created_at still reports every other
        # section; only the long-blocked ages are unavailable, and an unknown
        # age is never dressed up as a long one.
        created = "coalesce(created_at,0)" if "created_at" in columns(conn, "tasks") else "0"
        blocked = one(
            conn,
            "select id, assignee, block_kind, block_recurrences, consecutive_failures,"
            f" coalesce(last_failure_error,''), {created}, coalesce(body,'')"
            " from tasks where status='blocked' order by id",
        )
        if blocked:
            out.append("BLOCKED:")
            for tid, who, kind, rec, cf, err, _created, _body in blocked:
                reason = (err or kind or "").strip().replace("\n", " ")[:160]
                out.append(
                    f"- {tid} @{who or '?'} kind={kind or '?'} recur={rec} fails={cf} :: {reason}"
                )

        hard = one(
            conn,
            "select id, title, assignee from tasks where status='blocked' and"
            " (block_kind='needs_input' or body like '%Hard Blocker%') order by id",
        )
        if hard:
            out.append("OWNER GATES (never auto-unblock):")
            for tid, title, who in hard:
                out.append(f"- {tid} @{who or '?'} :: {title}")

        out.extend(long_blocked_lines(conn, blocked))

        done = one(
            conn,
            "select id, assignee, title from tasks where status='done' and completed_at>=?"
            " order by completed_at",
            (since,),
        )
        out.append(f"LAST 24H DONE ({len(done)}):")
        for tid, who, title in done:
            out.append(f"- {tid} @{who or '?'} :: {title}")

        runs = one(
            conn,
            "select task_id, profile, status, outcome, coalesce(summary,''), coalesce(error,'')"
            " from task_runs where started_at>=? and (status in"
            " ('crashed','timed_out','failed') or outcome in"
            " ('crashed','timed_out','spawn_failed','gave_up')) order by started_at",
            (since,),
        )
        out.append(f"LAST 24H FAILED RUNS ({len(runs)}):")
        for tid, prof, status, outcome, summary, err in runs:
            detail = (err or summary or "").strip().replace("\n", " ")[:160]
            out.append(f"- {tid} @{prof or '?'} status={status} outcome={outcome or '?'} :: {detail}")

        running = one(
            conn,
            "select id, assignee, worker_pid, coalesce(last_heartbeat_at,0) from tasks"
            " where status='running' order by id",
        )
        if running:
            now = int(time.time())
            out.append("RUNNING:")
            for tid, who, pid, hb in running:
                age = f"{(now - hb) // 60}m" if hb else "no-heartbeat"
                out.append(f"- {tid} @{who or '?'} pid={pid or '?'} heartbeat={age} ago")
    finally:
        conn.close()
    return out


def main() -> None:
    now = dt.datetime.now(dt.timezone.utc).isoformat(timespec="minutes")
    print(f"=== KANBAN DAILY SNAPSHOT {now} ===")
    slugs = board_slugs()
    if not slugs:
        print("(no boards found)")
        return
    for slug in slugs:
        try:
            lines = snapshot_board(slug)
        except sqlite3.Error as exc:
            # One corrupt, locked or schema-drifted board must not take the
            # whole daily report down with it: the healthy boards still
            # report, and the failed board surfaces as its own warning line
            # (the same convention the other collectors use).
            lines = [f"[board {slug}] BOARD_READ_FAILED :: {str(exc).strip()[:200]}"]
        if lines:
            print()
            print("\n".join(lines))


if __name__ == "__main__":
    main()
