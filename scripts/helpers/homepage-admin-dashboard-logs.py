#!/usr/bin/env python3
"""Collect a bounded metadata-only projection of selected journald errors.

This small systemd helper uses Python's standard library for subprocess deadlines,
JSON projection and atomic publication, alongside the existing shell collectors;
it does not add a backend service or a separately packaged Rust application.
"""

import argparse
import datetime as dt
import json
import os
import selectors
import signal
import subprocess
import tempfile
import time
from pathlib import Path
from typing import Any

SAFE_MESSAGE = "Journal error event; message withheld"
MAX_STDOUT = 256 * 1024
MAX_RECORD = 8 * 1024
MAX_RECORDS = 101
MAX_CACHE = 128 * 1024
TIMEOUT_SECONDS = 5

UNITS = {
    "homepage": ("Homepage", "homepage.service"),
    "service-access-canary": ("Service access canary", "homepage-canary.service"),
    "offsite-backup": ("Offsite backup", "rclone-mega-kopia-sync.service"),
}


class InvalidRecord(ValueError):
    pass


class CollectionError(RuntimeError):
    pass


def load_manifest(value: Any) -> dict[str, Any]:
    if not isinstance(value, dict) or value.get("schemaVersion") != 1 or not isinstance(value.get("units"), list):
        raise ValueError("invalid manifest")
    if len(value["units"]) > 3:
        raise ValueError("invalid manifest")
    seen: set[str] = set()
    units = []
    for entry in value["units"]:
        if not isinstance(entry, dict):
            raise ValueError("invalid manifest")
        unit_id = entry.get("id")
        if not isinstance(unit_id, str) or set(entry) != {"id", "label", "unit"}:
            raise ValueError("invalid manifest")
        expected = UNITS.get(unit_id)
        if expected is None or (entry.get("label"), entry.get("unit")) != (expected[0], expected[1]) or unit_id in seen:
            raise ValueError("invalid manifest")
        seen.add(unit_id)
        units.append({"id": unit_id, "label": expected[0], "unit": expected[1]})
    if not {"homepage", "service-access-canary"}.issubset(seen):
        raise ValueError("invalid manifest")
    return {"schemaVersion": 1, "units": units}


def iso_from_microseconds(value: int) -> str:
    seconds, micros = divmod(value, 1_000_000)
    stamp = dt.datetime.fromtimestamp(seconds, tz=dt.timezone.utc).replace(microsecond=micros)
    return stamp.strftime("%Y-%m-%dT%H:%M:%S.%fZ")


def parse_record(raw: str, unit: str) -> dict[str, Any]:
    if len(raw.encode("utf-8")) > MAX_RECORD:
        raise InvalidRecord("record-too-large")
    try:
        value = json.loads(raw)
        timestamp = value.get("__REALTIME_TIMESTAMP")
        priority = value.get("PRIORITY")
        trusted_unit = value.get("_SYSTEMD_UNIT")
        if not isinstance(timestamp, str) or not timestamp.isdecimal():
            raise ValueError
        timestamp_us = int(timestamp)
        if timestamp_us < 0 or timestamp_us > 253402300799999999:
            raise ValueError
        if not isinstance(priority, str) or not priority.isdecimal() or int(priority) not in range(4):
            raise ValueError
        if trusted_unit != unit:
            raise ValueError
        return {"timestamp": iso_from_microseconds(timestamp_us), "priority": int(priority), "message": SAFE_MESSAGE}
    except (AttributeError, OverflowError, TypeError, ValueError):
        raise InvalidRecord("invalid-metadata") from None


def _read_child(argv: list[str]) -> bytes:
    child = subprocess.Popen(
        argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        close_fds=True, start_new_session=True,
    )
    assert child.stdout is not None and child.stderr is not None
    selector = selectors.DefaultSelector()
    selector.register(child.stdout, selectors.EVENT_READ, "stdout")
    selector.register(child.stderr, selectors.EVENT_READ, "stderr")
    output = bytearray()
    deadline = time.monotonic() + TIMEOUT_SECONDS
    failure: str | None = None
    try:
        while selector.get_map():
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                failure = "timeout"
                break
            for key, _ in selector.select(remaining):
                if key.data == "stdout":
                    remaining_stdout = MAX_STDOUT + 1 - len(output)
                    chunk = os.read(key.fd, min(8192, remaining_stdout))
                    output.extend(chunk)
                    if len(output) > MAX_STDOUT:
                        failure = "output-too-large"
                        break
                else:
                    chunk = os.read(key.fd, 8192)
                if not chunk:
                    selector.unregister(key.fileobj)
                    key.fileobj.close()
                    continue
            if failure:
                break
        if failure:
            os.killpg(child.pid, signal.SIGKILL)
        try:
            code = child.wait(timeout=max(0.01, deadline - time.monotonic()))
        except subprocess.TimeoutExpired:
            os.killpg(child.pid, signal.SIGKILL)
            code = child.wait()
            failure = failure or "timeout"
        if code != 0:
            failure = failure or "collector-failed"
        if failure:
            raise CollectionError(failure)
        return bytes(output)
    finally:
        selector.close()
        if child.poll() is None:
            os.killpg(child.pid, signal.SIGKILL)
            child.wait()
        for stream in (child.stdout, child.stderr):
            if not stream.closed:
                stream.close()


