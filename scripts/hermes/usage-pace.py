#!/usr/bin/env python3
"""Compact usage/credit pace for the daily board-steward report.

Reads only local, non-secret telemetry:

* the account rate-limit windows T3 Code resolves for Codex and OpenCode Go/Zen,
  from its provider cache (``~/.t3/caches/<provider>.json`` -> ``usageLimits``);
  each resolved window carries ``usedPercent``, ``resetsAt`` and, when the
  provider reports it, ``windowDurationMins``;
* the same windows live, best-effort: Codex from ``hermes usage --json`` and
  OpenCode Go/Zen from a local OpenCode credential, queried against the Zen
  usage endpoint (the source the T3 Code usage tab reads);
* Hermes' own per-model spend from ``session_model_usage`` in ``state.db``;
* OpenCode's per-session totals from its local ``opencode.db``.

The OpenCode usage credential is resolved locally, in order: the ``opencode-go``
API key in the auth file, else the active console (device-login) access token in
``opencode.db`` — the credential the CLI/TUI and Hermes' ``opencode-go`` provider
use, and the only one the Zen endpoint entitles — else ``OPENCODE_API_KEY``. A
raw console API key returns HTTP 403 ("An active OpenCode Go subscription is
required") even with a live subscription, so the device token is required; an
env-key-only setup produces the same 403 the daily report showed.

Pace reuses T3 Code's own assessment so a window reads here exactly as it does in
T3: compare the used percent against the elapsed fraction of the window and call
it ``OVER PACE`` when usage leads the clock by more than five points, ``Under
pace`` when it trails by more than five, ``On pace`` otherwise. T3 is the only
source that resolves ``windowDurationMins`` (the raw endpoints omit it), so the
duration comes from its cache; the kind/label/duration fall back only when the
cache is missing.

Each account window prints as one line, one metric per bullet::

    Codex
    - Weekly: 75% left, resets in 5d 13h (OVER PACE)
    OpenCode
    - 5-Hour: 84% left, resets in 2h 23m (On pace)

It prints a short block and never sends, writes board state, or reveals a
credential. Every source is best-effort: a missing credential, database or
binary degrades that one line, never the report.

Environment overrides (used by tests and a different checkout):
  HERMES_ROOT         hermes state dir (default ~/.hermes)
  HERMES_BIN          hermes launcher (default ~/.local/bin/hermes, else PATH)
  T3_CACHE_DIR        T3 Code provider cache (default ~/.t3/caches)
  OPENCODE_DB         opencode database, incl. the console credential
                      (default ~/.local/share/opencode/opencode.db)
  OPENCODE_AUTH       opencode auth file (default ~/.local/share/opencode/auth.json)
  OPENCODE_GO_TOKEN   explicit Zen/Go token, overriding both local sources
  OPENCODE_API_KEY    legacy opencode-go key, used only when nothing else resolves
  OPENCODE_USAGE_URL  opencode-go usage endpoint (default the Zen usage API)
  USAGE_PACE_NOW      ISO instant to treat as now (default: the current time)
"""
from __future__ import annotations

import datetime as dt
import json
import os
import shutil
import sqlite3
import subprocess
import time
import urllib.error
import urllib.request
from pathlib import Path

DAY = 86400.0
SPIKE_RATIO = 1.5
MINUTE_MS = 60_000
HOUR_MS = 3_600_000
DAY_MS = 86_400_000
# T3 Code calls usage "ahead"/"under" pace past a five-point lead/lag against the
# elapsed fraction of the window; keep the same margin so the verdicts match.
PACE_MARGIN = 5.0
# Provider display order, and the window kinds each reports. T3 resolves the
# window list; this is the order to print them in and the fallback set when its
# cache is missing.
PROVIDERS = (
    ("codex", "Codex", ("weekly",)),
    ("opencode", "OpenCode", ("session", "weekly", "monthly")),
)
KIND_LABELS = {"session": "5-Hour", "weekly": "Weekly", "monthly": "Monthly"}
KIND_DURATION_MINS = {"session": 300, "weekly": 10_080, "monthly": 43_200}
# Zen usage keys mapped to T3 window kinds.
OPENCODE_GO_KINDS = {"rolling": "session", "weekly": "weekly", "monthly": "monthly"}
# Cloudflare fronts the Zen endpoint and rejects clients with no/opaque
# user-agent (error 1010), so send a descriptive product string.
OPENCODE_GO_UA = "hermes-usage-pace/1.0"


