#!/usr/bin/env python3
"""Run the virtual-logger scenarios (see README.md).

Each scenario gets a fresh Stack (PostgreSQL, Mosquitto, groundwater-server)
under one scratch directory, which is removed at the end unless --keep.
A scenario marked xfail=<finding id> documents a known defect: its failure
is reported as XFAIL, a pass as XPASS (the defect is gone: drop the mark).
"""

import argparse
import datetime as dt
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile
import time
import traceback

sys.path.insert(0, str(Path(__file__).resolve().parent))
import harness  # noqa: E402
import scenarios  # noqa: E402


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--firmware", default=os.environ.get("GWL_FIRMWARE_DIR"),
                        help="firmware project dir (.../GWL_Firmware_V2.1/GWL_Firmware_V2.1), read only")
    parser.add_argument("--server-bin", default=str(harness.REPO / "custom_apps/target/debug/groundwater-server"))
    parser.add_argument("--only", nargs="*", help="scenario names (default: all)")
    parser.add_argument("--list", action="store_true")
    parser.add_argument("--keep", action="store_true", help="keep the scratch directory")
    parser.add_argument("--out", help="write results.json / results.md here")
    args = parser.parse_args()

    if args.list:
        for sc in scenarios.SCENARIOS:
            print(f"{sc.name:28} {sc.xfail or '':10} {sc.doc}")
        return 0
    if not args.firmware:
        parser.error("--firmware or GWL_FIRMWARE_DIR is required")
    selected = [sc for sc in scenarios.SCENARIOS if not args.only or sc.name in args.only]
    if args.only and len(selected) != len(args.only):
        parser.error(f"unknown scenario in {args.only}")

    scratch = Path(tempfile.mkdtemp(prefix="gwl-vlogger-", dir=os.environ.get("TMPDIR")))
    results = []
    try:
        tools = harness.Tools(scratch / "build", args.firmware, args.server_bin)
        for sc in selected:
            root = scratch / sc.name
            started = time.monotonic()
            stack = harness.Stack(tools, root, sc.server_env)
            status, detail = "PASS", ""
            try:
                try:
                    stack.start()
                except Exception:  # noqa: BLE001 - the stack, not the scenario
                    raise RuntimeError("stack start failed:\n" + traceback.format_exc(limit=4))
                sc.fn(stack)
            except (harness.ScenarioFailure, harness.LoggerExited) as err:
                status, detail = "FAIL", f"{type(err).__name__}: {err}"
            except Exception:  # noqa: BLE001 - report harness errors as failures too
                status, detail = "ERROR", traceback.format_exc(limit=6)
            finally:
                stack.stop()
            if sc.xfail and status == "FAIL":
                status = "XFAIL"
            elif sc.xfail and status == "PASS":
                status = "XPASS"
            took = time.monotonic() - started
            results.append({"name": sc.name, "status": status, "xfail": sc.xfail, "seconds": round(took, 1),
                            "detail": detail, "dir": str(root)})
            print(f"{status:6} {sc.name:28} {took:6.1f}s {sc.xfail or ''}", flush=True)
            if detail:
                print("       " + detail.replace("\n", "\n       "), flush=True)
        if args.out:
            write_results(Path(args.out), results, scratch, args.keep)
    finally:
        if args.keep:
            print(f"scratch kept: {scratch}")
        else:
            shutil.rmtree(scratch, ignore_errors=True)
    bad = [r for r in results if r["status"] in ("FAIL", "ERROR", "XPASS")]
    return 1 if bad else 0


def write_results(out, results, scratch, keep):
    out.mkdir(parents=True, exist_ok=True)
    (out / "results.json").write_text(json.dumps(results, indent=2))
    lines = [f"# Virtual logger run {dt.datetime.now(dt.timezone.utc):%Y-%m-%d %H:%M} UTC", "",
             "| Scenario | Result | Finding | Time |", "|---|---|---|---|"]
    for r in results:
        lines.append(f"| {r['name']} | {r['status']} | {r['xfail'] or ''} | {r['seconds']} s |")
    for r in results:
        if r["detail"]:
            lines += ["", f"## {r['name']}: {r['status']}", "", "```", r["detail"].strip(), "```"]
    (out / "results.md").write_text("\n".join(lines) + "\n")
    # transcripts of every scenario (small): the exact payloads exchanged
    for r in results:
        src = Path(r["dir"])
        dst = out / r["name"]
        dst.mkdir(exist_ok=True)
        for f in list(src.glob("*/transcript.jsonl")) + list(src.glob("*/firmware.log")) + [src / "server.log"]:
            if f.exists():
                name = f.name if f.parent == src else f"{f.parent.name}-{f.name}"
                shutil.copy(f, dst / name)


if __name__ == "__main__":
    sys.exit(main())