def _timestamp_microseconds(value: str) -> int:
    stamp = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    delta = stamp - dt.datetime(1970, 1, 1, tzinfo=dt.timezone.utc)
    return (delta.days * 86400 + delta.seconds) * 1_000_000 + delta.microseconds


def _collect_unit(unit: dict[str, str], journalctl: str, start: int, end: int) -> dict[str, Any]:
    name = unit["unit"]
    argv = [
        journalctl, f"--since=@{start}", f"--until=@{end}", "--priority=0..3",
        "--reverse", "--lines=101", "--no-pager", "--output=json",
        "--output-fields=__REALTIME_TIMESTAMP,PRIORITY,_SYSTEMD_UNIT",
        f"_SYSTEMD_UNIT={name}",
    ]
    try:
        output = _read_child(argv)
        if output and not output.endswith(b"\n"):
            raise InvalidRecord("invalid-output")
        lines = output.splitlines()
        if len(lines) > MAX_RECORDS or any(len(line) > MAX_RECORD for line in lines):
            raise InvalidRecord("invalid-output")
        entries = [parse_record(line.decode("utf-8", "strict"), name) for line in lines]
        indexed = list(enumerate(entries))
        indexed.sort(key=lambda pair: (-_timestamp_microseconds(pair[1]["timestamp"]), pair[1]["priority"], pair[0]))
        return {
            "unit": name, "state": "available", "reasonCode": None,
            "truncated": len(entries) > 100, "entries": [entry for _, entry in indexed[:100]],
        }
    except InvalidRecord:
        return {"unit": name, "state": "invalid", "reasonCode": "observation-invalid", "truncated": False, "entries": []}
    except CollectionError as error:
        reason = error.args[0] if error.args and error.args[0] in {
            "timeout", "output-too-large", "collector-failed", "invalid-output",
        } else "collector-unavailable"
        return {"unit": name, "state": "unavailable", "reasonCode": reason, "truncated": False, "entries": []}
    except (UnicodeDecodeError, OSError):
        return {"unit": name, "state": "unavailable", "reasonCode": "collector-unavailable", "truncated": False, "entries": []}


def collect(manifest: Any, journalctl: str, output: Path | str, now_us: int | None = None) -> dict[str, Any]:
    fixed_manifest = load_manifest(manifest)
    now_us = time.time_ns() // 1000 if now_us is None else now_us
    if type(now_us) is not int or now_us < 0:
        raise ValueError("invalid clock")
    now_seconds = now_us // 1_000_000
    generated_at = iso_from_microseconds(now_us)
    units = [_collect_unit(unit, journalctl, now_seconds - 86400, now_seconds) for unit in fixed_manifest["units"]]
    report = {"schemaVersion": 1, "generatedAt": generated_at, "horizonSeconds": 86400, "units": units}
    encoded = (json.dumps(report, separators=(",", ":"), ensure_ascii=False) + "\n").encode("utf-8")
    if len(encoded) > MAX_CACHE:
        raise CollectionError("cache-too-large")
    destination = Path(output)
    if destination.is_symlink() or (destination.exists() and not destination.is_file()):
        raise CollectionError("invalid-target")
    temporary: str | None = None
    try:
        fd, temporary = tempfile.mkstemp(prefix=".logs.", dir=destination.parent)
        with os.fdopen(fd, "wb") as stream:
            stream.write(encoded)
            stream.flush()
            if os.geteuid() == 0:
                os.fchown(stream.fileno(), 0, -1)
            os.fchmod(stream.fileno(), 0o640)
            os.fsync(stream.fileno())
        os.replace(temporary, destination)
        temporary = None
        return report
    finally:
        if temporary is not None:
            try:
                os.unlink(temporary)
            except FileNotFoundError:
                pass


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--journalctl", required=True)
    args = parser.parse_args()
    try:
        manifest = json.loads(Path(args.manifest).read_text(encoding="utf-8"))
        collect(manifest, args.journalctl, args.output)
    except Exception:
        print("homepage-admin-dashboard-logs: collection-unavailable")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