def hermes_root() -> Path:
    return Path(os.environ.get("HERMES_ROOT", str(Path.home() / ".hermes")))


def hermes_bin() -> str | None:
    override = os.environ.get("HERMES_BIN")
    if override:
        return override if Path(override).exists() else None
    local = Path.home() / ".local/bin/hermes"
    return str(local) if local.exists() else shutil.which("hermes")


def t3_cache_dir() -> Path:
    return Path(os.environ.get("T3_CACHE_DIR", str(Path.home() / ".t3" / "caches")))


def opencode_db() -> Path:
    return Path(os.environ.get("OPENCODE_DB", str(Path.home() / ".local/share/opencode/opencode.db")))


def opencode_auth() -> Path:
    return Path(os.environ.get("OPENCODE_AUTH", str(Path.home() / ".local/share/opencode/auth.json")))


def opencode_usage_url() -> str:
    return os.environ.get("OPENCODE_USAGE_URL", "https://opencode.ai/zen/go/v1/usage")


def http_get_json(url: str, headers: dict, timeout: int = 15) -> dict:
    request = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return json.loads(response.read().decode("utf-8"))


def now() -> dt.datetime:
    raw = os.environ.get("USAGE_PACE_NOW")
    if raw:
        try:
            return dt.datetime.fromisoformat(raw)
        except ValueError:
            pass
    return dt.datetime.now().astimezone()


def now_ms() -> float:
    return now().timestamp() * 1000


def fmt_tokens(value: int) -> str:
    for unit, scale in (("B", 1e9), ("M", 1e6), ("K", 1e3)):
        if abs(value) >= scale:
            return f"{value / scale:.1f}{unit}"
    return str(value)


def parse_epoch_ms(value) -> float | None:
    if not isinstance(value, str):
        return None
    try:
        parsed = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=now().tzinfo)
    return parsed.timestamp() * 1000


def t3_usage_limits(provider: str) -> dict:
    """The provider's resolved usage limits from T3 Code's cache, best-effort."""
    path = t3_cache_dir() / f"{provider}.json"
    try:
        data = json.loads(path.read_text())
    except (OSError, ValueError):
        return {}
    limits = data.get("usageLimits") if isinstance(data, dict) else None
    return limits if isinstance(limits, dict) else {}


def t3_windows(provider: str) -> dict:
    """kind -> resolved window (usedPercent, resetsAt, windowDurationMins)."""
    windows = {}
    for window in t3_usage_limits(provider).get("windows") or []:
        if isinstance(window, dict) and window.get("kind"):
            windows[str(window["kind"])] = window
    return windows


def remaining_percent(used) -> int | None:
    try:
        used = float(used)
    except (TypeError, ValueError):
        return None
    return round(100 - max(0.0, min(100.0, used)))


def pace_verdict(used, resets_at, duration_mins, moment_ms: float) -> str | None:
    """T3 Code's pace assessment, mapped to a short label.

    ``usedPercent`` versus the elapsed fraction of a fixed-length window: a lead
    of more than five points is over pace, a lag of more than five is under.
    Returns ``None`` when T3 could not resolve the window length.
    """
    try:
        used = float(used)
    except (TypeError, ValueError):
        return None
    reset = parse_epoch_ms(resets_at)
    if reset is None or not duration_mins or duration_mins <= 0:
        return None
    window_ms = float(duration_mins) * MINUTE_MS
    elapsed = max(0.0, min(1.0, (window_ms - (reset - moment_ms)) / window_ms))
    diff = used - elapsed * 100
    if diff > PACE_MARGIN:
        return "OVER PACE"
    if diff < -PACE_MARGIN:
        return "Under pace"
    return "On pace"


