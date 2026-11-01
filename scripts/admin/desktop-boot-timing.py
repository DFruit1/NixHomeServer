#!/usr/bin/env python3
"""Record Void/runit boot milestones with Python's standard library only.

Python keeps /proc parsing and persistent JSON reports small; this is a local
operator tool, not a new backend service. All times are seconds since Linux boot.
"""

import argparse
import json
import os
from pathlib import Path
import re
import sys
import time


STATE = Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local/state")) / "desktop-boot-timing"
BOOT_ID = Path("/proc/sys/kernel/random/boot_id").read_text().strip()
CURRENT = STATE / BOOT_ID


def load(path):
    return json.loads(path.read_text()) if path.exists() else {}


def process_starts():
    names = {"runsvdir", "greetd", "niri", "noctalia", "T3-Code.AppImag", "t3code"}
    starts = {}
    for proc in Path("/proc").glob("[0-9]*"):
        try:
            stat = (proc / "stat").read_text()
            name = stat[stat.index("(") + 1:stat.rindex(")")]
            if name in names:
                # Fields after the final ')' start at field 3; starttime is 22.
                seconds = int(stat[stat.rindex(")") + 2:].split()[19]) / os.sysconf("SC_CLK_TCK")
                starts[name] = min(seconds, starts.get(name, seconds))
        except (OSError, ValueError, IndexError):
            continue  # Processes can exit while /proc is being read.
    return starts


def report():
    CURRENT.mkdir(parents=True, exist_ok=True)
    data = {"boot_id": BOOT_ID, "process_starts": process_starts()}
    core = Path("/run/desktop-boot-timing")
    if core.exists():
        lines = dict(line.split() for line in core.read_text().splitlines())
        if lines.pop("boot_id", None) == BOOT_ID:
            data.update({key: float(value) for key, value in lines.items()})
    for marker in ("session-spawn", "ready"):
        data.update(load(CURRENT / f"{marker}.json"))
    if "core-start" in data and "core-end" in data:
        data["core-duration"] = data["core-end"] - data["core-start"]
    (CURRENT / "report.json").write_text(json.dumps(data, indent=2) + "\n")
    print(f"Boot: {BOOT_ID}\nSeconds since Linux boot (firmware and GRUB excluded):")
    for key, label in (
        ("core-start", "Runit core hooks begin, after pseudo-filesystems"),
        ("core-end", "Runit core hooks end, before boot-log cleanup"),
        ("core-duration", "Measured core initialization duration"),
        ("session-spawn", "Niri dispatched the session marker"),
        ("ready", "Manually marked desktop ready"),
    ):
        value = f"{data[key]:.2f}s" if key in data else "not recorded"
        print(f"  {label}: {value}")
    print("Live process starts (restarts replace the original process):")
    for name, seconds in sorted(data["process_starts"].items(), key=lambda item: item[1]):
        print(f"  {name}: {seconds:.2f}s")
    print(f"Saved: {CURRENT / 'report.json'}")
    print("Session dispatch and process creation do not prove application readiness.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("report", "mark-session", "mark-ready", "history", "kernel-gaps"), nargs="?", default="report")
    args = parser.parse_args()
    if args.command == "kernel-gaps":
        previous = 0.0
        gaps = []
        for line in sys.stdin:
            match = re.match(r"\[\s*(\d+\.\d+)\]\s*(.*)", line)
            if match:
                seconds = float(match[1])
                if seconds <= 120:
                    gaps.append((seconds - previous, seconds, match[2]))
                previous = seconds
        print("Largest kernel-log gaps in the first 120s; the following message is not necessarily the cause:")
        for gap, seconds, message in sorted(gaps, reverse=True)[:10]:
            print(f"  {gap:7.3f}s gap, ending at {seconds:8.3f}s: {message}")
    elif args.command == "history":
        for path in sorted(STATE.glob("*/report.json"), key=lambda item: item.stat().st_mtime):
            data = load(path)
            values = ", ".join(f"{key}={data[key]:.2f}s" for key in ("core-duration", "session-spawn", "ready") if key in data)
            print(f"{data['boot_id']}: {values or 'live process snapshot only'}")
    else:
        if args.command.startswith("mark-"):
            seconds = time.clock_gettime(time.CLOCK_BOOTTIME)
            marker = "session-spawn" if args.command == "mark-session" else "ready"
            CURRENT.mkdir(parents=True, exist_ok=True)
            try:
                with (CURRENT / f"{marker}.json").open("x") as output:
                    json.dump({marker: seconds}, output)
            except FileExistsError:
                pass  # Preserve the first marker across compositor restarts.
        report()


if __name__ == "__main__":
    main()
