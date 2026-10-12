#!/usr/bin/env python3
"""Compact usage/credit pace for the daily board-steward report.

Reads only local, non-secret telemetry:

* the account rate-limit windows the provider exposes through
  ``hermes usage --json`` (Codex weekly/5h windows, plan, banked resets);
* Hermes' own per-model spend from ``session_model_usage`` in ``state.db``;
* OpenCode's per-session totals from its local ``opencode.db``.

It prints a short block and never sends, writes board state, or reveals a
credential. The daily prompt turns this into a credit-risk and spike report;
this script only supplies the numbers. Every source is best-effort: a missing
credential, database or binary degrades that one line, never the report.

Environment overrides (used by tests and a different checkout):
  HERMES_ROOT    hermes state dir (default ~/.hermes)
  HERMES_BIN     hermes launcher (default ~/.local/bin/hermes, else PATH)
  OPENCODE_DB    opencode database (default ~/.local/share/opencode/opencode.db)
  USAGE_PACE_NOW ISO instant to treat as now (default: the current time)
"""
from __future__ import annotations

import datetime as dt
import json
import os
import shutil
import sqlite3
import subprocess
import time
from pathlib import Path

DAY = 86400.0
SPIKE_RATIO = 1.5
WINDOW_DAYS = {"weekly": 7.0, "daily": 1.0, "monthly": 30.0,
               "5h": 5.0 / 24, "hourly": 1.0 / 24}


def hermes_root() -> Path:
    return Path(os.environ.get("HERMES_ROOT", str(Path.home() / ".hermes")))


def hermes_bin() -> str | None:
    override = os.environ.get("HERMES_BIN")
    if override:
        return override if Path(override).exists() else None
    local = Path.home() / ".local/bin/hermes"
    return str(local) if local.exists() else shutil.which("hermes")


def opencode_db() -> Path:
    return Path(os.environ.get("OPENCODE_DB", str(Path.home() / ".local/share/opencode/opencode.db")))


def now() -> dt.datetime:
    raw = os.environ.get("USAGE_PACE_NOW")
    if raw:
        try:
            return dt.datetime.fromisoformat(raw)
        except ValueError:
            pass
    return dt.datetime.now().astimezone()


def fmt_tokens(value: int) -> str:
    for unit, scale in (("B", 1e9), ("M", 1e6), ("K", 1e3)):
        if abs(value) >= scale:
            return f"{value / scale:.1f}{unit}"
    return str(value)


def parse_iso(value) -> dt.datetime | None:
    if not isinstance(value, str):
        return None
    try:
        parsed = dt.datetime.fromisoformat(value)
    except ValueError:
        return None
    return parsed if parsed.tzinfo else parsed.replace(tzinfo=now().tzinfo)


def pace_note(provider: str, label: str, used, resets_at) -> str | None:
    """Project the window to its reset at the pace observed since it opened."""
    window_days = WINDOW_DAYS.get(str(label).strip().lower())
    reset = parse_iso(resets_at)
    if window_days is None or reset is None or used is None:
        return None
    remaining_days = (reset - now()).total_seconds() / DAY
    elapsed_days = window_days - remaining_days
    if elapsed_days <= 0 or remaining_days < 0:
        return None
    rate = used / elapsed_days
    projected = used + rate * remaining_days
    risk = "RISK: projected to exhaust before reset" if projected >= 100 else "ok"
    return (f"- {provider} {label} pace: {rate:.1f}%/day; projected "
            f"{projected:.0f}% at reset ({risk})")