def duration_phrase(ms: float) -> str:
    """T3 Code's reset countdown: ``Xd Yh`` / ``Xh Ym`` / ``Xm``."""
    ms = max(0, int(ms))
    days = ms // DAY_MS
    hours = (ms % DAY_MS) // HOUR_MS
    minutes = (ms % HOUR_MS) // MINUTE_MS
    if days > 0:
        return f"{days}d {hours}h"
    if hours > 0:
        return f"{hours}h {minutes}m"
    return f"{minutes}m"


def reset_phrase(resets_at, moment_ms: float) -> str | None:
    reset = parse_epoch_ms(resets_at)
    if reset is None:
        return None
    if reset <= moment_ms:
        return "resets now"
    return f"resets in {duration_phrase(reset - moment_ms)}"


def window_line(label: str, used, resets_at, duration_mins, moment_ms: float) -> str:
    """One metric per bullet: ``- Weekly: 75% left, resets in 5d 13h (OVER PACE)``."""
    left = remaining_percent(used)
    if left is None:
        return f"- {label}: usage unavailable"
    line = f"- {label}: {left}% left"
    reset = reset_phrase(resets_at, moment_ms)
    if reset:
        line += f", {reset}"
    verdict = pace_verdict(used, resets_at, duration_mins, moment_ms)
    if verdict:
        line += f" ({verdict})"
    return line


def codex_live() -> tuple[dict, str | None]:
    """kind -> (used_percent, resets_at) from ``hermes usage --json``, best-effort."""
    binary = hermes_bin()
    if not binary:
        return {}, "no hermes launcher found"
    try:
        proc = subprocess.run(
            [binary, "usage", "--provider", "openai-codex", "--json"],
            capture_output=True, text=True, timeout=30,
            env={**os.environ, "HERMES_HOME": str(hermes_root())})
        data = json.loads(proc.stdout or "{}")
    except (OSError, subprocess.SubprocessError, ValueError):
        return {}, "usage fetch failed"
    windows = data.get("windows") or []
    if not windows:
        return {}, str(data.get("unavailable_reason") or "no usage endpoint")
    resolved = {}
    for window in windows:
        label = str(window.get("label") or "").strip().lower()
        kind = {"weekly": "weekly", "5h": "session", "session": "session",
                "monthly": "monthly"}.get(label)
        if kind:
            resolved[kind] = (window.get("used_percent"), window.get("resets_at"))
    return resolved, None


def opencode_device_token() -> str:
    """The active OpenCode console (device-login) access token, best-effort.

    The Zen usage endpoint entitles this token, not a console API key: an
    API-key request returns HTTP 403 ("An active OpenCode Go subscription is
    required") even with a live subscription. It is the credential the CLI/TUI
    and Hermes' ``opencode-go`` provider use, read from the same read-only
    ``credential`` row in ``opencode.db``; reading it at call time keeps the
    report working when opencode refreshes it. The token is never printed.
    """
    db = opencode_db()
    if not db.exists():
        return ""
    try:
        conn = sqlite3.connect(f"file:{db}?mode=ro", uri=True, timeout=5)
    except sqlite3.Error:
        return ""
    try:
        row = conn.execute(
            "select value from credential"
            " where integration_id = 'opencode' and label = 'Default' and active = 1"
        ).fetchone()
    except sqlite3.Error:
        return ""
    finally:
        conn.close()
    try:
        return str(json.loads(row[0]).get("access", "")).strip()
    except (TypeError, ValueError, AttributeError, IndexError):
        return ""


