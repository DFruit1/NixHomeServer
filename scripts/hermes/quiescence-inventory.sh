#!/usr/bin/env python3
"""Produce a durable, citable quiescence receipt for the deploy gate.

Read-only against every live board; writes one JSON receipt that later cards
byte-verify instead of re-gathering the same evidence by hand. See
documentation/plans/2026-10-22-hermes-evidence-capture-powers.md (T2).

Exit
----
0  receipt produced (findings may accompany it)
2  QUIESCENCE_BAD_KNOB: a knob or board slug is malformed
3  QUIESCENCE_DB_ERROR: a board database would not open
4  QUIESCENCE_QUERY_ERROR: a receipt query failed at runtime
"""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import sys


def fail(marker: str, code: int, detail: str) -> None:
    assert marker and code != 0
    print(f"{marker} {detail}".strip(), file=sys.stderr)
    sys.exit(code)


def kanban_home() -> Path:
    root = os.environ.get("HERMES_ROOT") or str(Path.home() / ".hermes")
    return Path(root).resolve()


def boards(home: Path, named: list[str]) -> list[tuple[str, Path]]:
    boundary = home / "kanban" / "boards"
    found: list[tuple[str, Path]] = []
    for entry in sorted({*(named or []), *(p.name for p in boundary.glob("*"))}):
        slug = entry.strip().lower()
        if not slug or slug.startswith("_") or slug.startswith("."):
            continue
        db = boundary / slug / "kanban.db"
        if db.is_file() or the_name(named, slug):
            found.append((slug, db))
    return found


def the_name(named: list[str], slug: str) -> bool:
    return bool(named) and slug in named


def read_rows(db: Path) -> tuple[dict, list, list]:
    import sqlite3

    connection = sqlite3.connect("file:%s?mode=ro" % db, uri=True, timeout=.5)
    try:
        connection.execute("PRAGMA query_only=ON")
        counts = dict(connection.execute(
            "SELECT status, COUNT(*) FROM tasks GROUP BY status"))
        active_rows = connection.execute(
            "SELECT t.id, COALESCE(t.assignee,''), t.status,"
            " COALESCE(t.worker_pid,0), COALESCE(t.claim_lock,''),"
            " COALESCE(t.last_heartbeat_at, t.started_at, t.created_at),"
            " COALESCE(t.consecutive_failures,0)"
            "  FROM tasks t"
            " WHERE t.status IN ('running','ready','blocked')"
            " ORDER BY t.status, t.id").fetchall()
        run_rows = connection.execute(
            "SELECT r.task_id, r.id, r.status, COALESCE(r.outcome,''),"
            " COALESCE(r.worker_pid,0), r.started_at, r.ended_at"
            "  FROM task_runs r"
            " WHERE r.task_id IN"
            "   (SELECT id FROM tasks"
            "     WHERE status IN ('running','ready','blocked'))").fetchall()
        return counts, active_rows, run_rows
    finally:
        connection.close()


def liveness(pid: int) -> str:
    if not pid or pid <= 1:
        return "no-worker"
    try:
        os.kill(pid, 0)
        return "unknown"
    except ProcessLookupError:
        return "gone"
    except PermissionError:
        return "alive"
    except OSError:
        return "unknown"


BUCKETS = (("lt5m", 300), ("5-15m", 900), ("15-30m", 1800),
           ("30-60m", 3600), ("1-4h", 14400))


def bucket(now: int, when: int) -> str:
    if not when:
        return "unknown"
    age = max(0, now - when)
    for name, limit in BUCKETS:
        if age < limit:
            return name
    return "gt4h"


def receipt(now: int, home: Path, board: str, db: Path, named: bool) -> dict:
    name = db.name
    if not db.is_file() and not named:
        return {"board": board, "missing": True}
    try:
        counts, active_rows, run_rows = read_rows(db)
    except Exception as exc:  # sqlite3.Error, ValueError, OSError
        fail("QUIESCENCE_DB_ERROR", 3, f"board={board} db={db} {exc}")
    active = [
        {"id": tid, "assignee": assignee, "status": status,
         "worker_pid": pid, "worker_liveness": liveness(pid),
         "claim_present": bool(lock),
         "heartbeat_age": bucket(now, touched),
         "consecutive_failures": failures}
        for tid, assignee, status, pid, lock, touched, failures in active_rows]
    seen: set[str] = set()
    latest_runs = []
    for task, run, status, outcome, pid, started, ended in run_rows:
        if task in seen:
            continue  # rows arrive already ordered by run id
        seen.add(task)
        latest_runs.append(
            {"task_id": task, "run_id": run, "status": status,
             "outcome": outcome, "worker_pid": pid,
             "started_age": bucket(now, started), "ended": bool(ended)})
    latest_runs.sort(key=lambda entry: entry["task_id"])
    return {"board": board, "status_counts": counts, "active": active,
            "latest_runs": latest_runs}


def system_stamp() -> str:
    current = Path("/run/current-system")
    if not current.is_symlink():
        return ""
    try:
        return os.readlink(current)
    except OSError:
        return ""


def main(argv: list[str]) -> int:
    named_args: list[str] = []
    for arg in argv:
        if arg.startswith("--board="):
            named_args.append(arg[len("--board="):])
        elif arg in ("-h", "--help"):
            print(__doc__)
            return 0
        elif arg.startswith("-"):
            fail("QUIESCENCE_BAD_KNOB", 2, f"option='{arg}' (want a slug)")
        else:
            named_args.append(arg)
    for slug in named_args:
        if (not slug or slug != slug.strip().lower()
                or any(c not in "abcdefghijklmnopqrstuvwxyz0123456789_-" for c in slug)):
            fail("QUIESCENCE_BAD_KNOB", 2, f"board='{slug}'")

    home = kanban_home()
    receipt_dir = home / "state" / "quiescence-receipts"
    settled = receipt_dir / "receipt.json"
    previous = {}
    try:
        previous = json.loads(settled.read_text())
    except (OSError, json.JSONDecodeError):
        previous = {}

    now = int(__import__("time").time())
    receipt_dir.mkdir(parents=True, exist_ok=True)
    boards_out = [
        receipt(now, home, slug, db, the_name(named_args, slug))
        for slug, db in boards(home, named_args)]

    result: dict = {"receipt_schema": 1, "now_epoch": now,
                    "boards": boards_out}
    stamp = system_stamp()
    if stamp:
        result["current_system"] = {
            "stamp": stamp,
            "change": ("change" if previous.get("current_system", {}).get("stamp")
                       not in ("", stamp) else "same")
            if previous.get("current_system", {}).get("stamp") else "baseline",
        }
    guard = home / "scripts" / "shutdown-guard.sh"
    status_file = Path(
        os.environ.get("SHUTDOWN_GUARD_STATE_DIR")
        or "/run/nixhomeserver-shutdown-guard") / "status"
    state = ""
    message = ""
    if status_file.is_file():
        for line in status_file.read_text().splitlines():
            if line.startswith("state="):
                state = line[len("state="):]
            elif line.startswith("message="):
                message = line[len("message="):]
    result["shutdown_guard"] = {"state": state or "unknown"}

    payload = json.dumps(result, sort_keys=True, indent=1) + "\n"
    digest = hashlib.sha256(payload.encode()).hexdigest()
    temporary = receipt_dir / ("receipt.json.tmp" + str(os.getpid()))
    with temporary.open("x") as handle:  # fails closed if another writer exists
        handle.write(payload)
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(temporary, settled)

    print(f"QUIESCENCE_RECEIPT sha256={digest}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