def provider_windows() -> list[str]:
    """Account rate-limit windows from `hermes usage --json`, best-effort."""
    binary = hermes_bin()
    if not binary:
        return ["- unavailable: no hermes launcher found"]
    lines: list[str] = []
    providers = ["openai-codex"]
    default = os.environ.get("USAGE_PACE_PROVIDER")
    if default:
        providers.insert(0, default)
    seen: set[str] = set()
    for provider in providers:
        if provider in seen:
            continue
        seen.add(provider)
        try:
            proc = subprocess.run(
                [binary, "usage", "--provider", provider, "--json"],
                capture_output=True, text=True, timeout=30,
                env={**os.environ, "HERMES_HOME": str(hermes_root())})
            data = json.loads(proc.stdout or "{}")
        except (OSError, subprocess.SubprocessError, ValueError):
            lines.append(f"- {provider}: unavailable (usage fetch failed)")
            continue
        windows = data.get("windows") or []
        if not windows:
            reason = data.get("unavailable_reason") or "no usage endpoint"
            lines.append(f"- {provider}: {reason}")
            continue
        plan = data.get("plan") or "?"
        for window in windows:
            label = window.get("label") or "window"
            used = window.get("used_percent")
            reset = window.get("resets_at")
            lines.append(f"- {provider} ({plan}) {label}: {used}% used, resets {reset}")
            note = pace_note(provider, label, used, reset)
            if note:
                lines.append(note)
        for detail in data.get("details") or []:
            lines.append(f"- {provider} note: {detail}")
    return lines


def hermes_spend() -> dict:
    """Token and session totals from every profile's session history, 24h/7d.

    Cron and the agents are per-profile, so the bots' usage lives across the
    shared state.db and each ``profiles/*/state.db``, not one table.
    """
    totals = {"24h": [0, 0, 0.0], "7d": [0, 0, 0.0]}  # sessions, tokens, cost
    dbs = [hermes_root() / "state.db"]
    dbs.extend(sorted((hermes_root() / "profiles").glob("*/state.db")))
    cutoffs = (("7d", time.time() - 7 * DAY), ("24h", time.time() - DAY))
    for db in dbs:
        if not db.exists():
            continue
        try:
            conn = sqlite3.connect(f"file:{db}?mode=ro", uri=True, timeout=5)
        except sqlite3.Error:
            continue
        try:
            for key, cutoff in cutoffs:
                row = conn.execute(
                    "select count(*),"
                    " coalesce(sum(input_tokens)+sum(output_tokens),0)"
                    " from sessions where started_at >= ?", (cutoff,)).fetchone()
                totals[key][0] += int(row[0])
                totals[key][1] += int(row[1])
        except sqlite3.Error:
            pass
        finally:
            conn.close()
    return totals


def opencode_spend() -> dict:
    """Cost and token totals from OpenCode's session table, 24h/7d."""
    totals = {"24h": [0, 0, 0], "7d": [0, 0, 0]}  # sessions, tokens, cost
    db = opencode_db()
    if not db.exists():
        return totals
    now_ms = int(now().timestamp() * 1000)
    try:
        conn = sqlite3.connect(f"file:{db}?mode=ro", uri=True, timeout=5)
    except sqlite3.Error:
        return totals
    try:
        for key, window in (("7d", 7 * DAY), ("24h", DAY)):
            cutoff = now_ms - int(window * 1000)
            row = conn.execute(
                "select count(*),"
                " coalesce(sum(tokens_input)+sum(tokens_output),0),"
                " coalesce(sum(cost),0)"
                " from session where time_updated >= ?", (cutoff,)).fetchone()
            totals[key] = [int(row[0]), int(row[1]), float(row[2])]
    except sqlite3.Error:
        pass
    finally:
        conn.close()
    return totals


def spend_line(label: str, totals: dict) -> list[str]:
    day, week = totals["24h"], totals["7d"]
    daily_avg = week[1] / 7.0 if week[1] else 0.0
    spike = " SPIKE" if daily_avg and day[1] > SPIKE_RATIO * daily_avg else ""
    return [
        f"- {label} 24h: {fmt_tokens(day[1])} tok, ${day[2]:.2f}, {day[0]} units",
        f"- {label} 7d : {fmt_tokens(week[1])} tok, ${week[2]:.2f}, {week[0]} units"
        f" (avg {fmt_tokens(int(daily_avg))} tok/day){spike}",
    ]


def main() -> None:
    stamp = now().strftime("%Y-%m-%d %H:%M")
    print(f"=== USAGE PACE {stamp} ===")
    print("ACCOUNT LIMITS:")
    for line in provider_windows():
        print(line)
    print("HERMES BOTS (session history):")
    for line in spend_line("hermes", hermes_spend()):
        print(line)
    print("OPENCODE (local sessions):")
    for line in spend_line("opencode", opencode_spend()):
        print(line)


if __name__ == "__main__":
    main()