def opencode_usage_key() -> str:
    """Resolve the OpenCode Go credential for the Zen usage endpoint, best-effort.

    Order: an explicit ``OPENCODE_GO_TOKEN``, then the ``opencode-go`` API key
    in the local OpenCode auth file (the source T3 Code reads), then the active
    console device credential, then the legacy ``OPENCODE_API_KEY``. Only the
    device token is reliably entitled, so it is what an env-key-only setup needs.
    """
    key = os.environ.get("OPENCODE_GO_TOKEN", "").strip()
    if key:
        return key
    try:
        auth = json.loads(opencode_auth().read_text())
    except (OSError, ValueError):
        auth = None
    if isinstance(auth, dict):
        candidate = auth.get("opencode-go")
        if isinstance(candidate, dict) and candidate.get("type") == "api":
            key = str(candidate.get("key", "")).strip()
            if key:
                return key
    return opencode_device_token() or os.environ.get("OPENCODE_API_KEY", "").strip()


def opencode_live() -> tuple[dict, str | None]:
    """kind -> (percent, resetsAt) from the Zen usage endpoint, best-effort.

    The key (see ``opencode_usage_key``) authenticates a read-only GET against
    the Zen usage endpoint, which returns rolling/weekly/monthly ``percent`` and
    ``resetsAt``. The key is never printed.
    """
    key = opencode_usage_key()
    if not key:
        return {}, "no OpenCode credential"
    try:
        data = http_get_json(opencode_usage_url(), {
            "Authorization": f"Bearer {key}",
            "User-Agent": OPENCODE_GO_UA,
            "Accept": "application/json",
        })
    except urllib.error.HTTPError as exc:
        return {}, f"usage request failed: HTTP {exc.code}"
    except (urllib.error.URLError, OSError, ValueError):
        return {}, "usage request failed"
    usage = data.get("usage") if isinstance(data, dict) else None
    if not isinstance(usage, dict):
        return {}, "no usage in response"
    resolved = {}
    for name, kind in OPENCODE_GO_KINDS.items():
        record = usage.get(name)
        if isinstance(record, dict):
            resolved[kind] = (record.get("percent"), record.get("resetsAt"))
    return resolved, None if resolved else "empty usage response"


def account_limit_lines() -> list[str]:
    """Account windows as one metric per bullet, reusing T3 Code's assessments."""
    moment_ms = now_ms()
    lines: list[str] = []
    live = {"codex": codex_live(), "opencode": opencode_live()}
    for provider, display, kinds in PROVIDERS:
        cached = t3_windows(provider)
        resolved, reason = live[provider]
        bullets: list[str] = []
        for kind in kinds:
            window = cached.get(kind) or {}
            used, resets_at = resolved.get(kind, (None, None))
            if used is None:
                used = window.get("usedPercent")
            if resets_at is None:
                resets_at = window.get("resetsAt")
            duration = window.get("windowDurationMins")
            if not isinstance(duration, (int, float)) or duration <= 0:
                duration = KIND_DURATION_MINS.get(kind)
            if used is None and resets_at is None:
                continue
            bullets.append(window_line(KIND_LABELS.get(kind, kind), used, resets_at, duration, moment_ms))
        if provider == "codex":
            credits = t3_usage_limits(provider).get("resetCredits") or {}
            count = credits.get("availableCount")
            if count:
                bullets.append(f"- Banked resets: {count}")
        lines.append(display)
        lines.extend(bullets or [f"- unavailable ({reason or 'no usage data'})"])
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
    now_epoch_ms = int(now_ms())
    try:
        conn = sqlite3.connect(f"file:{db}?mode=ro", uri=True, timeout=5)
    except sqlite3.Error:
        return totals
    try:
        for key, window in (("7d", 7 * DAY), ("24h", DAY)):
            cutoff = now_epoch_ms - int(window * 1000)
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
    for line in account_limit_lines():
        print(line)
    print("HERMES BOTS (session history):")
    for line in spend_line("hermes", hermes_spend()):
        print(line)
    print("OPENCODE (local sessions):")
    for line in spend_line("opencode", opencode_spend()):
        print(line)


if __name__ == "__main__":
    main()
