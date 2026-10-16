#!/usr/bin/env python3
"""Emit the daily board snapshot only during the daytime catch-up window.

The daily steward is scheduled for 07:00 local time. When the host is powered
down overnight the slot is missed; Hermes re-fires a missed recurring job on its
next tick (``cron.catch_up_missed``), which can land at any hour. This gate makes
that catch-up useful without a late-night report: the snapshot is emitted at most
once per calendar day and only between 07:00 and 17:00 local time. Outside the
window it prints a Hermes wake gate (``{"wakeAgent": false}`` as the final line)
so the scheduler skips the agent run and delivery, leaving the next 07:00
occurrence to report.

Wired as the ``--script`` of the ``hermes daily steward`` job only. The shared
snapshot collector (``kanban-daily-steward.py``) is unchanged and is still used
verbatim by the four-hourly stall follow-up job, which must run every slot.
"""
from __future__ import annotations

import datetime as dt
import importlib.util
import json
import os
from pathlib import Path

START_HOUR = 7   # 07:00 local, inclusive
END_HOUR = 17    # 17:00 local, exclusive: a later power-on waits for the next 07:00
COLLECTORS = ("kanban-daily-steward.py", "usage-pace.py", "kanban-performance.py")
DAILY_JOB_NAME = "hermes daily steward"


def hermes_root() -> Path:
    return Path(os.environ.get("HERMES_ROOT", str(Path.home() / ".hermes")))


def marker_path(root: Path) -> Path:
    return root / "state" / "daily-steward-last-emit"


def last_emit_date(root: Path) -> dt.date | None:
    try:
        return dt.date.fromisoformat(marker_path(root).read_text().strip())
    except (OSError, ValueError):
        return None


def _job_store(root: Path) -> dict:
    """The daily job's record from any jobs.json this profile may run under."""
    candidates = []
    home = os.environ.get("HERMES_HOME")
    if home:
        candidates.append(Path(home) / "cron" / "jobs.json")
    candidates.append(root / "cron" / "jobs.json")
    candidates.extend(sorted((root / "profiles").glob("*/cron/jobs.json")))
    for path in candidates:
        try:
            data = json.loads(path.read_text())
        except (OSError, ValueError):
            continue
        for job in data.get("jobs", []):
            if job.get("name") == DAILY_JOB_NAME:
                return job
    return {}


def delivery_failed(root: Path) -> bool:
    """True when the daily job's most recent run recorded a delivery error.

    A catch-up that fires before the SimpleX daemons finish starting after a
    power-on fails delivery and would otherwise consume the day, so the report
    is silently lost. A recorded delivery error keeps the day eligible for a
    later manual or catch-up fire.
    """
    return bool(_job_store(root).get("last_delivery_error"))


def in_window(now: dt.datetime) -> bool:
    return START_HOUR <= now.hour < END_HOUR


def should_emit(now: dt.datetime, last: dt.date | None, undelivered: bool = False) -> bool:
    """True when this fire is the day's report: inside the window, not already sent.

    07:00 is the only scheduled slot, so a marker dated today means the report
    already went out (on schedule or as an earlier catch-up) and a second run
    would be a duplicate. An older or absent marker with the clock inside the
    window is exactly the missed-run catch-up. Calendar-day freshness keeps a
    same-day duplicate out without skipping a scheduled 07:00 run whose previous
    catch-up landed late the day before. ``undelivered`` re-opens a day whose
    report was generated but whose delivery failed, so the transport coming up a
    few minutes late does not cost the owner the report.
    """
    return in_window(now) and (last != now.date() or undelivered)


def record_emit(root: Path, now: dt.datetime) -> None:
    path = marker_path(root)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(now.date().isoformat() + "\n")


def load_collector(name: str):
    path = Path(__file__).resolve().with_name(name)
    module_name = name[:-3].replace("-", "_")
    spec = importlib.util.spec_from_file_location(module_name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main() -> None:
    root = hermes_root()
    now = dt.datetime.now()
    if not should_emit(now, last_emit_date(root), delivery_failed(root)):
        reason = (f"outside {START_HOUR:02d}:00-{END_HOUR:02d}:00"
                  if not in_window(now) else "already reported today")
        print(f"daily-steward-window: {reason}; skipping (next scheduled 07:00)")
        print(json.dumps({"wakeAgent": False}))
        return
    # Board snapshot first, then usage pace and the local performance cohort.
    # The last line stays report content, never the wake gate.
    for name in COLLECTORS:
        load_collector(name).main()
    record_emit(root, now)


if __name__ == "__main__":
    main()
