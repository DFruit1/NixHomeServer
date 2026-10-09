#!/usr/bin/env python3
"""Collect a read-only daily snapshot of every Hermes kanban board.

Injected into the daily board-steward cron prompt. It never mutates a board: the
steward agent decides what to unblock, this script only reports what exists so the
agent reasons over real state instead of guessing. Output is compact text.
"""

from __future__ import annotations

import datetime as dt
import os
import sqlite3
import time
from pathlib import Path

# Boards live under the shared/default root (HERMES_ROOT), not a profile home:
# a per-profile cron job still inspects every board on the host.
ROOT = Path(os.environ.get("HERMES_ROOT", str(Path.home() / ".hermes")))
BOARDS = ROOT / "kanban" / "boards"
SKIP = {"_archived"}


def board_slugs() -> list[str]:
    if not BOARDS.is_dir():
        return []
    return sorted(p.name for p in BOARDS.iterdir() if p.is_dir() and p.name not in SKIP)


def one(conn: sqlite3.Connection, sql: str, args: tuple = ()) -> list:
    return conn.execute(sql, args).fetchall()


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

        midnight = int(
            dt.datetime.now().replace(hour=0, minute=0, second=0, microsecond=0).timestamp()
        )

        blocked = one(
            conn,
            "select id, assignee, block_kind, block_recurrences, consecutive_failures,"
            " coalesce(last_failure_error,''), coalesce(completed_at,0)"
            " from tasks where status='blocked' order by id",
        )
        if blocked:
            out.append("BLOCKED:")
            for tid, who, kind, rec, cf, err, _ in blocked:
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

        done = one(
            conn,
            "select id, assignee, title from tasks where status='done' and completed_at>=?"
            " order by completed_at",
            (midnight,),
        )
        out.append(f"TODAY DONE ({len(done)}):")
        for tid, who, title in done:
            out.append(f"- {tid} @{who or '?'} :: {title}")

        runs = one(
            conn,
            "select task_id, profile, status, outcome, coalesce(summary,''), coalesce(error,'')"
            " from task_runs where started_at>=? and (status in"
            " ('crashed','timed_out','failed') or outcome in"
            " ('crashed','timed_out','spawn_failed','gave_up')) order by started_at",
            (midnight,),
        )
        out.append(f"TODAY FAILED RUNS ({len(runs)}):")
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
    now = dt.datetime.now().strftime("%Y-%m-%d %H:%M")
    print(f"=== KANBAN DAILY SNAPSHOT {now} ===")
    slugs = board_slugs()
    if not slugs:
        print("(no boards found)")
        return
    for slug in slugs:
        lines = snapshot_board(slug)
        if lines:
            print()
            print("\n".join(lines))


if __name__ == "__main__":
    main()
