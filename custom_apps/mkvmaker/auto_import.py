#!/usr/bin/env python3
"""Unattended, restart-safe DVD ISO ingestion for disc-to-jellyfin."""

from __future__ import annotations

import argparse
import collections
import difflib
import errno
import fcntl
import hashlib
import json
import os
import pwd
import re
import secrets
import signal
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse
import urllib.request
from dataclasses import dataclass
from contextlib import contextmanager
from pathlib import Path
from typing import Any


STATE_VERSION = 2
TVMAZE_API = "https://api.tvmaze.com"
USER_AGENT = "NixHomeServer-mkvmaker/1.0 (automated personal media metadata lookup)"
shutdown_signal: int | None = None


class ShutdownRequested(Exception):
    """The supervisor was asked to stop without charging a job retry."""


class LeaseLost(Exception):
    """The worker no longer owns the queue item it was processing."""


class InvalidQueueState(RuntimeError):
    """Durable queue metadata could not be read safely."""


class SourceChanged(RuntimeError):
    """The claimed ISO pathname no longer identifies the same file."""


class ConverterFailed(RuntimeError):
    """disc-to-jellyfin exited unsuccessfully; carries its own error lines."""

    def __init__(self, return_code: int, errors: list[str], output_tail: list[str]) -> None:
        self.return_code = return_code
        self.errors = errors
        self.output_tail = output_tail
        super().__init__(errors[0] if errors else f"converter exited with status {return_code}")


RETRY_HINT = "then move the ISO from _ISO/_DVDs/_Failed back into _ISO/_DVDs to try again."
# Converter and planner messages, matched against the first reported error,
# translated into what went wrong and what the owner can do about it.
FAILURE_EXPLANATIONS: list[tuple[re.Pattern[str], str, str]] = [
    (
        re.compile(r"output belongs to a different source or encode configuration: (?P<path>.+)"),
        "The destination already holds a different conversion.",
        "{path} was made from another ISO or with other encode settings. Rename this ISO "
        "so it gets its own title, or move the existing folder away, " + RETRY_HINT,
    ),
    (
        re.compile(r"existing output failed validation; move or delete it: (?P<path>.+)"),
        "An unfinished earlier attempt is in the way.",
        "Move or delete {path}, " + RETRY_HINT,
    ),
    (
        re.compile(r"output exists without a readable matching manifest: (?P<path>.+)"),
        "A file the converter did not create already exists at the destination.",
        "Move or rename {path}, " + RETRY_HINT,
    ),
    (
        re.compile(r"another process is working on (?P<path>.+)"),
        "Another conversion was writing the same file at the same time.",
        "Wait for the other conversion to finish, " + RETRY_HINT,
    ),
    (
        re.compile(r"not enough free space"),
        "There is not enough free disk space for this conversion.",
        "Free up space on the media drive, " + RETRY_HINT,
    ),
    (
        re.compile(r"HandBrake failed|HandBrake scan failed|HandBrake produced no title-set|HandBrake title-set JSON"),
        "HandBrake could not read or encode this disc.",
        "The disc image may be damaged or copy-protected. Re-rip the disc, " + RETRY_HINT,
    ),
    (
        re.compile(r"output validation failed"),
        "The finished video failed its playback check.",
        "The disc image may be damaged. Re-rip the disc, " + RETRY_HINT,
    ),
    (
        re.compile(r"deadline"),
        "The conversion stalled and was stopped.",
        "The disc image may be damaged or unusually long. Check the details below, " + RETRY_HINT,
    ),
    (
        re.compile(r"no titles at least|No DVD titles selected|declares \d+ episodes"),
        "No suitable videos were found on the disc.",
        "Check that the ISO is a complete video DVD, or rename it to say how many "
        "episodes it holds, " + RETRY_HINT,
    ),
    (
        re.compile(r"Duplicate check unavailable"),
        "Could not check whether this disc was already converted.",
        "Check that _ISO/_DVDs/_Processed is readable, " + RETRY_HINT,
    ),
]


def display_path(root: Path, path: str) -> str:
    """Show a shared-storage path relative to the share, as the file browser does."""
    try:
        shared = Path(os.path.commonpath([str(root), path]))
        relative = Path(path).relative_to(shared)
    except ValueError:
        return path
    return str(relative) if str(relative) != "." else path


def explain_failure(error: BaseException, shared_root: Path) -> dict[str, str]:
    """Return the owner-facing summary, next step, and technical details."""
    reason = str(error).strip() or type(error).__name__
    if isinstance(error, ConverterFailed):
        details = "\n".join(error.output_tail).strip() or reason
    else:
        details = reason
    for pattern, summary, hint in FAILURE_EXPLANATIONS:
        match = pattern.search(reason)
        if match:
            path = match.groupdict().get("path")
            if path:
                hint = hint.format(path=display_path(shared_root, path.strip()))
            return {"summary": summary, "hint": hint[0].upper() + hint[1:], "details": details}
    first = reason.splitlines()[0][:300]
    return {
        "summary": first[0].upper() + first[1:] if first else "The conversion failed.",
        "hint": "Check the details below, " + RETRY_HINT,
        "details": details,
    }


def write_failure_report(
    archived: Path, error: BaseException, attempts: int, shared_root: Path
) -> None:
    report = explain_failure(error, shared_root)
    archived.with_suffix(".iso.error.txt").write_text(
        f"{report['summary']}\n{report['hint']}\n\nDetails:\n{report['details']}\n",
        encoding="utf-8",
    )
    atomic_json(
        archived.with_suffix(".iso.error.json"),
        {**report, "attempts": attempts, "failedAt": int(time.time())},
    )


FAILURE_REPORT_SUFFIX = ".iso.error.txt"


def prune_orphaned_failure_reports(failed_dir: Path) -> None:
    """Drop ``X.iso.error.txt`` reports in _Failed whose ISO has left it.

    A person retries a failure by moving its ISO out; the report then
    describes nothing. Reports are written after their ISO is archived, so a
    report without its ISO is never one being written. Nothing else is
    touched: not ISOs, links, structured reports, or other files.
    """
    try:
        entries = list(failed_dir.iterdir())
    except OSError:
        return
    isos = {entry.name[:-4].casefold() for entry in entries if entry.name.casefold().endswith(".iso")}
    for entry in entries:
        if not entry.name.endswith(FAILURE_REPORT_SUFFIX) or entry.is_symlink() or not entry.is_file():
            continue
        stem = entry.name[:-len(FAILURE_REPORT_SUFFIX)]
        # Re-checked: the listing is not atomic with an ISO arriving.
        if stem.casefold() in isos or any(
                (failed_dir / f"{stem}{suffix}").exists() for suffix in (".iso", ".ISO")):
            continue
        try:
            entry.unlink()
        except OSError as error:
            print(f"Could not remove stale failure report {entry}: {error}", file=sys.stderr)
        else:
            print(f"Removed stale failure report {entry.name}; its ISO is no longer in {failed_dir}")


def request_shutdown(signum: int, _frame: Any) -> None:
    global shutdown_signal
    shutdown_signal = signum


@dataclass(frozen=True)
class Title:
    index: int
    seconds: int
    main_feature: bool
    # Display aspect ratio (1.33 for 4:3, 1.78 for 16:9) when HandBrake reports it.
    aspect: float | None = None


@dataclass(frozen=True)
class SourceHints:
    name: str
    year: int | None
    season: int | None
    episode: int | None
    last_episode: int | None
    disc: int | None
    provider: str | None = None
    is_jellyfin_named: bool = False
    trailing_series: int | None = None


_ROMAN_VALUES = {"i": 1, "v": 5, "x": 10, "l": 50, "c": 100, "d": 500, "m": 1000}
_CANONICAL_ROMAN_1_TO_30_RE = re.compile(r"(?i)^X{0,3}(?:IX|IV|V?I{0,3})$")


def _roman_to_int(token: str) -> int | None:
    """Return the Arabic value of a Roman-numeral token (1..30) or None.

    Non-canonical tokens and letter mixes that are not Roman numerals (e.g.
    ``IIV`` or ``matrix``) return
    ``None`` instead of being mis-parsed.
    """
    roman = token.casefold()
    if not roman or _CANONICAL_ROMAN_1_TO_30_RE.fullmatch(roman) is None:
        return None
    total = 0
    previous = 0
    for ch in reversed(roman):
        current = _ROMAN_VALUES[ch]
        total += current if current >= previous else -current
        previous = current
    return total if 1 <= total <= 30 else None


_PROVIDER_RE = re.compile(
    r"(?i)\[(?P<provider>tvdbid|tmdbid|imdbid)-(?P<value>[A-Za-z0-9]+)\]"
)
_PARENS_YEAR_RE = re.compile(r"\((?P<year>(?:19|20)\d{2})\)")
_BARE_YEAR_RE = re.compile(r"(?<!\d)(?P<year>(?:19|20)\d{2})(?!\d)")
_SERIES_PREFIX_RE = re.compile(
    r"(?i)(?:^|[^a-z0-9])(?:series|season|vol(?:ume)?)[ ._-]+"
    r"(?:(?P<roman>[ivxlcdm]+)|0*(?P<arabic>\d{1,2}))(?:[^a-z0-9]|$)"
)
_SEASON_RE = re.compile(r"(?i)(?:^|[^a-z0-9])(?:s|season)[ ._-]*0*(\d{1,2})(?:e\d+)?")
_EPISODE_RE = re.compile(r"(?i)(?:^|[^a-z0-9])s\d{1,2}[ ._-]*e0*(\d{1,3})")
_EPISODE_RANGE_RE = re.compile(
    r"(?i)(?:^|[^a-z0-9])s0*(\d{1,2})[ ._-]*e0*(\d{1,3})"
    r"(?:[ ._]*-[ ._]*|[ ._]+to[ ._]+)e?0*(\d{1,3})(?:[^a-z0-9]|$)"
)
_DISC_RE = re.compile(
    r"(?i)(?:^|[^a-z0-9])(?:disc|disk|dvd)[ ._-]*0*(\d{1,2})(?:[^a-z0-9]|$)"
)
_TRAILING_NUMERAL_RE = re.compile(r"(?i)\s(?P<token>[ivxlcdm]+|\d{1,2})$")
# The desktop ripper names repeat captures of one volume label
# ``LABEL_20261114-155933`` or ``LABEL_20261114-162720_1TbgkU``. The stamp
# says when the disc was read; it is never part of the programme's name.
_RIPPER_SUFFIX_RE = re.compile(r"_\d{8}-\d{6}(?:_[A-Za-z0-9]{6})?$")


def parse_provider(text: str) -> str | None:
    match = _PROVIDER_RE.search(text)
    if not match:
        return None
    return f"{match.group('provider').lower()}-{match.group('value')}"


def strip_jellyfin_suffix(name: str) -> str:
    """Drop Jellyfin ``(Year)`` and ``[provider-id]`` suffixes for similarity matching."""
    out = re.sub(r"\s*\[(?:tvdbid|tmdbid|imdbid)-[A-Za-z0-9]+\]\s*$", "", name)
    out = re.sub(r"\s*\((?:19|20)\d{2}\)\s*$", "", out)
    return out.strip()


def parse_jellyfin_folder(name: str) -> tuple[str, int | None, str | None]:
    base = strip_jellyfin_suffix(name)
    year_match = _PARENS_YEAR_RE.search(name)
    year = int(year_match.group("year")) if year_match else None
    return base, year, parse_provider(name)


def detect_season(stem: str) -> tuple[int | None, int | None, bool]:
    """Return (season, episode, season_from_explicit_marker_or_trailing_token).

    The third value distinguishes an explicit Jellyfin-style season signal from
    the bare trailing-numeral fallback so callers can flag filename conformance.
    """
    season = episode = None
    explicit_marker = False
    season_match = _SEASON_RE.search(stem)
    if season_match:
        candidate = int(season_match.group(1))
        # Season 0 holds Jellyfin specials; only an explicit S00Exx names it.
        if 1 <= candidate <= 99 or (
            candidate == 0 and re.search(r"(?i)e\d", season_match.group(0))
        ):
            season = candidate
            explicit_marker = True
    if season is None:
        series_match = _SERIES_PREFIX_RE.search(stem)
        if series_match:
            if series_match.group("roman"):
                value = _roman_to_int(series_match.group("roman"))
            else:
                value = int(series_match.group("arabic"))
            if value is not None and 1 <= value <= 30:
                season = value
                explicit_marker = True
    episode_match = _EPISODE_RE.search(stem)
    if episode_match:
        episode = int(episode_match.group(1))
        explicit_marker = True
    return season, episode, explicit_marker


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input-dir", type=Path, required=True)
    parser.add_argument("--movies-dir", type=Path, required=True)
    parser.add_argument("--shows-dir", type=Path, required=True)
    parser.add_argument("--state-dir", type=Path, required=True)
    parser.add_argument("--progress-file", type=Path)
    parser.add_argument("--converter", required=True)
    parser.add_argument("--staging-dir", type=Path, help="Write partial MKVs here instead of inside the Jellyfin library.")
    parser.add_argument("--handbrake", default=os.environ.get("DISC_TO_JELLYFIN_HANDBRAKE", "HandBrakeCLI"))
    parser.add_argument("--settle-seconds", type=int, default=60)
    parser.add_argument("--min-duration", type=int, default=300)
    parser.add_argument("--dominant-ratio", type=float, default=0.85)
    parser.add_argument("--metadata-timeout", type=int, default=10)
    parser.add_argument("--max-attempts", type=int, default=3)
    parser.add_argument("--retry-seconds", type=int, default=900)
    parser.add_argument("--profile", choices=("standard", "compatible", "archive"), default="standard")
    parser.add_argument("--video-preset", choices=("balanced", "compact", "maximum", "fast"), default="balanced")
    parser.add_argument(
        "--worker-id",
        default=os.environ.get("MKVMAKER_WORKER_ID", "local"),
        help="Stable worker name recorded in renewable queue leases.",
    )
    parser.add_argument(
        "--lease-seconds",
        type=int,
        default=120,
        help="Seconds a worker owns an ISO before it must renew its lease.",
    )
    identify = parser.add_argument_group(
        "episode identification",
        "Without --identifier, TV discs keep the older filename/TVmaze numbering.",
    )
    identify.add_argument("--identifier", help="disc-identify executable")
    identify.add_argument("--held-dir", type=Path,
                          help="Holding folder outside the Jellyfin libraries for unidentified episodes.")
    identify.add_argument("--needs-dir", type=Path,
                          help="Where ISOs awaiting identification are kept (default: INPUT/_NeedsIdentification).")
    identify.add_argument("--bonsai-url")
    identify.add_argument("--parakeet")
    identify.add_argument("--parakeet-model")
    identify.add_argument("--subtitle-socket")
    identify.add_argument("--sevenzip", default="7zz")
    identify.add_argument("--ffmpeg", default="ffmpeg")
    identify.add_argument(
        "--max-menu-frames",
        type=int,
        default=32,
        help="Menu frames the identifier may read (its own default is 20; box-set "
             "discs with per-episode submenus need more pages).",
    )
    identify.add_argument("--identify-threads", type=int, default=4)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}", args.worker_id) is None:
        parser.error("--worker-id must be 1-64 safe letters, digits, dot, underscore, or hyphen")
    if args.lease_seconds < 3:
        parser.error("--lease-seconds must be at least 3")
    return args


def atomic_json(path: Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    os.replace(temporary, path)


def load_state(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return {"version": STATE_VERSION, "sources": {}}
    except (json.JSONDecodeError, OSError) as error:
        raise InvalidQueueState(f"cannot read durable queue state {path}: {error}") from error
    if not isinstance(value, dict) or not isinstance(value.get("sources"), dict):
        raise InvalidQueueState(f"durable queue state {path} has an invalid structure")
    version = value.get("version")
    if type(version) is not int or version not in (1, STATE_VERSION):
        raise InvalidQueueState(
            f"durable queue state {path} uses unsupported version {version!r}"
        )
    if "processed_hashes" in value and not isinstance(value["processed_hashes"], dict):
        raise InvalidQueueState(f"durable queue state {path} has invalid processed hashes")
    # Version 2 adds an NFS-backed per-source lock. Preserve version 1 queues
    # in place so an activation never discards existing observations or plans.
    value["version"] = STATE_VERSION
    return value


@contextmanager
def locked_queue(lock_path: Path):
    """Serialize queue metadata updates without serializing conversions."""
    with lock_path.open("a+", encoding="utf-8") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(lock, fcntl.LOCK_UN)


def source_signature(path: Path) -> dict[str, int]:
    stat = path.stat()
    return {
        "size": stat.st_size,
        "mtime_ns": stat.st_mtime_ns,
        "ctime_ns": stat.st_ctime_ns,
    }


def signatures_match(expected: Any, actual: dict[str, int]) -> bool:
    """Accept legacy size/mtime signatures while upgrading them in place."""
    if not isinstance(expected, dict):
        return False
    required = ("size", "mtime_ns")
    if any(type(expected.get(key)) is not int for key in required):
        return False
    return all(actual.get(key) == value for key, value in expected.items())


def ensure_source_unchanged(source: Path, expected: dict[str, Any]) -> None:
    try:
        actual = source_signature(source)
    except OSError as error:
        raise SourceChanged(f"claimed ISO disappeared or became unreadable: {error}") from error
    if not signatures_match(expected, actual) or set(expected) != set(actual):
        raise SourceChanged(f"claimed ISO changed while it was being processed: {source.name}")


def try_source_lock(claims_dir: Path, source_name: str):
    """Take a non-blocking NFSv4 lock that survives wall-clock skew."""
    lock_name = hashlib.sha256(source_name.encode("utf-8")).hexdigest() + ".lock"
    lock = (claims_dir / lock_name).open("a+", encoding="utf-8")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        lock.close()
        return None
    return lock


def release_source_lock(lock: Any) -> None:
    if lock is None:
        return
    try:
        fcntl.flock(lock, fcntl.LOCK_UN)
    finally:
        lock.close()


def lease_owned(entry: dict[str, Any], worker_id: str, lease_id: str) -> bool:
    lease = entry.get("lease")
    return (
        isinstance(lease, dict)
        and lease.get("workerId") == worker_id
        and lease.get("leaseId") == lease_id
    )


def parse_handbrake_json(text: str) -> dict[str, Any]:
    marker = "JSON Title Set:"
    start = text.find(marker)
    if start < 0:
        raise RuntimeError("HandBrake produced no title-set JSON")
    decoder = json.JSONDecoder()
    value, _ = decoder.raw_decode(text[start + len(marker) :].lstrip())
    if not isinstance(value, dict):
        raise RuntimeError("HandBrake title-set JSON is not an object")
    return value


def stop_process_tree(process: subprocess.Popen) -> None:
    # Converter and HandBrake use distinct process groups. Snapshot descendant
    # groups before interruption so escalation still reaches orphaned children.
    groups = {process.pid}
    def collect(pid: int) -> None:
        try:
            children = Path(f"/proc/{pid}/task/{pid}/children").read_text().split()
        except OSError:
            return
        for child in children:
            try:
                group = os.getpgid(int(child))
                if group != os.getpgrp():
                    groups.add(group)
                collect(int(child))
            except ProcessLookupError:
                pass
    collect(process.pid)
    for group in groups:
        try:
            os.killpg(group, signal.SIGINT)
        except ProcessLookupError:
            pass
    try:
        process.wait(timeout=30)
    except subprocess.TimeoutExpired:
        pass
    finally:
        for group in groups:
            try:
                os.killpg(group, signal.SIGKILL)
            except ProcessLookupError:
                pass
        process.wait()


def scan_titles(handbrake: str, source: Path, renew_lease: Any | None = None,
                renew_interval: float = 40) -> list[Title]:
    command = [
        handbrake,
        "--input",
        str(source),
        "--title",
        "0",
        "--min-duration",
        "0",
        "--scan",
        "--json",
    ]
    # HandBrake includes raw DVD volume-label bytes in its diagnostic output.
    # Those labels are not guaranteed to be valid UTF-8, while the JSON title
    # set itself is ASCII/UTF-8. Preserve the scan and replace only malformed
    # diagnostic characters instead of failing the entire queue item.
    with subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          text=True, encoding="utf-8", errors="replace",
                          start_new_session=True) as process:
        try:
            deadline = time.monotonic() + 10 * 60
            renew_after = time.monotonic()
            while True:
                if shutdown_signal is not None:
                    raise ShutdownRequested("shutdown during HandBrake scan")
                if time.monotonic() >= deadline:
                    raise RuntimeError("HandBrake scan exceeded 10-minute deadline")
                if renew_lease is not None and time.monotonic() >= renew_after:
                    if not renew_lease():
                        raise LeaseLost("queue lease was lost during HandBrake scan")
                    renew_after = time.monotonic() + max(1.0, renew_interval)
                try:
                    stdout, stderr = process.communicate(timeout=0.5)
                    break
                except subprocess.TimeoutExpired:
                    continue
        except BaseException:
            stop_process_tree(process)
            raise
        result = subprocess.CompletedProcess(command, process.returncode, stdout, stderr)
    if result.returncode != 0:
        detail = (result.stderr or result.stdout).strip()[-2000:]
        raise RuntimeError(f"HandBrake scan failed ({result.returncode}): {detail}")
    combined = f"{result.stdout}\n{result.stderr}"
    title_set = parse_handbrake_json(combined)
    main = title_set.get("MainFeature")
    titles: list[Title] = []
    for raw in title_set.get("TitleList", []):
        duration = raw.get("Duration") or {}
        seconds = (
            int(duration.get("Hours") or 0) * 3600
            + int(duration.get("Minutes") or 0) * 60
            + int(duration.get("Seconds") or 0)
        )
        index = int(raw.get("Index") or 0)
        if index > 0:
            titles.append(Title(index=index, seconds=seconds, main_feature=index == main,
                                aspect=display_aspect(raw.get("Geometry"))))
    return sorted(titles, key=lambda title: title.index)


def display_aspect(geometry: Any) -> float | None:
    """Display aspect ratio from a HandBrake scan title's Geometry block."""
    if not isinstance(geometry, dict):
        return None
    try:
        width = int(geometry.get("Width") or 0)
        height = int(geometry.get("Height") or 0)
        par = geometry.get("PAR") or {}
        num = int(par.get("Num") or 1)
        den = int(par.get("Den") or 1)
    except (TypeError, ValueError):
        return None
    if width <= 0 or height <= 0 or num <= 0 or den <= 0:
        return None
    return round(width * num / (height * den), 2)


def select_titles(titles: list[Title], minimum: int, dominant_ratio: float) -> tuple[list[Title], bool, float]:
    substantial = [title for title in titles if title.seconds >= minimum]
    if not substantial:
        raise RuntimeError(f"disc has no titles at least {minimum} seconds long")
    longest = max(substantial, key=lambda title: title.seconds)
    total = sum(title.seconds for title in substantial)
    ratio = longest.seconds / total
    if ratio >= dominant_ratio:
        return [longest], True, ratio

    # DVD TV sets often contain a play-all title whose duration is approximately
    # the sum of the individual episodes. Keep the episodes, not the duplicate.
    selected: list[Title] = []
    for title in substantial:
        others = sum(candidate.seconds for candidate in substantial if candidate != title)
        likely_play_all = len(substantial) >= 3 and others > 0 and 0.85 <= title.seconds / others <= 1.15
        if not likely_play_all:
            selected.append(title)
    if not selected:
        selected = substantial
    return selected, False, ratio


def collapse_systematic_duplicate_title_pairs(titles: list[Title]) -> list[Title]:
    """Collapse systematic adjacent duplicate DVD titles.

    Some TV DVDs expose every episode twice as adjacent titles with the exact
    same duration. The entire episode sequence must consist of at least two
    pairs, with at most one unpaired play-all title whose duration approximates
    the sum of the unique episodes. This avoids mutating ordinary discs that
    merely contain incidental equal-runtime titles.
    """
    collapsed: list[Title] = []
    duplicate_pairs = 0
    unique_runtime = 0
    singles: list[Title] = []
    index = 0
    while index < len(titles):
        current = titles[index]
        if index + 1 < len(titles) and current.seconds == titles[index + 1].seconds:
            collapsed.append(current)
            duplicate_pairs += 1
            unique_runtime += current.seconds
            index += 2
        else:
            collapsed.append(current)
            singles.append(current)
            index += 1
    if duplicate_pairs < 2:
        return titles
    if not singles:
        return collapsed
    if len(singles) != 1 or unique_runtime <= 0:
        return titles
    play_all_ratio = singles[0].seconds / unique_runtime
    return collapsed if 0.85 <= play_all_ratio <= 1.15 else titles


def recover_declared_episode_titles(
    titles: list[Title], expected: int
) -> list[Title] | None:
    """Recover an explicit episode range from a mixed composite-title layout.

    Some TV DVDs expose overlapping multi-episode titles alongside the
    individual episodes, then duplicate one individual title. Only use this
    fallback when the filename declares the exact episode count, every retained
    title has an ordinary episode runtime, and collapsing adjacent equal-runtime
    duplicates produces exactly that count. Otherwise the caller still fails
    closed.
    """
    episode_sized = [
        title for title in titles if 8 * 60 <= title.seconds <= 75 * 60
    ]
    recovered: list[Title] = []
    for title in episode_sized:
        if (
            recovered
            and title.index == recovered[-1].index + 1
            and title.seconds == recovered[-1].seconds
        ):
            continue
        recovered.append(title)
    return recovered if len(recovered) == expected else None


def prepare_titles(
    titles: list[Title],
    hints: SourceHints,
    minimum: int,
    dominant_ratio: float,
    *,
    allow_trailing_tv: bool = False,
) -> tuple[list[Title], bool, float]:
    """Apply TV-safe duplicate filtering, play-all filtering, and range validation."""
    substantial = [title for title in titles if title.seconds >= minimum]
    if not substantial:
        raise RuntimeError(f"disc has no titles at least {minimum} seconds long")
    explicit_tv = hints.season is not None or hints.episode is not None
    if explicit_tv:
        candidates = collapse_systematic_duplicate_title_pairs(substantial)
    elif hints.trailing_series is not None and allow_trailing_tv:
        candidates = collapse_systematic_duplicate_title_pairs(substantial)
    else:
        candidates = substantial
    selected, dominant, ratio = select_titles(candidates, minimum, dominant_ratio)
    if hints.episode is not None and hints.last_episode is not None:
        expected = hints.last_episode - hints.episode + 1
        if len(selected) != expected:
            recovered = recover_declared_episode_titles(substantial, expected)
            if recovered is not None:
                selected = recovered
                dominant = False
        if len(selected) != expected:
            raise RuntimeError(
                f"ISO filename declares {expected} episodes "
                f"(E{hints.episode:02d}-E{hints.last_episode:02d}), "
                f"but DVD title filtering found {len(selected)}"
            )
    return selected, dominant, ratio


def looks_like_episode_set(titles: list[Title]) -> bool:
    # Two similar episode-length titles are already a TV disc (many box sets
    # hold two 50-minute episodes per disc); a film is longer than 75 minutes.
    if len(titles) < 2:
        return False
    durations = [title.seconds for title in titles]
    shortest = min(durations)
    longest = max(durations)
    return 8 * 60 <= shortest and longest <= 75 * 60 and longest / shortest <= 1.5


def episode_core(titles: list[Title]) -> list[Title] | None:
    """Episode-length titles of a disc that also carries short extras.

    ``ALL_CREATURES_GREAT_AND_SMALL.iso`` (2026-11-17) held two 54-minute
    episodes and 9- and 5-minute extras; the extras broke
    ``looks_like_episode_set`` and the disc was filed as a film. Returns the
    episodes when at least two similar episode-length titles exist and every
    other title is clearly shorter (under 35% of the longest episode).
    """
    if not titles:
        return None
    longest = max(title.seconds for title in titles)
    core = [title for title in titles
            if title.seconds >= 0.6 * longest and 8 * 60 <= title.seconds <= 75 * 60]
    rest = [title for title in titles if title not in core]
    if len(core) < 2 or not rest or not looks_like_episode_set(core):
        return None
    if any(title.seconds >= 0.35 * longest for title in rest):
        return None
    return core


def source_hints(path: Path) -> SourceHints:
    stem = _RIPPER_SUFFIX_RE.sub("", path.stem)
    parens_year = _PARENS_YEAR_RE.search(stem)
    bare_year = _BARE_YEAR_RE.search(stem)
    year = int(parens_year.group("year")) if parens_year else (
        int(bare_year.group("year")) if bare_year else None
    )
    provider = parse_provider(stem)
    season, episode, explicit_season = detect_season(stem)
    range_match = _EPISODE_RANGE_RE.search(stem)
    last_episode = int(range_match.group(3)) if range_match else None
    if last_episode is not None and episode is not None and last_episode < episode:
        raise ValueError(
            f"reversed episode range E{episode:02d}-E{last_episode:02d} in {path.name}"
        )
    disc_match = _DISC_RE.search(stem)
    disc = int(disc_match.group(1)) if disc_match else None

    cleaned = stem.replace("_", " ").replace(".", " ")
    cleaned = re.sub(r"(?i)\[(?:tvdbid|tmdbid|imdbid)-[A-Za-z0-9]+\]", " ", cleaned)
    cleaned = re.sub(r"\((?:19|20)\d{2}\)", " ", cleaned)
    cleaned = re.sub(
        r"(?i)\bs\d{1,2}[ ._-]*e\d{1,3}"
        r"(?:(?:[ ._]*-[ ._]*|[ ._]+to[ ._]+)e?\d{1,3})?\b",
        " ",
        cleaned,
    )
    cleaned = re.sub(r"(?i)\bs[ ._-]*\d{1,2}\b", " ", cleaned)
    cleaned = re.sub(
        r"(?i)(?:^|[^a-z0-9])?(?:series|season|vol(?:ume)?)[ ._-]*(?:[ivxlcdm]+|\d{1,2})(?:\b|[^a-z0-9]|$)",
        " ",
        cleaned,
    )
    cleaned = re.sub(r"(?i)\b(?:disc|disk|dvd)[ -]*\d{1,2}\b", " ", cleaned)
    cleaned = re.sub(
        r"(?i)\b(?:dvd|pal|ntsc|iso|mkv|mp4|avi|rip|backup|widescreen|fullscreen)\b",
        " ",
        cleaned,
    )
    cleaned = re.sub(r"(?<!\d)(?:19|20)\d{2}(?!\d)", " ", cleaned)
    cleaned = re.sub(r"[\[\](){}]+", " ", cleaned)
    cleaned = re.sub(r"\s+", " ", cleaned).strip(" -")

    # Ambiguous bare trailing series identifier on a multi-disc set (e.g.
    # ``RUMPOLE_OF_THE_BAILEY_IV_DISC_2.iso``). It *may* encode the season (the
    # user's Rumpole ISOs), but it may equally be part of a movie title (e.g.
    # ``Mission Impossible 2``). It is only interpreted as a season later once
    # the disc content is known to be TV-like, so the trailing token is kept in
    # the name here and stripped only on the TV path.
    trailing_series: int | None = None
    if disc is not None and cleaned:
        trailing = _TRAILING_NUMERAL_RE.search(cleaned)
        if trailing and not re.fullmatch(r"(?i)[ivxlcdm]+|\d{1,2}", cleaned):
            token = trailing.group("token")
            value = int(token) if token.isdigit() else _roman_to_int(token)
            if value is not None and 1 <= value <= 30:
                trailing_series = value

    if not cleaned:
        cleaned = stem.replace("_", " ").strip() or "Unknown DVD"
    if cleaned.isupper() or cleaned.islower():
        cleaned = cleaned.title()

    # An ISO filename is considered Jellyfin-curated when it carries any of the
    # canonical signals: parenthesised year, provider tag, episode marker, an
    # explicit season/series identifier, or a bare trailing series identifier
    # on a disc of a set. A curated name bypasses TVmaze so the user's chosen
    # library name is preserved.
    is_jellyfin_named = (
        parens_year is not None
        or provider is not None
        or episode is not None
        or explicit_season
        or trailing_series is not None
    )
    return SourceHints(
        name=cleaned,
        year=year,
        season=season,
        episode=episode,
        last_episode=last_episode,
        disc=disc,
        provider=provider,
        is_jellyfin_named=is_jellyfin_named,
        trailing_series=trailing_series,
    )


def strip_trailing_series_token(name: str, season: int) -> str:
    """Drop a trailing Arabic/Roman series token that represents ``season``.

    Only used on the TV path, where ``season`` was derived from the token (e.g.
    ``Rumpole Of The Bailey IV`` -> ``Rumpole Of The Bailey``). Movies keep the
    token as part of their title.
    """
    match = re.search(r"(?i)\s(?P<token>[ivxlcdm]+|\d{1,2})$", name)
    if not match:
        return name
    token = match.group("token")
    value = int(token) if token.isdigit() else _roman_to_int(token)
    if value == season:
        return name[: match.start()].strip(" -") or name
    return name


def normalized_name(value: str) -> str:
    return " ".join(re.findall(r"[a-z0-9]+", value.casefold()))


def natural_key(value: str) -> list[str | int]:
    return [int(part) if part.isdigit() else part.casefold() for part in re.split(r"(\d+)", value)]


def match_score(query: str, candidate: str) -> float:
    left = normalized_name(query)
    right = normalized_name(candidate)
    if not left or not right:
        return 0.0
    sequence = difflib.SequenceMatcher(None, left, right).ratio()
    left_tokens = set(left.split())
    right_tokens = set(right.split())
    overlap = len(left_tokens & right_tokens) / max(len(left_tokens | right_tokens), 1)
    return max(sequence, overlap)


def fetch_json(url: str, timeout: int) -> Any:
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT, "Accept": "application/json"})
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return json.load(response)


def tvmaze_match(hints: SourceHints, selected_count: int, timeout: int) -> dict[str, Any] | None:
    try:
        query = urllib.parse.urlencode({"q": hints.name})
        results = fetch_json(f"{TVMAZE_API}/search/shows?{query}", timeout)
    except Exception as error:  # Metadata is best-effort; conversion must still proceed.
        print(f"Metadata lookup unavailable: {error}", file=sys.stderr)
        return None
    candidates: list[tuple[float, dict[str, Any]]] = []
    for item in results[:10] if isinstance(results, list) else []:
        show = item.get("show") or {}
        score = match_score(hints.name, str(show.get("name") or ""))
        premiered = str(show.get("premiered") or "")
        if hints.year and premiered[:4].isdigit() and int(premiered[:4]) != hints.year:
            score -= 0.12
        candidates.append((score, show))
    if not candidates:
        return None
    score, show = max(candidates, key=lambda candidate: candidate[0])
    threshold = 0.62 if hints.season is not None else 0.80
    if score < threshold:
        print(f"Ignoring low-confidence TVmaze match for {hints.name!r} (score {score:.2f})")
        return None
    try:
        episodes = fetch_json(f"{TVMAZE_API}/shows/{int(show['id'])}/episodes", timeout)
    except Exception as error:
        print(f"TVmaze show matched but episode lookup failed: {error}", file=sys.stderr)
        episodes = []
    season = hints.season or 1
    season_episodes = [episode for episode in episodes if episode.get("season") == season and episode.get("number")]
    if hints.season is None and selected_count > 1 and len(season_episodes) < selected_count:
        return None
    return {"score": score, "show": show, "episodes": episodes}


def jellyfin_name(name: str, year: int | None, provider: str | None) -> str:
    value = name
    if year:
        value += f" ({year})"
    if provider:
        value += f" [{provider}]"
    return value


def existing_next_episode(shows_root: Path, media_name: str, season: int) -> int | None:
    season_dir = shows_root / media_name / f"Season {season:02d}"
    if not season_dir.is_dir():
        return None
    pattern = re.compile(rf"(?i)S{season:02d}E(\d+)")
    numbers = []
    for path in season_dir.glob("*.mkv"):
        match = pattern.search(path.name)
        if match:
            numbers.append(int(match.group(1)))
    return max(numbers) + 1 if numbers else None


# Continuity threshold for matching an ISO's curated name against an existing
# Jellyfin library folder. ``0.80`` keeps the user's Rumpole discs grouped with
# their previously converted siblings without glueing unrelated series that
# merely share common words like "The" or "Series".
EXISTING_FOLDER_MATCH_THRESHOLD = 0.80


def find_existing_series(
    library: Path,
    hints_name: str,
    threshold: float = EXISTING_FOLDER_MATCH_THRESHOLD,
    *,
    expected_year: int | None = None,
    expected_provider: str | None = None,
) -> tuple[str, int | None, str | None] | None:
    """Return ``(name, year, provider)`` for an existing library folder whose
    stripped name and any curated metadata match ``hints_name`` so siblings
    chain together. Ambiguous equal-scoring folders are not reused.

    This is the queue-grouping mechanism: when an ISO filename lacks canonical
    Jellyfin formatting, the auto-importer still continues prior encodes by
    adopting the existing library folder's full name (with its year/provider
    tags). Without this, RUMPOLE_OF_THE_BAILEY_IV_DISC_2.iso and
    RUMPOLE_OF_THE_BAILEY_3_DISC_1.iso would land in two unrelated series
    folders instead of one.
    """
    if not library.is_dir() or not hints_name:
        return None
    query = strip_jellyfin_suffix(hints_name)
    if not query:
        return None
    best_score = 0.0
    best: tuple[str, int | None, str | None] | None = None
    best_is_ambiguous = False
    for entry in library.iterdir():
        if not entry.is_dir():
            continue
        candidate_name, candidate_year, candidate_provider = parse_jellyfin_folder(entry.name)
        if not candidate_name:
            continue
        if expected_year is not None and candidate_year != expected_year:
            continue
        if expected_provider is not None and candidate_provider != expected_provider:
            continue
        score = match_score(query, candidate_name)
        if score < threshold:
            continue
        if score > best_score:
            best_score = score
            best = (candidate_name, candidate_year, candidate_provider)
            best_is_ambiguous = False
        elif score == best_score:
            best_is_ambiguous = True
    if best is None or best_is_ambiguous:
        return None
    return best


def find_existing_for_hints(
    library: Path,
    hints: SourceHints,
    display_name: str,
) -> tuple[str, int | None, str | None] | None:
    """Reuse an exact curated folder, or a conservative fuzzy uncurated match."""
    if hints.is_jellyfin_named:
        exact_matches: list[tuple[str, int | None, str | None]] = []
        if not library.is_dir():
            return None
        wanted = normalized_name(display_name)
        for entry in library.iterdir():
            if not entry.is_dir():
                continue
            candidate_name, candidate_year, candidate_provider = parse_jellyfin_folder(
                entry.name
            )
            if normalized_name(candidate_name) != wanted:
                continue
            if hints.year is not None and candidate_year != hints.year:
                continue
            if hints.provider is not None and candidate_provider != hints.provider:
                continue
            exact_matches.append((candidate_name, candidate_year, candidate_provider))
        return exact_matches[0] if len(exact_matches) == 1 else None
    return find_existing_series(
        library,
        display_name,
        threshold=EXISTING_FOLDER_MATCH_THRESHOLD,
        expected_year=hints.year,
        expected_provider=hints.provider,
    )


def provider_id(show: dict[str, Any]) -> str | None:
    external = show.get("externals") or {}
    if external.get("thetvdb"):
        return f"tvdbid-{int(external['thetvdb'])}"
    imdb = external.get("imdb")
    if isinstance(imdb, str) and re.fullmatch(r"tt\d+", imdb):
        return f"imdbid-{imdb}"
    return None


IDENTIFY_DEADLINE_SECONDS = 2 * 3600


def identification_enabled(args: argparse.Namespace) -> bool:
    return bool(getattr(args, "identifier", None)) and getattr(args, "held_dir", None) is not None


def needs_dir(args: argparse.Namespace) -> Path:
    return getattr(args, "needs_dir", None) or args.input_dir / "_NeedsIdentification"


def ripper_sidecar(source: Path) -> Path:
    """The desktop ripper's TheDiscDB evidence uploaded beside the ISO."""
    return source.with_name(source.stem + ".jellyfin.json")


def checksum_manifest(source: Path) -> Path:
    """The desktop ripper's ``sha256sum`` manifest uploaded beside the ISO."""
    return source.with_name(source.name + ".sha256")


def move_checksum(manifest: Path, archived: Path) -> None:
    """Keep an ISO's checksum manifest beside it wherever the ISO goes.

    Left behind in the inbox, a manifest makes the ripper refuse a later disc
    of the same name as a conflicting file. It is rewritten for the ISO's new
    name, so ``sha256sum -c`` keeps working after a rename; a manifest already
    at the destination is never replaced.
    """
    if not manifest.is_file() or manifest.is_symlink():
        return
    destination = checksum_manifest(archived)
    if destination.exists() or destination.is_symlink():
        print(f"Kept {manifest.name}: {destination.name} already exists", file=sys.stderr)
        return
    try:
        fields = manifest.read_text(encoding="utf-8").split()
        digest = fields[0].lower() if fields else ""
        if len(digest) == 64 and all(ch in "0123456789abcdef" for ch in digest):
            temporary = destination.with_name(f".{destination.name}.{os.getpid()}.tmp")
            temporary.write_text(f"{digest}  {archived.name}\n", encoding="utf-8")
            os.replace(temporary, destination)
            manifest.unlink()
        else:
            os.replace(manifest, destination)
    except (OSError, UnicodeDecodeError) as error:
        print(f"Could not move {manifest.name} with its ISO: {error}", file=sys.stderr)


def iso_owner(source: Path) -> str | None:
    """Username of whoever uploaded the ISO; their provider accounts are used."""
    try:
        return pwd.getpwuid(source.stat().st_uid).pw_name
    except (KeyError, OSError):
        return None


def uncertain(summary: str, reason: str) -> dict[str, Any]:
    return {"status": "uncertain", "summary": summary, "reasons": [reason],
            "assignments": [], "candidates": [], "series": None}


def run_identifier(
    args: argparse.Namespace,
    arguments: list[str],
    renew_lease: Any | None,
    stage_label: str,
) -> dict[str, Any]:
    """Run disc-identify, renewing the queue lease while it works.

    Identification never fails a conversion: any error becomes an uncertain
    result, which holds the disc for a person instead of guessing.
    """
    common = []
    if getattr(args, "bonsai_url", None):
        common += ["--bonsai-url", args.bonsai_url]
    cache = args.state_dir / "identify-cache"
    common += ["--cache-dir", str(cache)]
    work = (args.staging_dir or args.state_dir) / f".identify-{os.getpid()}"
    common += ["--work-dir", str(work)]
    # The broker socket also checks episode numbering against TMDB.
    if getattr(args, "subtitle_socket", None):
        common += ["--provider-socket", args.subtitle_socket]
    command = [args.identifier, *arguments, *common]
    print(f"Identifying episodes ({stage_label})")
    try:
        process = subprocess.Popen(
            command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
            encoding="utf-8", errors="replace", start_new_session=True,
        )
    except OSError as error:
        return uncertain("Episode identification is unavailable.", f"could not start the identifier: {error}")
    deadline = time.monotonic() + IDENTIFY_DEADLINE_SECONDS
    renew_after = time.monotonic() + max(1.0, args.lease_seconds / 3)
    try:
        while True:
            if shutdown_signal is not None:
                raise ShutdownRequested("shutdown during episode identification")
            if time.monotonic() >= deadline:
                stop_process_tree(process)
                return uncertain("Episode identification took too long.", "the identifier exceeded its deadline")
            if renew_lease is not None and time.monotonic() >= renew_after:
                if not renew_lease():
                    raise LeaseLost("queue lease was lost during episode identification")
                renew_after = time.monotonic() + max(1.0, args.lease_seconds / 3)
            try:
                stdout, stderr = process.communicate(timeout=0.5)
                break
            except subprocess.TimeoutExpired:
                continue
    except BaseException:
        stop_process_tree(process)
        raise
    finally:
        shutil.rmtree(work, ignore_errors=True)
    if process.returncode != 0:
        detail = (stderr or "").strip()[-500:]
        return uncertain("Episode identification failed.", f"identifier error: {detail or process.returncode}")
    try:
        result = json.loads(stdout)
    except json.JSONDecodeError:
        return uncertain("Episode identification failed.", "the identifier printed invalid JSON")
    if not isinstance(result, dict):
        return uncertain("Episode identification failed.", "the identifier printed invalid JSON")
    for line in result.get("reasons") or []:
        print(f"  identification: {line}")
    print(f"  identification: {result.get('summary', '')}")
    return result


def identify_disc(args: argparse.Namespace, source: Path, selected: list[Title],
                  hints: SourceHints, renew_lease: Any | None,
                  sidecar: Path | None = None) -> dict[str, Any]:
    # Repeated All Creatures holds (2026-11-14/15): the library had the
    # spaced title, but we sent the compressed volume label to TVmaze and
    # depended on Bonsai to recover its words. Reuse only an unambiguous,
    # letter-for-letter library match as a search hint, never as episode proof.
    name_hint = hints.name
    existing = find_existing_for_hints(args.shows_dir, hints, hints.name)
    if existing is not None:
        compact = lambda value: normalized_name(value).replace(" ", "")
        if compact(existing[0]) == compact(hints.name):
            name_hint = existing[0]
    arguments = ["disc", "--iso", str(source), "--name-hint", name_hint,
                 "--sevenzip", args.sevenzip, "--ffmpeg", args.ffmpeg,
                 "--max-menu-frames", str(getattr(args, "max_menu_frames", 32))]
    for title in selected:
        arguments += ["--title", f"{title.index}:{title.seconds}"]
    if hints.season is not None:
        arguments += ["--season-hint", str(hints.season)]
    aspects = [title.aspect for title in selected if title.aspect]
    if aspects:
        arguments += ["--display-aspect", f"{sorted(aspects)[len(aspects) // 2]:.2f}"]
    sidecar = sidecar or ripper_sidecar(source)
    if sidecar.is_file():
        arguments += ["--sidecar", str(sidecar)]
    # The uploader's saved TMDB account checks the episode numbering.
    owner = iso_owner(source)
    if owner:
        arguments += ["--owner", owner]
    return run_identifier(args, arguments, renew_lease, "disc menus")


def identify_content(args: argparse.Namespace, source: Path, plan: dict[str, Any],
                     videos: list[str], renew_lease: Any | None) -> dict[str, Any]:
    if not (getattr(args, "parakeet", None) and getattr(args, "parakeet_model", None)):
        return uncertain(plan.get("identification", {}).get("summary") or "Episodes need confirming.",
                         "speech transcription is not configured")
    context = args.state_dir / f".identify-context-{os.getpid()}.json"
    disc_outcome = dict(plan.get("identification") or {})
    proposal = order_proposal(args, source, disc_outcome, list(plan["titles"]))
    if proposal is not None:
        disc_outcome.update(assignments=proposal["assignments"],
                            proposalSource=proposal["proposalSource"])
        print(f"  identification: {proposal['reason']}")
    atomic_json(context, disc_outcome)
    arguments = ["content", "--context", str(context), "--ffmpeg", args.ffmpeg,
                 "--parakeet", args.parakeet, "--parakeet-model", args.parakeet_model,
                 "--threads", str(args.identify_threads)]
    for video, title in zip(videos, plan["titles"]):
        arguments += ["--video", video, "--title", str(title)]
    owner = iso_owner(source)
    if owner:
        arguments += ["--owner", owner]
    if owner and getattr(args, "subtitle_socket", None):
        arguments += ["--subtitle-socket", args.subtitle_socket]
    try:
        result = run_identifier(args, arguments, renew_lease, "dialogue")
    finally:
        context.unlink(missing_ok=True)
    if proposal is not None:
        result["reasons"] = [proposal["reason"], *(result.get("reasons") or [])]
    return result


def identified_assignments(result: dict[str, Any], titles: list[int]) -> list[dict[str, Any]] | None:
    """Validated assignments, in title order, or None when not usable."""
    if result.get("status") != "identified" or not isinstance(result.get("series"), dict):
        return None
    assignments = result.get("assignments") or []
    if [a.get("title") for a in assignments] != list(titles):
        return None
    numbers = [(a.get("season"), a.get("episode")) for a in assignments]
    if not all(isinstance(s, int) and isinstance(e, int) for s, e in numbers):
        return None
    if any(n[0] != numbers[0][0] or n[1] != numbers[0][1] + i for i, n in enumerate(numbers)):
        return None
    return assignments


# Hold reasons that a later attempt can change: a busy or failed service, or
# the identifier itself failing. Matched against reason text from both
# stages and from this worker.
TRANSIENT_REASONS = [re.compile(pattern) for pattern in (
    r"Bonsai (?:could not [a-z ]+|ranking failed): .*(?:HTTP (?:429|5\d\d)|timed out|timeout"
    r"|error sending request|connection|POST https?://)",
    # Label splitting failed on every disc from 2026-11-15 to 2026-11-17
    # because Bonsai's reasoning used the whole token budget (fixed in
    # disc-identify since). Those holds, and any later cut-off, are retried.
    r"^Bonsai could not split the label: Bonsai reply (?:is not the requested JSON|was cut off)",
    # A menu reading cut off at its token limit (long reasoning) is a
    # sampling accident like the label split above, not a verdict on the
    # menu. The identifier now keeps the frames that did read; a partial
    # read that still cannot name the disc, and a total failure whose
    # batches each cut off, are retried the same way.
    r"^Bonsai could not read (?:the menus|some menu frames): .*Bonsai reply was cut off",
    r"^TVmaze (?:search failed|episodes for .+ failed)",
    r"^The OpenSubtitles daily download limit was reached",
    r"^OpenSubtitles comparison is unavailable",
    r"^TMDB is unavailable",
    r"^the identifier exceeded its deadline",
    r"^identifier error:",
    r"^could not start the identifier",
    r"^the identifier printed invalid JSON",
    r"^Title \d+: transcription failed: (?!the excerpt contains too little speech)",
)]
# Reasons that say the evidence disagrees, which no retry changes.
SUBSTANTIVE_REASONS = [re.compile(pattern) for pattern in (
    # A library-order or disc-number guess is only a guess: the content
    # stage falls back to the dialogue alone when it is contradicted.
    r"rather than the (?!library order |disc number ).*guess",
    r"^The matched episodes are not consecutive",
    r"^The episodes named on the menu are not consecutive",
    r"different series equally well",
    r"TV series share this name",
    r"^The disc menu lists \d+ episodes but",
    r"^TheDiscDB places these episodes",
    r"^publishing failed:",
    r"converter's outputs could not be matched",
    r"^the disc's titles changed",
)]
# Automatic re-identification of a hold whose blockers were all transient:
# the delay before attempt 1, 2 and 3; after that a person decides.
RETRY_DELAYS = (3600, 6 * 3600, 24 * 3600)
# `.identify.json` evidence schema. 2 added `status`, `outcomes`, `retry`
# and `resolution`; the schema-1 fields keep their meaning.
EVIDENCE_SCHEMA_VERSION = 2


def classify_reasons(reasons: list[Any]) -> dict[str, Any]:
    """Split hold reasons into transient and substantive blockers.

    ``retryable`` is true when something temporary went wrong and nothing
    contradicts the disc; other reasons (no match, unreadable menus) only
    follow from the evidence that was available and block nothing alone.
    """
    texts = [str(reason) for reason in reasons]
    transient = [text for text in texts if any(p.search(text) for p in TRANSIENT_REASONS)]
    substantive = [text for text in texts if any(p.search(text) for p in SUBSTANTIVE_REASONS)]
    return {
        "retryable": bool(transient) and not substantive,
        "transientReasons": transient,
        "substantiveReasons": substantive,
    }


def library_to_provider_episode(series: dict[str, Any], season: int,
                                episode: int) -> tuple[int, int]:
    """Convert library (Jellyfin folder) numbering into the identifier's.

    The library is numbered like TVmaze for now. This is the one place a
    numbering map (e.g. TMDB/TVDB orderings) has to be applied.
    """
    del series  # the mapping does not depend on the series yet
    return season, episode


_LIBRARY_EPISODE_RE = re.compile(r"(?i)S(\d{1,2})E(\d{1,3})(?:-?E(\d{1,3}))?")


def library_episode_numbers(series_dir: Path) -> set[tuple[int, int]]:
    """Every (season, episode) a library series folder holds (ranges expanded)."""
    present: set[tuple[int, int]] = set()
    try:
        folders = [entry for entry in series_dir.iterdir()
                   if entry.is_dir() and re.fullmatch(r"Season \d{1,3}", entry.name)]
    except OSError:
        return present
    for folder in folders:
        for path in folder.glob("*.mkv"):
            match = _LIBRARY_EPISODE_RE.search(path.name)
            if match:
                season, first = int(match.group(1)), int(match.group(2))
                last = max(first, int(match.group(3) or first))
                present.update((season, number) for number in range(first, last + 1))
    return present


def library_gaps(present: set[tuple[int, int]], counts: dict[int, int],
                 season: int | None) -> list[tuple[int, int, int]]:
    """Runs of missing episodes (season, first, last) within the provider's counts."""
    runs: list[tuple[int, int, int]] = []
    for number in sorted(counts):
        if number < 1 or (season is not None and number != season):
            continue
        first = None
        for episode in range(1, counts[number] + 2):
            missing = episode <= counts[number] and (number, episode) not in present
            if missing and first is None:
                first = episode
            elif not missing and first is not None:
                runs.append((number, first, episode - 1))
                first = None
    return runs


def order_proposal(args: argparse.Namespace, source: Path, identification: dict[str, Any],
                   titles: list[int]) -> dict[str, Any] | None:
    """Propose episodes for a disc whose series is known but episodes are not.

    From the library ("library order"): when exactly one run of missing
    episodes (within the provider's season counts, and the disc's season if
    known) has room for the disc's titles, its first episodes; with several
    the dialogue alone decides. Without counts, the episodes after the known
    season's last one. With no library episodes (in that season), an
    estimate from the disc number in the file name ("disc number"). The
    content stage only accepts it when the dialogue confirms a title and
    contradicts none, and falls back to the dialogue alone otherwise.
    """
    series = identification.get("series")
    if (identification.get("status") == "identified" or identification.get("assignments")
            or not isinstance(series, dict) or not series.get("tvmazeId") or not titles):
        return None
    counts: dict[int, int] = {}
    raw_counts = identification.get("seasonEpisodeCounts")
    for key, value in (raw_counts.items() if isinstance(raw_counts, dict) else []):
        if str(key).isdigit() and isinstance(value, int):
            counts[int(key)] = value
    known_season = identification.get("season") if isinstance(identification.get("season"), int) else None
    count = len(titles)
    start: tuple[int, int] | None = None
    origin = ""
    note = ""
    name, year, provider = library_identity(args.shows_dir, series)
    series_dir = args.shows_dir / safe_name(jellyfin_name(name, year, provider))
    present = library_episode_numbers(series_dir) if series_dir.is_dir() else set()
    in_scope = {number for number in present if known_season in (None, number[0])}
    if in_scope:
        origin = "library order"
        if counts:
            fitting = [run for run in library_gaps(present, counts, known_season)
                       if run[2] - run[1] + 1 >= count]
            if len(fitting) == 1:
                season, first, _ = fitting[0]
                start = (season, first)
                before = max((number for number in present if number < start), default=None)
                note = "the library's only gap with room for the disc" + (
                    f", after S{before[0]:02d}E{before[1]:02d}" if before else "")
        elif known_season is not None:
            last = max(in_scope)
            start = (known_season, last[1] + 1)
            note = f"after S{last[0]:02d}E{last[1]:02d} in the library"
    else:
        # No library episodes to continue from (in this season).
        try:
            disc = source_hints(source).disc
        except ValueError:
            disc = None
        if disc:
            season = known_season or 1
            start = (season, (disc - 1) * count + 1)
            origin = "disc number"
            note = f"disc {disc} of season {season}"
    if start is None:
        return None
    season, first = start
    numbers = [library_to_provider_episode(series, season, first + offset) for offset in range(count)]
    if any(n[0] != numbers[0][0] or n[1] != numbers[0][1] + i for i, n in enumerate(numbers)):
        return None
    provider_season, provider_first = numbers[0]
    # A disc never crosses a season; past the provider's count it cannot fit.
    if counts and provider_first + count - 1 > counts.get(provider_season, 0):
        return None
    assignments = [
        {"title": title, "season": s, "episode": e, "name": "", "evidence": origin}
        for title, (s, e) in zip(titles, numbers)
    ]
    episodes = f"S{provider_season:02d}E{provider_first:02d}" + (
        f"-E{provider_first + count - 1:02d}" if count > 1 else "")
    return {
        "proposalSource": origin,
        "assignments": assignments,
        "reason": f"Proposed {episodes} from the {origin} ({note}); the dialogue must confirm it.",
    }


def evidence_resolution(by: str, name: str, year: int | None, provider: str | None,
                        season: int, first: int, count: int) -> dict[str, Any]:
    """How a disc's episodes were finally decided, for the evaluation harness.

    ``by`` is "identifier" (identified on first pass), "automatic retry" or
    "rename" (a person named the ISO).
    """
    return {"by": by, "series": name, "year": year, "provider": provider,
            "season": season, "firstEpisode": first, "lastEpisode": first + count - 1}


def write_processed_evidence(archived: Path, plan: dict[str, Any]) -> None:
    """Keep an identified disc's evidence beside its archived ISO.

    Same document as a held disc's ``.identify.json`` (schema 2) with
    ``status`` "identified" and a ``resolution``; best effort.
    """
    outcomes = plan.get("identify_outcomes")
    if not isinstance(outcomes, dict):
        outcomes = {"disc": plan.get("identification"), "content": None}
    titles = plan.get("titles") or []
    evidence = {
        "schemaVersion": EVIDENCE_SCHEMA_VERSION,
        "status": "identified",
        "sourceIso": plan.get("source_iso") or "",
        "titles": titles,
        "summary": str((plan.get("identification") or {}).get("summary") or ""),
        "reasons": [str(r) for r in ((plan.get("identification") or {}).get("reasons") or [])][:12],
        "outcomes": outcomes,
        # Automatic retries archive their evidence in complete_retry_publish.
        "resolution": evidence_resolution(
            "identifier", str(plan.get("name") or ""), plan.get("year"), plan.get("provider"),
            int(plan["season"]) if isinstance(plan.get("season"), int) else 1,
            int(plan.get("first_episode") or 1), len(titles)),
        "finishedAt": int(time.time()),
    }
    try:
        atomic_json(archived.with_name(archived.name + ".identify.json"), evidence)
    except OSError as error:
        print(f"Could not record identification evidence for {archived.name}: {error}",
              file=sys.stderr)


def library_match(shows_root: Path, series: dict[str, Any]
                  ) -> tuple[tuple[str, int | None, str | None], str | None]:
    """The library folder identity for a series, and a TMDB-numbering conflict.

    A folder tagged with any of the series' provider ids (``providerIds``:
    TMDB, TVDB or IMDb, from the TMDB numbering check) is the series' folder
    whatever it is called. Otherwise name and year must match, and a folder
    tag of a kind the series knows must be one of its ids.

    A ``tmdbid`` folder is numbered like TMDB, which can differ from TVmaze
    (Sherlock Holmes (1984): 4 TVmaze seasons, 7 on TMDB). Only a series
    whose numbering was mapped to TMDB (``tmdbId``) may reuse it by name; for
    any other the second value names that folder, and the disc is held:
    publishing into it would misnumber it, and a second folder would split
    the series in Jellyfin.
    """
    name = str(series.get("name") or "").strip()
    year = series.get("year") if isinstance(series.get("year"), int) else None
    provider = series.get("provider") if isinstance(series.get("provider"), str) else None
    known = {tag for tag in [provider, *(series.get("providerIds") or [])] if isinstance(tag, str) and tag}
    kinds = {tag.split("-", 1)[0] for tag in known}
    tmdb_numbered = isinstance(series.get("tmdbId"), int) and not isinstance(series.get("tmdbId"), bool)
    if shows_root.is_dir():
        wanted = normalized_name(name)
        tagged = []
        matches = []
        unmapped_tmdb_folders = []
        for entry in sorted(shows_root.iterdir()):
            if not entry.is_dir():
                continue
            candidate_name, candidate_year, candidate_provider = parse_jellyfin_folder(entry.name)
            if candidate_provider in known:
                tagged.append((candidate_name, candidate_year, candidate_provider))
            if normalized_name(candidate_name) != wanted:
                continue
            if year is not None and candidate_year not in (None, year):
                continue
            if (candidate_provider and candidate_provider not in known
                    and candidate_provider.split("-", 1)[0] in kinds):
                continue
            if (candidate_provider and candidate_provider.startswith("tmdbid-")
                    and candidate_provider not in known and not tmdb_numbered):
                unmapped_tmdb_folders.append(entry.name)
                continue
            matches.append((candidate_name, candidate_year, candidate_provider))
        if len(tagged) == 1:
            return tagged[0], None
        if unmapped_tmdb_folders:
            return (name, year, provider), unmapped_tmdb_folders[0]
        if len(matches) == 1:
            return matches[0], None
    return (name, year, provider), None


def library_identity(shows_root: Path, series: dict[str, Any]) -> tuple[str, int | None, str | None]:
    """Reuse an existing library folder for the series, else its provider name.

    See library_match; callers that publish check numbering_hold first.
    """
    return library_match(shows_root, series)[0]


def numbering_hold(shows_root: Path, result: dict[str, Any]) -> dict[str, Any] | None:
    """An identified result held because its numbering does not fit the folder.

    None when the series may be published (see library_match). The held
    result keeps no assignments: its TVmaze numbers would name the wrong
    episodes in the TMDB-numbered folder if a person accepted them.
    """
    series = result.get("series")
    if not isinstance(series, dict):
        return None
    folder = library_match(shows_root, series)[1]
    if folder is None:
        return None
    reasons = [str(reason) for reason in result.get("reasons") or []]
    if any("no TMDB account saved" in reason for reason in reasons):
        why = "the uploader has no TMDB account saved in Media Manager"
    elif any("uploader is unknown" in reason for reason in reasons):
        why = "the uploader is unknown, so no TMDB account could be used"
    else:
        why = "they were not mapped to TMDB"
    reason = (f"The existing library folder {folder} uses TMDB episode numbering, but these "
              f"episodes have TVmaze numbering ({why}); they are held rather than published "
              "into it or into a second folder for the series.")
    return dict(result, status="uncertain", assignments=[],
                reasons=[*(result.get("reasons") or []), reason],
                summary=f"{folder} needs TMDB episode numbering; the episodes need confirming.")


def safe_name(value: str) -> str:
    """Match disc-to-jellyfin's filename cleaning."""
    cleaned = "".join("_" if ch in '<>:"/\\|?*' or ord(ch) < 32 else ch for ch in value)
    return cleaned.strip(" .")


def make_media_dirs(path: Path) -> None:
    """Create library folders group-writable; setgid is inherited, never set.

    The worker's RestrictSUIDSGID sandbox refuses an explicit setgid mode.
    """
    missing = []
    current = path
    while not current.exists():
        missing.append(current)
        current = current.parent
    for directory in reversed(missing):
        os.mkdir(directory, 0o770)


def prune_empty_dirs(path: Path, stop: Path) -> None:
    current = path
    while current != stop and stop in current.parents:
        try:
            current.rmdir()
        except OSError:
            return
        current = current.parent


def staging_name(target: Path, file: Path) -> Path:
    """Hidden, deterministic staging file beside a library target.

    Scanners ignore dot files. The name is tied to the held file it comes
    from, so a retry for this disc finds its own crash leftovers and never
    mistakes another disc's for them.
    """
    tag = hashlib.sha256(str(file).encode("utf-8", "surrogateescape")).hexdigest()[:12]
    return target.with_name(f".{target.name}.{tag}.publish.tmp")


def stage_episode(file: Path, staged: Path) -> bool:
    """Put a held episode at its hidden staging name; True if it was copied.

    The worker's sandbox mounts the holding folder and the library as
    separate bind mounts of one dataset, so rename() fails with EXDEV there.
    Like disc-to-jellyfin, fall back to copying (fsynced) instead.
    """
    # Only reached while the original is present (see publish_episodes), so
    # a leftover here is a stale copy and safe to replace.
    staged.unlink(missing_ok=True)
    try:
        os.rename(file, staged)
        return False
    except OSError as error:
        if error.errno != errno.EXDEV:
            raise
    try:
        with file.open("rb") as source, open(staged, "xb") as copy:
            shutil.copyfileobj(source, copy, 16 * 1024 * 1024)
            copy.flush()
            os.fsync(copy.fileno())
    except BaseException:
        staged.unlink(missing_ok=True)
        raise
    return True


def episode_targets(args: argparse.Namespace, count: int, name: str, year: int | None,
                    provider: str | None, season: int, first: int,
                    names: list[str]) -> tuple[Path, list[Path]]:
    """The season folder and library file names publish_episodes uses."""
    media_name = safe_name(jellyfin_name(name, year, provider))
    # Jellyfin reads the series identifier from the folder; repeating it in
    # every episode file only makes the library harder to read.
    episode_series = safe_name(jellyfin_name(name, year, None))
    season_dir = args.shows_dir / media_name / f"Season {season:02d}"
    targets = []
    for offset in range(count):
        title = safe_name(names[offset]) if offset < len(names) and names[offset] else ""
        stem = f"{episode_series} S{season:02d}E{first + offset:02d}"
        targets.append(season_dir / (f"{stem} - {title}.mkv" if title else f"{stem}.mkv"))
    return season_dir, targets


def publish_episodes(args: argparse.Namespace, files: list[Path], name: str, year: int | None,
                     provider: str | None, season: int, first: int, names: list[str]) -> Path:
    """Move held episode files into the TV library, all or nothing."""
    season_dir, targets = episode_targets(args, len(files), name, year, provider, season,
                                          first, names)
    # Recover from a publish of this disc that was killed part-way. A target
    # that is the same file as this disc's staging name is its own link; a
    # target with neither staging nor held file left was already cleaned up.
    stagings = [staging_name(t, f) for f, t in zip(files, targets)]
    linked_here = [t.exists() and st.exists() and os.path.samefile(t, st)
                   for t, st in zip(targets, stagings)]
    cleaned = [t.exists() and not st.exists() and not f.exists()
               for f, t, st in zip(files, targets, stagings)]
    if any(linked_here) and all(a or b for a, b in zip(linked_here, cleaned)):
        # Killed after every link was made: only clean-up was left.
        for file, target, staging, own in zip(files, targets, stagings, linked_here):
            if not own:
                continue
            if file.exists() and file.stat().st_size != target.stat().st_size:
                raise RuntimeError(f"{file} differs from the published {target}; left for a person")
            # Held copy first, staging last: at every stopping point an episode
            # is either still linked to its staging file or fully cleaned.
            if file.exists():
                file.unlink()  # the copied original; the library copy is complete
            staging.unlink()
        for target in targets:
            print(f"  published {target}")
        if getattr(args, "held_dir", None) is not None:
            for file in files:
                prune_empty_dirs(file.parent, args.held_dir)
        return season_dir
    for file, target, staging, own in zip(files, targets, stagings, linked_here):
        if own:
            target.unlink()  # killed while linking: undo this disc's links
        if staging.exists():
            if file.exists():
                staging.unlink()  # a stale copy; the original is intact
            else:
                os.rename(staging, file)  # the original itself, moved by rename
    missing = [str(f) for f in files if not f.is_file()]
    if missing:
        raise RuntimeError(f"held episode files are missing: {', '.join(missing)}")
    taken = [str(t) for t in targets if t.exists()]
    if taken:
        raise RuntimeError(f"library already has: {', '.join(taken)}")
    make_media_dirs(season_dir)
    # Phase 1 (slow, invisible): every episode reaches a hidden staging file
    # beside its target. Phase 2 (fast): each is linked to its final name,
    # which never replaces an existing file. A failure or shutdown before
    # phase 2 finishes undoes everything, so the library gets all of a disc
    # or none of it and the held record stays accurate.
    staged: list[tuple[Path, Path, Path, bool]] = []  # source, staging, target, copied
    linked: list[Path] = []

    def undo() -> None:
        for target in reversed(linked):
            target.unlink(missing_ok=True)
        for file, staging, _, copied in reversed(staged):
            if copied:
                staging.unlink(missing_ok=True)
            else:
                os.rename(staging, file)

    try:
        for file, target in zip(files, targets):
            if shutdown_signal is not None:
                raise ShutdownRequested("shutdown while publishing held episodes")
            staging = staging_name(target, file)
            staged.append((file, staging, target, stage_episode(file, staging)))
        for _, staging, target, _ in staged:
            os.link(staging, target)
            linked.append(target)
    except BaseException:
        undo()
        raise
    # Published. Clean-up failures from here on are only worth a warning.
    for file, staging, _, copied in staged:
        # Held copy first, staging last, so a kill between the two still
        # reads as "linked" to recovery rather than as a half-cleaned episode.
        for leftover in ([file, staging] if copied else [staging]):
            try:
                leftover.unlink()
            except OSError as error:
                print(f"Could not remove {leftover} after publishing: {error}", file=sys.stderr)
    for target in targets:
        print(f"  published {target}")
    if getattr(args, "held_dir", None) is not None:
        for file in files:
            prune_empty_dirs(file.parent, args.held_dir)
    return season_dir


def iso_suggestion(series: dict[str, Any] | None, assignments: list[dict[str, Any]],
                   count: int) -> dict[str, Any] | None:
    """The Jellyfin ISO name that would publish the held episodes as guessed."""
    if not isinstance(series, dict) or len(assignments) != count or not assignments:
        return None
    numbers = [(a.get("season"), a.get("episode")) for a in assignments]
    if not all(isinstance(s, int) and isinstance(e, int) for s, e in numbers):
        return None
    if any(n[0] != numbers[0][0] or n[1] != numbers[0][1] + i for i, n in enumerate(numbers)):
        return None
    season, first = numbers[0]
    last = numbers[-1][1]
    year = series.get("year") if isinstance(series.get("year"), int) else None
    provider = series.get("provider") if isinstance(series.get("provider"), str) else None
    episodes = f"S{season:02d}E{first:02d}" + (f"-E{last:02d}" if last != first else "")
    return {
        "series": series.get("name"),
        "year": year,
        "provider": provider,
        "season": season,
        "firstEpisode": first,
        "lastEpisode": last,
        # The provider tag belongs to the series folder, not the ISO the person
        # renames; held_provider() carries it into the library from this record.
        "isoName": safe_name(f"{jellyfin_name(str(series.get('name') or ''), year, None)} {episodes}") + ".iso",
    }


def held_suggestion(result: dict[str, Any], count: int, shows_root: Path | None = None,
                    disc_outcome: dict[str, Any] | None = None) -> dict[str, Any] | None:
    """The suggestion for a held result; none when its numbering is not Jellyfin's.

    ``tmdbNumberingHeld`` (on either stage's outcome: the content stage passes
    an unconfirmed disc-stage proposal through unchanged) marks a disc held
    because its episodes could not be renumbered as TMDB numbers them, so the
    guess is in TVmaze numbering. Likewise a series not mapped to TMDB whose
    library folder is TMDB-numbered: accepting the guess would publish TVmaze
    numbers into it.
    """
    if result.get("tmdbNumberingHeld") or (disc_outcome or {}).get("tmdbNumberingHeld"):
        return None
    series = result.get("series")
    if (shows_root is not None and isinstance(series, dict)
            and library_match(shows_root, series)[1] is not None):
        return None
    return iso_suggestion(series, result.get("assignments") or [], count)


def held_record_key(path: Path) -> str:
    """Survives the person renaming the ISO (same inode and size).

    The device number is left out: on ZFS it is assigned at mount time and
    can change across reboots, and the folder is a single filesystem.
    """
    info = path.stat()
    return f"{info.st_ino}:{info.st_size}"



_DISC_TOKEN_RE = re.compile(r"(?i)(?:d|disc|disk|dvd) ?\d{1,2}")
SPECIAL_MATCH_THRESHOLD = 0.85


def show_for_feature(shows_root: Path, movies_root: Path,
                     hints: SourceHints) -> tuple[tuple[str, int | None, str | None], str] | None:
    """The existing show a single-feature disc is named after, and the rest of its name.

    ``Rumpole of the Bailey D4`` names the show itself; ``Rumpole of the
    Bailey - Rumpole's Return`` names the show plus a subtitle. A bare number
    after a show name is a film sequel (``Mission Impossible 2``), and a name
    a ``_Movies`` folder already has stays a film.
    """
    if not shows_root.is_dir():
        return None
    query = normalized_name(hints.name)
    if not query:
        return None
    if movies_root.is_dir():
        for entry in movies_root.iterdir():
            base, year, _ = parse_jellyfin_folder(entry.name)
            if entry.is_dir() and normalized_name(base) == query and hints.year in (None, year):
                return None
    matches: list[tuple[int, tuple[str, int | None, str | None], str]] = []
    for entry in shows_root.iterdir():
        if not entry.is_dir():
            continue
        base, year, provider = parse_jellyfin_folder(entry.name)
        wanted = normalized_name(base)
        if not wanted or (hints.provider is not None and provider != hints.provider):
            continue
        if query == wanted:
            rest = ""
        elif query.startswith(wanted + " "):
            rest = query[len(wanted) + 1:]
            if rest.isdigit() or _roman_to_int(rest) is not None:
                continue
            if _DISC_TOKEN_RE.fullmatch(rest):
                rest = ""
        else:
            continue
        # The whole name is the show's: a year in it must be the show's. A
        # subtitle's year may be the special's own air date.
        if not rest and hints.year is not None and year != hints.year:
            continue
        matches.append((len(wanted), (base, year, provider), rest))
    if not matches:
        return None
    longest = max(length for length, _, _ in matches)
    best = [match for match in matches if match[0] == longest]
    if len(best) != 1:
        return None
    return best[0][1], best[0][2]


def special_candidates(rest: str, specials: list[tuple[int, str]]) -> list[tuple[float, int, str]]:
    """Season-0 episodes ranked by how well their name matches the disc's subtitle."""
    ranked = []
    words = f" {rest} "
    for episode, title in specials:
        wanted = normalized_name(title)
        score = match_score(rest, title) if rest else 0.0
        if rest and len(wanted.split()) >= 2 and f" {wanted} " in words:
            score = max(score, 0.95)  # ``Christmas Special - Rumpole's Return``
        ranked.append((score, episode, title))
    return sorted(ranked, key=lambda item: (-item[0], item[1]))


def special_plan(args: argparse.Namespace, source: Path, hints: SourceHints,
                 title: Title, ratio: float) -> dict[str, Any] | None:
    """File a feature-length special of an existing show at its S00Exx, or hold it.

    None leaves the disc a movie: its name is not an existing show's,
    identification (and its holding area) is not configured, or a name that
    adds a subtitle to the show's has no season-0 evidence. Only a TMDB list
    has season 0 (TVmaze numbers no specials), so without TMDB such a disc
    is a film named after the show (``Sherlock Holmes A Game of Shadows
    (2011)`` beside ``Sherlock Holmes (1984)``), as before specials existed.
    A disc named only after the show (``Rumpole of the Bailey D4``) is held.
    """
    match = show_for_feature(args.shows_dir, args.movies_dir, hints)
    if match is None:
        return None
    (name, year, provider), rest = match
    result = provider_episodes(args, name, year, provider, iso_owner(source))
    titles = library_episodes(result, year, provider) \
        if isinstance(result, dict) and result.get("layout") == "tmdb" else {}
    specials = sorted((e, t) for (s, e), t in titles.items() if s == 0)
    ranked = special_candidates(rest, specials)
    listed = {
        e.get("episode"): e for e in (result or {}).get("episodes") or []
        if isinstance(e, dict) and e.get("season") == 0
    } if titles else {}

    def fits_year(episode: int) -> bool:
        # A year in the name that is not the show's must be the special's own.
        if hints.year is None or year is None or hints.year == year:
            return True
        airdate = str((listed.get(episode) or {}).get("airdate") or "")
        return airdate[:4] == str(hints.year)

    # Filed directly only when a differing year in the name is the special's
    # own (``..._Hound_of_the_Baskervilles_1959`` is the film, not a 1988 special).
    confident = [item for item in ranked
                 if item[0] >= SPECIAL_MATCH_THRESHOLD and fits_year(item[1])]
    media = jellyfin_name(name, year, provider)
    if len(confident) == 1:
        _, episode, episode_name = confident[0]
        print(f"Filing {source.name} as {media} S00E{episode:02d} - {episode_name}")
        return {
            "kind": "tv",
            "name": name,
            "year": year,
            "provider": provider,
            "season": 0,
            "first_episode": episode,
            "last_episode": episode,
            "episode_names": [episode_name],
            "titles": [title.index],
            "dominant_ratio": ratio,
            "output": str(args.shows_dir),
        }
    if not identification_enabled(args):
        return None
    guess = ranked[0] if ranked and ranked[0][0] >= 0.6 and fits_year(ranked[0][1]) else None
    if guess is None and specials:
        # Only a suggestion for the person: the one special of this length.
        runtimes = {e: (listed.get(e) or {}).get("runtime") for e, _ in specials}
        close = [(0.0, e, t) for e, t in specials
                 if isinstance(runtimes.get(e), int) and fits_year(e)
                 and abs(runtimes[e] * 60 - title.seconds) <= max(300, title.seconds / 10)]
        guess = close[0] if len(close) == 1 else None
    if rest and guess is None and not any(fits_year(e) for _, e, _ in confident):
        return None  # a subtitle with no season-0 evidence: a film
    if not specials:
        layout = result.get("layout") if isinstance(result, dict) else "unavailable"
        reason = f"no season 0 list in Jellyfin's numbering for {media} (episode list: {layout})"
    elif len(confident) > 1:
        reason = "several specials match: " + ", ".join(
            f"S00E{e:02d} {t}" for _, e, t in confident[:4])
    elif rest:
        reason = f"no special of {media} is named like {rest!r}"
    else:
        reason = f"the disc name gives no special title to match against {media}'s season 0"
    print(f"Holding {source.name}: one feature-length title named after {media}; {reason}")
    identification = {
        "status": "uncertain",
        "summary": f"A feature-length title named after {media}; confirm which special it is.",
        "reasons": [reason],
        "assignments": [{"title": title.index, "season": 0, "episode": guess[1]}] if guess else [],
        "candidates": [],
        "series": {"name": name, "year": year, "provider": provider},
    }
    return {
        "kind": "tv",
        "name": safe_name(source.stem),
        "year": None,
        "provider": None,
        "season": 1,
        "first_episode": 1,
        "last_episode": None,
        "episode_names": [f"DVD Title {title.index:02d}"],
        "titles": [title.index],
        "dominant_ratio": ratio,
        "output": str(args.held_dir),
        "held": True,
        # Dialogue comparison ranks regular episodes; a person confirms specials.
        "special": True,
        "identification": identification,
    }


def build_plan(args: argparse.Namespace, source: Path,
               renew_lease: Any | None = None) -> dict[str, Any]:
    titles = scan_titles(args.handbrake, source, renew_lease,
                         getattr(args, "lease_seconds", 120) / 3)
    hints = source_hints(source)
    trailing_existing = None
    if hints.trailing_series is not None:
        trailing_name = strip_trailing_series_token(hints.name, hints.trailing_series)
        trailing_existing = find_existing_series(args.shows_dir, trailing_name)
    selected, dominant, ratio = prepare_titles(
        titles,
        hints,
        args.min_duration,
        args.dominant_ratio,
        allow_trailing_tv=trailing_existing is not None,
    )
    # M1: when the ISO filename already carries Jellyfin-style signals the user
    # curated, bypass TVmaze so the user's chosen library name is preserved
    # instead of being silently overridden by the looked-up series name.
    episode_like = looks_like_episode_set(selected)
    # Episodes plus short extras. Not for a name with an explicit episode
    # range: the person counted the titles, and `prepare_titles` already
    # checked that count. Applied only once the disc is filed as TV.
    core = None
    if not dominant and not episode_like and hints.last_episode is None:
        core = episode_core(selected)
        episode_like = core is not None
    if not hints.is_jellyfin_named:
        metadata = tvmaze_match(hints, len(core or selected), args.metadata_timeout)
    else:
        metadata = None
    # A bare trailing series identifier (e.g. ``Rumpole ... IV``) only encodes
    # the season when the disc content is actually TV-like (episode durations).
    # Movie sequels keep their title number (``Mission Impossible 2``).
    tv_content = not dominant and episode_like
    trailing_season = (
        hints.trailing_series
        if hints.trailing_series is not None
        and trailing_existing is not None
        and tv_content
        else None
    )
    season = hints.season if hints.season is not None else trailing_season
    is_tv = season is not None or (tv_content and hints.trailing_series is None)
    if is_tv and core is not None:
        print(f"Treating DVD titles {[title.index for title in core]} as episodes; "
              f"the shorter titles {[title.index for title in selected if title not in core]} "
              "are extras")
        selected = core

    if is_tv:
        tv_name = strip_trailing_series_token(hints.name, season)
        # M2: when the filename lacks canonical Jellyfin formatting, fall back to
        # matching this ISO against an existing Jellyfin library folder so
        # subsequent discs of the same series (e.g. Rumpole series 3 / IV)
        # chain into the same folder; otherwise trust the cured filename or
        # TVmaze look-up.
        existing = find_existing_for_hints(
            args.shows_dir,
            hints,
            tv_name,
        )
        if existing is not None:
            name, year, provider = existing
        elif hints.is_jellyfin_named:
            name, year, provider = tv_name, hints.year, hints.provider
        elif metadata:
            show = metadata["show"]
            name = str(show.get("name") or tv_name)
            premiered = str(show.get("premiered") or "")
            year = int(premiered[:4]) if premiered[:4].isdigit() else hints.year
            provider = provider_id(show)
        else:
            name, year, provider = tv_name, hints.year, hints.provider
        season = 1 if season is None else season
        # A person who wrote explicit episode numbers into the ISO name has
        # already identified the disc. Everything else is identified from the
        # disc itself, and held out of the library when that is not certain.
        curated_episodes = hints.is_jellyfin_named and hints.episode is not None
        if identification_enabled(args) and not curated_episodes:
            identification = identify_disc(args, source, selected, hints, renew_lease)
            titles = [title.index for title in selected]
            assignments = identified_assignments(identification, titles)
            numbering = numbering_hold(args.shows_dir, identification) \
                if assignments is not None else None
            if numbering is not None:
                identification, assignments = numbering, None
            if assignments is not None:
                name, year, provider = library_identity(args.shows_dir, identification["series"])
                return {
                    "kind": "tv",
                    "name": name,
                    "year": year,
                    "provider": provider,
                    "season": assignments[0]["season"],
                    "first_episode": assignments[0]["episode"],
                    "last_episode": assignments[-1]["episode"],
                    "episode_names": [
                        str(a.get("name") or f"DVD Title {title.index:02d}")
                        for a, title in zip(assignments, selected)
                    ],
                    "titles": titles,
                    "dominant_ratio": ratio,
                    "output": str(args.shows_dir),
                    "identification": identification,
                }
            # Encode into the holding folder under the ISO's own (unique)
            # name; the dialogue is compared once the episodes exist.
            return {
                "kind": "tv",
                "name": safe_name(source.stem),
                "year": None,
                "provider": None,
                "season": 1,
                "first_episode": 1,
                "last_episode": None,
                "episode_names": [f"DVD Title {title.index:02d}" for title in selected],
                "titles": titles,
                "dominant_ratio": ratio,
                "output": str(args.held_dir),
                "held": True,
                # The dialogue could only confirm the same TVmaze numbering.
                **({"numbering_conflict": True} if numbering is not None else {}),
                "identification": identification,
            }
        media_name = jellyfin_name(name, year, provider)
        first = hints.episode or existing_next_episode(args.shows_dir, media_name, season)
        if first is None:
            first = ((hints.disc or 1) - 1) * len(selected) + 1
        by_number = {
            (int(episode["season"]), int(episode["number"])): str(episode.get("name") or "")
            for episode in (metadata or {}).get("episodes", [])
            if episode.get("season") is not None and episode.get("number") is not None
        }
        # A curated name skips TVmaze above; its titles come from the list
        # that matches the folder's numbering, else stay placeholders.
        looked_up = (episode_names_for(args, name, year, provider, season, first,
                                       len(selected), iso_owner(source))
                     if metadata is None else [""] * len(selected))
        names = [
            by_number.get((season, first + offset)) or looked_up[offset]
            or f"DVD Title {title.index:02d}"
            for offset, title in enumerate(selected)
        ]
        return {
            "kind": "tv",
            "name": name,
            "year": year,
            "provider": provider,
            "season": season,
            "first_episode": first,
            "last_episode": hints.last_episode,
            "episode_names": names,
            "titles": [title.index for title in selected],
            "dominant_ratio": ratio,
            "output": str(args.shows_dir),
        }

    # A single feature named after an existing show is one of its specials
    # (``Rumpole's Return`` is Rumpole of the Bailey S00E03), not a film.
    if dominant and len(selected) == 1:
        special = special_plan(args, source, hints, selected[0], ratio)
        if special is not None:
            return special
    existing = find_existing_for_hints(
        args.movies_dir,
        hints,
        hints.name,
    )
    if existing is not None:
        name, year, provider = existing
    else:
        name, year, provider = hints.name, hints.year, hints.provider
    return {
        "kind": "movie",
        "name": name,
        "year": year,
        "provider": provider,
        "movie_disc": hints.disc,
        "titles": [title.index for title in selected],
        "dominant_ratio": ratio,
        "output": str(args.movies_dir),
    }


def converter_command(
    args: argparse.Namespace, source: Path, plan: dict[str, Any], queued: list[str] | None = None
) -> list[str]:
    command = [
        args.converter,
        str(source),
        "--yes",
        "--kind",
        plan["kind"],
        "--name",
        plan["name"],
        "--output",
        plan["output"],
        "--profile",
        args.profile,
        "--video-preset",
        args.video_preset,
        "--min-duration",
        str(args.min_duration),
        "--title",
        ",".join(str(index) for index in plan["titles"]),
    ]
    if args.staging_dir:
        command += ["--staging-dir", str(args.staging_dir)]
    command += [
        "--queue-directory",
        str(args.input_dir),
        "--active-queue-item",
        source.name,
    ]
    for title in queued or []:
        command += ["--queue-item", title]
    if plan.get("year"):
        command += ["--year", str(plan["year"])]
    if plan.get("provider"):
        command += ["--provider-id", plan["provider"]]
    if plan["kind"] == "tv":
        command += ["--season", str(plan["season"]), "--first-episode", str(plan["first_episode"])]
        for name in plan["episode_names"]:
            command += ["--episode-name", name]
    elif plan.get("movie_disc"):
        command += ["--movie-disc", str(plan["movie_disc"])]
    if args.progress_file:
        command += ["--progress-file", str(args.progress_file)]
    return command


def public_status(
    args: argparse.Namespace,
    state: str,
    plan: dict[str, Any] | None = None,
    queued: list[str] | None = None,
) -> None:
    if not args.progress_file:
        return
    conversions: list[dict[str, Any]] = []
    if state == "converting" and plan:
        conversions.append(
            {
                "title": str(plan["name"]),
                "mediaKind": str(plan["kind"]),
                "itemName": "Preparing encode",
                "itemIndex": 1,
                "itemCount": max(len(plan.get("titles", [])), 1),
                "percent": 0,
                "itemPercent": 0,
                "etaSeconds": None,
                "rateFps": None,
            }
        )
    payload: dict[str, Any] = {
        "schemaVersion": 1,
        "state": state,
        "updatedAt": int(time.time()),
        "conversions": conversions,
    }
    if queued:
        payload["queued"] = queued
    try:
        atomic_json(args.progress_file, payload)
    except OSError as error:
        print(f"Progress reporting unavailable: {error}", file=sys.stderr)


def iso_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def find_duplicate(
    source: Path,
    processed_dir: Path,
    source_hash: str | None,
    cached_hashes: dict[str, str],
) -> tuple[str | None, str | None, dict[str, str], set[str]]:
    """Return the name of a processed ISO identical to *source*, else None.

    Hashes are cached in durable state keyed by the archived ISO filename, so
    only new or matching-size ISOs are ever read. A size pre-filter avoids
    hashing the source when nothing in _Processed could match it.
    """
    live = {path.name for path in processed_dir.glob("*.iso")}
    source_size = source.stat().st_size
    candidates = sorted(
        (
            path
            for path in processed_dir.glob("*.iso")
            if path.stat().st_size == source_size
        ),
        key=lambda path: natural_key(path.name),
    )
    if not candidates:
        return None, source_hash, {}, live
    source_hash = source_hash or iso_sha256(source)
    calculated: dict[str, str] = {}
    for iso_path in candidates:
        digest = cached_hashes.get(iso_path.name)
        if digest is None:
            digest = iso_sha256(iso_path)
            calculated[iso_path.name] = digest
        if digest == source_hash:
            return iso_path.name, source_hash, calculated, live
    return None, source_hash, calculated, live


def completed_jobs_for_iso(
    args: argparse.Namespace,
    input_name: str,
    input_size: int,
) -> list[dict[str, Any]]:
    """Return completed, live MKV jobs safely contained by a Jellyfin library."""
    jobs_dir = args.state_dir / "disc-to-jellyfin/jobs"
    if not jobs_dir.is_dir():
        return []
    roots = (
        ("_Movies", args.movies_dir.resolve()),
        ("_Shows", args.shows_dir.resolve()),
    )
    jobs: list[dict[str, Any]] = []
    for manifest_path in jobs_dir.glob("*.job.json"):
        try:
            raw = json.loads(manifest_path.read_text(encoding="utf-8"))
            title = raw.get("title") if isinstance(raw, dict) else None
            if (
                not isinstance(raw, dict)
                or raw.get("completed") is not True
                or raw.get("input_size") != input_size
                or not isinstance(title, int)
                or isinstance(title, bool)
                or title < 1
                or not isinstance(raw.get("input"), str)
                or Path(raw["input"]).name != input_name
                or not isinstance(raw.get("output"), str)
            ):
                continue
            output = Path(raw["output"])
            if output.is_symlink() or output.suffix.casefold() != ".mkv":
                continue
            resolved = output.resolve(strict=True)
            if not resolved.is_file():
                continue
            for library_name, root in roots:
                try:
                    relative = resolved.relative_to(root)
                except ValueError:
                    continue
                jobs.append(
                    {
                        "title": title,
                        "output": resolved,
                        "library": library_name,
                        "relative": relative,
                    }
                )
                break
        except (OSError, ValueError, TypeError, json.JSONDecodeError) as error:
            print(
                f"Ignoring unreadable mkvmaker job manifest {manifest_path}: {error}",
                file=sys.stderr,
            )
    return jobs


def quarantine_duplicate_outputs(
    args: argparse.Namespace,
    duplicate_name: str,
    canonical_name: str,
    input_size: int,
    duplicate_dir: Path,
) -> list[dict[str, str]]:
    """Move outputs proven to be duplicate decodes into a review subtree.

    A duplicate-side output is moved only when a completed manifest for the
    canonical byte-identical ISO has the same DVD title number and its output
    still exists. Equal ISO basenames are intentionally left alone because old
    manifests cannot distinguish which upload produced the output.
    """
    if duplicate_name == canonical_name:
        return []
    canonical_by_title: dict[Any, list[Path]] = {}
    for job in completed_jobs_for_iso(args, canonical_name, input_size):
        canonical_by_title.setdefault(job["title"], []).append(job["output"])

    quarantined: list[dict[str, str]] = []
    moved: set[Path] = set()
    for job in completed_jobs_for_iso(args, duplicate_name, input_size):
        output = job["output"]
        if output in moved:
            continue
        canonical_outputs = [
            path for path in canonical_by_title.get(job["title"], []) if path != output
        ]
        if not canonical_outputs:
            continue
        destination_dir = duplicate_dir / job["library"] / job["relative"].parent
        destination_dir.mkdir(parents=True, exist_ok=True)
        destination = unique_destination(destination_dir, output.name)
        os.replace(output, destination)
        moved.add(output)
        quarantined.append(
            {
                "original": str(output),
                "quarantined": str(destination),
                "canonicalOutput": str(canonical_outputs[0]),
            }
        )
    return quarantined


def write_duplicate_report(
    archived: Path,
    canonical_name: str,
    quarantined: list[dict[str, str]],
    cleanup_error: str | None = None,
) -> None:
    report: dict[str, Any] = {
        "duplicateIso": archived.name,
        "duplicateOf": canonical_name,
        "quarantinedOutputs": quarantined,
    }
    if cleanup_error:
        report["cleanupError"] = cleanup_error
    archived.with_suffix(".iso.duplicate.json").write_text(
        json.dumps(report, indent=2) + "\n",
        encoding="utf-8",
    )


def unique_destination(directory: Path, name: str) -> Path:
    candidate = directory / name
    counter = 2
    while candidate.exists() or candidate.is_symlink():
        candidate = directory / f"{Path(name).stem}-{counter}{Path(name).suffix}"
        counter += 1
    return candidate


def identified_iso_name(plan: dict[str, Any]) -> str | None:
    """Jellyfin-style archive name for a disc whose episodes were identified."""
    if plan.get("kind") != "tv" or (plan.get("identification") or {}).get("status") != "identified":
        return None
    first = plan.get("first_episode")
    count = len(plan.get("titles") or [])
    if not isinstance(first, int) or not isinstance(plan.get("season"), int) or count == 0:
        return None
    last = first + count - 1
    episodes = f"S{plan['season']:02d}E{first:02d}" + (f"-E{last:02d}" if last != first else "")
    media = jellyfin_name(str(plan.get("name") or ""), plan.get("year"), plan.get("provider"))
    return safe_name(f"{media} {episodes}") + ".iso"


def archive_source(source: Path, directory: Path, plan: dict[str, Any] | None = None,
                   name: str | None = None) -> Path:
    directory.mkdir(parents=True, exist_ok=True)
    destination = unique_destination(directory, name or source.name)
    os.replace(source, destination)
    sidecar = ripper_sidecar(source)
    if sidecar.is_file():
        try:
            os.replace(sidecar, ripper_sidecar(destination))
        except OSError as error:
            print(f"Could not move {sidecar.name} with its ISO: {error}", file=sys.stderr)
    move_checksum(checksum_manifest(source), destination)
    if plan:
        # Informational only, and the ISO has already moved: a failure here
        # must not make the caller treat the archive as undone.
        manifest = destination.with_name(destination.name + ".output.json")
        try:
            manifest.write_text(
                json.dumps({
                    "sourceIso": source.name,
                    "outputDir": plan.get("output", ""),
                    "title": plan.get("name", ""),
                    "kind": plan.get("kind", ""),
                    "mediaDir": plan.get("media_dir", ""),
                    "finishedAt": int(time.time()),
                }),
                encoding="utf-8",
            )
        except OSError as error:
            print(f"Could not write {manifest.name}: {error}", file=sys.stderr)
    return destination


def process_source(
    args: argparse.Namespace,
    source: Path,
    entry: dict[str, Any],
    queued: list[str] | None = None,
    renew_lease: Any | None = None,
) -> None:
    plan = entry.get("plan")
    if not isinstance(plan, dict):
        plan = build_plan(args, source, renew_lease)
        entry["plan"] = plan
        entry["status"] = "planned"
    if plan.get("published") or plan.get("needs_identification"):
        # A retry after the held episodes were published or parked: the
        # encode is done and its outputs have moved; only archiving remains.
        return
    print(
        f"Selected DVD titles {plan['titles']} as {plan['kind']} "
        f"(largest/runtime={plan['dominant_ratio']:.1%})"
    )
    public_status(args, "converting", plan, queued)
    if renew_lease is not None and not renew_lease():
        raise LeaseLost(f"queue lease for {source.name} was lost before conversion")
    command = converter_command(args, source, plan, queued)
    process = subprocess.Popen(
        command,
        env={**os.environ, "MKVMAKER_WORKER_ID": args.worker_id},
        start_new_session=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    output = ConverterOutput()
    reader = threading.Thread(target=output.pump, args=(process.stdout,), daemon=True)
    reader.start()
    renew_after = time.monotonic() + max(1.0, args.lease_seconds / 3)
    deadline = time.monotonic() + 24 * 3600
    try:
        while True:
            if shutdown_signal is not None:
                raise ShutdownRequested(f"received {signal.Signals(shutdown_signal).name}")
            if time.monotonic() >= deadline:
                raise RuntimeError("converter exceeded 24-hour deadline")
            if renew_lease is not None and time.monotonic() >= renew_after:
                if not renew_lease():
                    raise LeaseLost(f"queue lease for {source.name} could not be renewed")
                renew_after = time.monotonic() + max(1.0, args.lease_seconds / 3)
            try:
                return_code = process.wait(timeout=0.5)
                break
            except subprocess.TimeoutExpired:
                continue
    except BaseException:
        stop_process_tree(process)
        reader.join(timeout=5)
        raise
    reader.join(timeout=30)
    if return_code in (130, -signal.SIGINT, -signal.SIGTERM):
        raise ShutdownRequested(f"converter stopped with status {return_code}")
    if return_code != 0:
        raise ConverterFailed(return_code, output.errors, list(output.tail))
    if output.planned:
        folder = os.path.commonpath(output.planned)
        if folder in output.planned:
            folder = os.path.dirname(folder)
        plan["media_dir"] = folder
    if plan.get("held"):
        finish_held(args, source, plan, list(output.planned), renew_lease)


def finish_held(args: argparse.Namespace, source: Path, plan: dict[str, Any],
                videos: list[str], renew_lease: Any | None) -> None:
    """Compare a held disc's dialogue, then publish it or park it for a person."""
    disc_outcome = plan.get("identification") or None
    content_outcome: dict[str, Any] | None = None
    if len(videos) != len(plan["titles"]):
        result = dict(plan.get("identification") or {})
        result["reasons"] = [*(result.get("reasons") or []),
                             "the converter's outputs could not be matched to the titles"]
    elif plan.get("special") or plan.get("numbering_conflict"):
        result = dict(plan.get("identification") or {})
    else:
        result = identify_content(args, source, plan, videos, renew_lease)
        content_outcome = result
        # Keep what the menus showed alongside what the dialogue showed.
        earlier = (plan.get("identification") or {}).get("reasons") or []
        result["reasons"] = list(dict.fromkeys([*earlier, *(result.get("reasons") or [])]))
        assignments = identified_assignments(result, plan["titles"])
        numbering = numbering_hold(args.shows_dir, result) if assignments is not None else None
        if numbering is not None:
            result, assignments = numbering, None
        if assignments is not None:
            name, year, provider = library_identity(args.shows_dir, result["series"])
            try:
                season_dir = publish_episodes(
                    args, [Path(video) for video in videos], name, year, provider,
                    assignments[0]["season"], assignments[0]["episode"],
                    [str(a.get("name") or "") for a in assignments],
                )
            except (OSError, RuntimeError) as error:
                # Usually the library already holds these episodes. Keep the
                # encode held for a person rather than failing the disc and
                # orphaning its videos.
                print(f"Could not publish identified episodes: {error}", file=sys.stderr)
                result = dict(result, summary=f"{result.get('summary') or 'Identified'} "
                              "It could not be published, so it was held instead.")
                result["reasons"] = [*result["reasons"], f"publishing failed: {error}"]
                season_dir = None
        if assignments is not None and season_dir is not None:
            plan.update(
                name=name, year=year, provider=provider, season=assignments[0]["season"],
                first_episode=assignments[0]["episode"], output=str(args.shows_dir),
                media_dir=str(season_dir.parent), held=False, published=True,
                identification=result,
                identify_outcomes={"disc": disc_outcome, "content": content_outcome},
            )
            if renew_lease is not None:
                renew_lease()  # persist "published" before the ISO is archived
            return
    shared_root = args.held_dir.parent.parent
    held_folder = Path(videos[0]).parent.parent if videos else args.held_dir / plan["name"]
    reasons = [str(reason) for reason in (result.get("reasons") or [])]
    plan["needs_identification"] = {
        "schemaVersion": EVIDENCE_SCHEMA_VERSION,
        "status": "held",
        "sourceIso": source.name,
        "heldDir": os.path.relpath(held_folder, shared_root),
        "heldFiles": videos,
        "titles": plan["titles"],
        "summary": str(result.get("summary") or "The episodes could not be identified."),
        "reasons": reasons[:12],
        "suggestion": held_suggestion(result, len(plan["titles"]), args.shows_dir, disc_outcome),
        "outcomes": {"disc": disc_outcome, "content": content_outcome},
        "retry": classify_reasons(reasons),
        # A person confirms specials; retries re-run the regular-episode stages.
        **({"special": True} if plan.get("special") else {}),
    }
    if renew_lease is not None:
        renew_lease()


def initial_retry(classification: Any, now: int) -> dict[str, Any]:
    """Queue-state retry schedule for a newly held disc."""
    if isinstance(classification, dict) and classification.get("retryable"):
        return {"state": "scheduled", "attempts": 0, "nextAt": now + RETRY_DELAYS[0]}
    return {"state": "not retryable", "attempts": 0}


def retry_view(classification: dict[str, Any], retry: dict[str, Any]) -> dict[str, Any]:
    """The evidence file's `retry` object: why, and what happens next."""
    return {
        **{key: classification.get(key) for key in
           ("retryable", "transientReasons", "substantiveReasons")},
        "state": retry.get("state"),
        "attempts": int(retry.get("attempts") or 0),
        "maxAttempts": len(RETRY_DELAYS),
        "nextAttemptAt": retry.get("nextAt") if retry.get("state") == "scheduled" else None,
    }


def park_for_identification(args: argparse.Namespace, source: Path,
                            record: dict[str, Any], state: dict[str, Any]) -> Path:
    """Move the ISO to _NeedsIdentification with its evidence for the UI."""
    archived = archive_source(source, needs_dir(args))
    now = int(time.time())
    classification = record.get("retry") if isinstance(record.get("retry"), dict) else {}
    retry = initial_retry({} if record.get("special") else classification, now)
    evidence = dict(record, finishedAt=now, retry=retry_view(classification, retry))
    identify_path = archived.with_name(archived.name + ".identify.json")
    atomic_json(identify_path, evidence)
    state.setdefault("held", {})[held_record_key(archived)] = {
        "retry": retry,
        "identify": identify_path.name,
        "sidecar": ripper_sidecar(archived).name,
        "checksum": checksum_manifest(archived).name,
        "files": record.get("heldFiles", []),
        "titles": record.get("titles", []),
        "heldDir": record.get("heldDir", ""),
        **({"special": True} if record.get("special") else {}),
        # Renaming keeps the modification time; a different ISO that later
        # reuses the inode number does not, so it never publishes these videos.
        "mtimeNs": archived.stat().st_mtime_ns,
    }
    return archived


def held_provider(identify_path: Path) -> str | None:
    """The provider the importer identified for this disc, if it recorded one.

    The suggested ISO name no longer repeats the provider tag, so this keeps
    the series folder's Jellyfin identifier when a person renames the held ISO.
    """
    try:
        evidence = json.loads(identify_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None
    suggestion = evidence.get("suggestion") if isinstance(evidence, dict) else None
    if not isinstance(suggestion, dict):
        return None
    provider = suggestion.get("provider")
    if not isinstance(provider, str) or parse_provider(f"[{provider}]") != provider:
        return None
    return provider


def read_evidence(identify_path: Path) -> dict[str, Any]:
    """A held disc's evidence; {} when missing, unreadable or a link.

    The folder is writable by people; never follow a link placed there.
    """
    if identify_path.is_symlink():
        return {}
    try:
        evidence = json.loads(identify_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}
    return evidence if isinstance(evidence, dict) else {}


def move_evidence(identify_path: Path, destination: Path, updates: dict[str, Any]) -> None:
    """Archive a held disc's evidence beside its ISO, recording how it ended."""
    if not identify_path.is_file() and not identify_path.is_symlink():
        return
    evidence = read_evidence(identify_path)
    evidence.update(updates)
    try:
        atomic_json(destination, evidence)
    except OSError as error:
        print(f"Could not archive {identify_path.name}: {error}", file=sys.stderr)
        return
    identify_path.unlink(missing_ok=True)


def note_identification_problem(identify_path: Path, message: str) -> None:
    # The folder is writable by people; never follow a link placed there.
    evidence: Any = {"schemaVersion": 1}
    if not identify_path.is_symlink():
        try:
            evidence = json.loads(identify_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            pass
    if not isinstance(evidence, dict):
        evidence = {"schemaVersion": 1}
    if evidence.get("summary") == message:
        return
    evidence["summary"] = message
    try:
        atomic_json(identify_path, evidence)
    except OSError:
        pass


EPISODE_LOOKUP_SECONDS = 30


def provider_episodes(args: argparse.Namespace, name: str, year: int | None,
                      provider: str | None, owner: str | None) -> dict[str, Any] | None:
    """A series' episode list from ``disc-identify episodes``, or None.

    Best-effort: a missing identifier or broker, an error, or a timeout only
    costs the episode titles, never the conversion.
    """
    identifier = getattr(args, "identifier", None)
    socket = getattr(args, "subtitle_socket", None)
    if not identifier or not socket:
        return None
    command = [identifier, "episodes", "--series", provider or "",
               "--provider-socket", socket,
               "--cache-dir", str(args.state_dir / "identify-cache")]
    # TMDB answers with the uploader's saved account.
    if owner:
        command += ["--owner", owner]
    if name:
        command += ["--name", name]
    if year:
        command += ["--year", str(year)]
    try:
        completed = subprocess.run(
            command, capture_output=True, text=True, encoding="utf-8", errors="replace",
            timeout=EPISODE_LOOKUP_SECONDS, check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        print(f"Episode list unavailable for {name!r}: {error}", file=sys.stderr)
        return None
    try:
        result = json.loads(completed.stdout) if completed.returncode == 0 else None
    except json.JSONDecodeError:
        result = None
    if not isinstance(result, dict) or result.get("schemaVersion") != 1:
        detail = (completed.stderr or "").strip()[-300:] or (
            f"status {completed.returncode}" if completed.returncode else "unexpected output")
        print(f"Episode list unavailable for {name!r}: {detail}", file=sys.stderr)
        return None
    for reason in result.get("reasons") or []:
        print(f"  episode list: {reason}")
    return result


def library_episodes(result: dict[str, Any] | None, year: int | None,
                     provider: str | None) -> dict[tuple[int, int], str]:
    """Episode titles by (season, episode), only where they fit the folder.

    Jellyfin numbers episodes as TMDB does, so a "tmdb" list always fits. A
    TVmaze list fits only a folder without a ``tmdbid`` tag: that folder is
    in TMDB's layout, which can differ (Sherlock Holmes (1984) has 4 TVmaze
    seasons but 7 on TMDB), so its S/E titles would name the wrong episodes.
    """
    if not isinstance(result, dict):
        return {}
    tmdb_folder = isinstance(provider, str) and provider.startswith("tmdbid-")
    layout = result.get("layout")
    if layout != "tmdb" and not (layout == "tvmaze" and not tmdb_folder):
        return {}
    series = result.get("series") if isinstance(result.get("series"), dict) else {}
    if tmdb_folder and isinstance(series.get("tmdbId"), int) \
            and f"tmdbid-{series['tmdbId']}" != provider:
        return {}
    if provider is None and year is not None and isinstance(series.get("year"), int) \
            and series["year"] != year:
        return {}
    titles: dict[tuple[int, int], str] = {}
    for episode in result.get("episodes") or []:
        if not isinstance(episode, dict):
            continue
        number = (episode.get("season"), episode.get("episode"))
        title = episode.get("name")
        if all(isinstance(n, int) and not isinstance(n, bool) for n in number) \
                and isinstance(title, str) and title.strip():
            titles[number] = title.strip()
    return titles


def episode_names_for(args: argparse.Namespace, name: str, year: int | None,
                      provider: str | None, season: int, first: int, count: int,
                      owner: str | None) -> list[str]:
    """Best-effort titles for episodes whose numbers a person chose; "" if unknown."""
    titles = library_episodes(provider_episodes(args, name, year, provider, owner),
                              year, provider)
    return [titles.get((season, first + offset), "") for offset in range(count)]


def resolve_renamed_holds(args: argparse.Namespace, lock_path: Path, state_path: Path,
                          processed_dir: Path) -> None:
    """Publish held episodes once a person renames their ISO with episode numbers.

    In _NeedsIdentification, renaming ``X.iso`` to ``Show (1978) S01E05-E06.iso``
    moves the held videos into the library without re-encoding them.
    """
    directory = needs_dir(args)
    if not directory.is_dir():
        return
    with locked_queue(lock_path):
        state = load_state(state_path)
        records = state.get("held")
        if not isinstance(records, dict) or not records:
            return
        live: set[str] = set()
        isos = [path for path in directory.iterdir()
                if path.suffix.lower() == ".iso" and path.is_file() and not path.is_symlink()]
        for iso in sorted(isos, key=lambda path: natural_key(path.name)):
            try:
                key = held_record_key(iso)
            except OSError:
                continue
            live.add(key)
            record = records.get(key)
            if not isinstance(record, dict):
                continue
            if isinstance(record.get("retry"), dict) and record["retry"].get("publishing"):
                continue  # an automatic retry's publish is finished first
            if isinstance(record.get("mtimeNs"), int) and iso.stat().st_mtime_ns != record["mtimeNs"]:
                continue
            try:
                hints = source_hints(iso)
            except ValueError:
                continue
            if hints.season is None or hints.episode is None:
                continue
            # Media Manager renames the evidence with the ISO so its page keeps
            # the disc's details; a rename in Files leaves the original name.
            identify_path = directory / f"{iso.name}.identify.json"
            if not identify_path.is_file() or identify_path.is_symlink():
                identify_path = directory / str(record.get("identify") or identify_path.name)
            files = [Path(item) for item in record.get("files", [])]
            count = len(files)
            last = hints.last_episode if hints.last_episode is not None else hints.episode + count - 1
            if count == 0 or last - hints.episode + 1 != count:
                note_identification_problem(
                    identify_path,
                    f"The new name covers {last - hints.episode + 1} episode(s), "
                    f"but this disc holds {count}. Name the full range, e.g. "
                    f"S{hints.season:02d}E{hints.episode:02d}-E{hints.episode + count - 1:02d}.",
                )
                continue
            existing = find_existing_for_hints(args.shows_dir, hints, hints.name)
            name, year, provider = existing or (hints.name, hints.year, hints.provider)
            if provider is None:
                # The suggested ISO name leaves the provider tag out so the
                # person's name stays readable; the disc's own evidence still
                # carries it into the series folder Jellyfin matches on.
                provider = held_provider(identify_path)
            names = episode_names_for(args, name, year, provider,
                                      hints.season, hints.episode, count, iso_owner(iso))
            try:
                season_dir = publish_episodes(args, files, name, year, provider,
                                              hints.season, hints.episode, names)
            except (OSError, RuntimeError) as error:
                note_identification_problem(identify_path, f"Could not publish the episodes: {error}")
                continue
            archived = archive_source(iso, processed_dir, {
                "kind": "tv", "name": name, "output": str(args.shows_dir),
                "media_dir": str(season_dir.parent),
            })
            move_evidence(identify_path, archived.with_name(archived.name + ".identify.json"), {
                "status": "confirmed",
                "resolution": evidence_resolution("rename", name, year, provider,
                                                  hints.season, hints.episode, count),
            })
            # The ripper's evidence keeps the ISO's original name.
            original_sidecar = directory / str(record.get("sidecar") or "")
            if record.get("sidecar") and original_sidecar.is_file():
                os.replace(original_sidecar, ripper_sidecar(archived))
            if record.get("checksum"):
                move_checksum(directory / str(record["checksum"]), archived)
            del records[key]
            # Save at once: a later disc's slow copy must not leave this one
            # recorded as still held if the worker is stopped mid-way.
            state["held"] = records
            atomic_json(state_path, state)
            print(f"Published held episodes of {iso.name} to {season_dir}")
        # Forget holds whose ISO is gone and whose held videos are gone too.
        # While the videos exist the record is the only map from ISO to
        # videos, so it is kept.
        for stale in set(records) - live:
            files = records[stale].get("files", []) if isinstance(records[stale], dict) else []
            if not any(Path(str(item)).is_file() for item in files):
                del records[stale]
        state["held"] = records
        atomic_json(state_path, state)


def held_iso_for_key(directory: Path, key: str) -> Path | None:
    """The ISO in _NeedsIdentification that a held record belongs to, by inode."""
    try:
        entries = list(directory.iterdir())
    except OSError:
        return None
    for path in entries:
        if path.suffix.lower() != ".iso" or path.is_symlink() or not path.is_file():
            continue
        try:
            if held_record_key(path) == key:
                return path
        except OSError:
            continue
    return None


def bonsai_gate_busy(args: argparse.Namespace) -> bool:
    """True while the Bonsai gate is serving or queueing someone else's work.

    A retry is background work, so it waits for an idle gate instead of
    adding to its queue. An unreachable gate is not "busy": the attempt runs
    and fails as a transient problem, which keeps the retries bounded.
    """
    url = getattr(args, "bonsai_url", None)
    if not url:
        return False
    base = url.rstrip("/").removesuffix("/v1")
    try:
        health = fetch_json(f"{base}/health", 5)
    except Exception:  # noqa: BLE001 - no health endpoint means no gate to honour
        return False
    if not isinstance(health, dict):
        return False
    return bool(health.get("queued")) or health.get("available_permits") == 0


# How long retries defer to other Bonsai work. Media Manager's photo-tag
# review (2026-11-17) kept the gate's queue full for hours, which would
# have postponed every retry indefinitely; after this long one retry joins
# the queue like any other request, then the wait starts again.
BUSY_GATE_PATIENCE_SECONDS = 3600


# Attempts given back because Bonsai was only busy, per hold (about a day
# of hourly forced retries) before busy failures count like any other.
BUSY_GATE_REFUNDS = 24
_BUSY_GATE_RE = re.compile(
    r"^(?:Title \d+: )?Bonsai (?:could not [a-z ]+|ranking failed): .*HTTP (?:429|503|504)")


def busy_gate_only(classification: dict[str, Any]) -> bool:
    """Every temporary blocker was the Bonsai gate answering busy."""
    transient = classification.get("transientReasons") or []
    return bool(transient) and all(_BUSY_GATE_RE.search(str(r)) for r in transient)


def postpone_for_busy_gate(args: argparse.Namespace, now: int) -> bool:
    """True when a retry should wait for the Bonsai gate to be idle."""
    marker = args.state_dir / "retry-bonsai-busy-since"
    if not bonsai_gate_busy(args):
        marker.unlink(missing_ok=True)
        return False
    try:
        since = int(marker.read_text(encoding="utf-8").strip())
    except (OSError, ValueError):
        since = None
    if since is None or since > now:  # missing, unreadable, or from a clock that moved back
        since = now
        try:
            marker.write_text(str(now), encoding="utf-8")
        except OSError:
            pass
    if now - since < BUSY_GATE_PATIENCE_SECONDS:
        print("Bonsai is busy; postponing an automatic re-identification")
        return True
    # The gate queues two requests and answers 429/504 beyond that; the
    # identifier retries those for about eleven minutes. An attempt lost
    # only to a busy gate is given back (see `busy_gate_only`).
    print("Bonsai has been busy for over an hour; re-identifying anyway")
    marker.unlink(missing_ok=True)
    return False


def update_held_evidence(identify_path: Path, updates: dict[str, Any]) -> None:
    evidence = read_evidence(identify_path) or {"schemaVersion": 1}
    evidence.update(updates)
    try:
        atomic_json(identify_path, evidence)
    except OSError as error:
        print(f"Could not update {identify_path.name}: {error}", file=sys.stderr)


def reidentify_held(args: argparse.Namespace, directory: Path, iso: Path, record: dict[str, Any],
                    renew: Any) -> tuple[dict[str, Any], dict[str, Any], list[dict[str, Any]] | None]:
    """Identify a held disc again from its ISO and its already-encoded videos.

    Returns the final result, both stages' outcomes and the validated
    assignments (None when still uncertain). Nothing is re-encoded.
    """
    titles = [int(title) for title in record.get("titles") or []]
    files = [str(item) for item in record.get("files") or []]
    scanned = {title.index: title for title in scan_titles(
        args.handbrake, iso, renew, getattr(args, "lease_seconds", 120) / 3)}
    if not titles or any(title not in scanned for title in titles) or len(files) != len(titles):
        result = uncertain("The disc no longer matches its held videos.",
                           "the disc's titles changed since it was encoded")
        return result, {"disc": None, "content": None}, None
    hints = source_hints(iso)  # parseable: checked when the hold was chosen
    sidecar = directory / str(record.get("sidecar") or "")
    disc = identify_disc(args, iso, [scanned[title] for title in titles], hints, renew,
                         sidecar if record.get("sidecar") else None)
    assignments = identified_assignments(disc, titles)
    if assignments is not None:
        numbering = numbering_hold(args.shows_dir, disc)
        if numbering is not None:
            return numbering, {"disc": disc, "content": None}, None
        return disc, {"disc": disc, "content": None}, assignments
    content = identify_content(args, iso, {"titles": titles, "identification": disc}, files, renew)
    content["reasons"] = list(dict.fromkeys([*(disc.get("reasons") or []),
                                             *(content.get("reasons") or [])]))
    assignments = identified_assignments(content, titles)
    numbering = numbering_hold(args.shows_dir, content) if assignments is not None else None
    if numbering is not None:
        return numbering, {"disc": disc, "content": content}, None
    return content, {"disc": disc, "content": content}, assignments


def complete_retry_publish(args: argparse.Namespace, directory: Path, processed_dir: Path,
                           records: dict[str, Any], key: str) -> bool:
    """Publish a re-identified hold and archive its ISO; the caller holds
    queue.lock and saves the state afterwards.

    `retry.publishing` is saved before anything moves, so a run killed at any
    point resumes here: publish_episodes undoes or finishes its own partial
    work, an already published disc is only archived, and a disc whose ISO
    was already archived is only forgotten.

    False when the ISO could not be archived: `publishing` stays set, the
    error is recorded on the retry, and the caller tries again later.
    """
    record = records[key]
    retry = record["retry"]
    job = retry["publishing"]
    files = [Path(str(item)) for item in record.get("files") or []]
    titles = list(record.get("titles") or [])
    names = [str(name) for name in job.get("names") or []]
    season_dir, targets = episode_targets(args, len(files), job["name"], job.get("year"),
                                          job.get("provider"), job["season"], job["first"], names)
    published = bool(files) and all(target.exists() for target in targets) and not any(
        file.exists() or staging_name(target, file).exists()
        for file, target in zip(files, targets))
    identify_path = directory / str(record.get("identify") or "")
    if not published:
        try:
            publish_episodes(args, files, job["name"], job.get("year"), job.get("provider"),
                             job["season"], job["first"], names)
        except (OSError, RuntimeError) as error:
            retry.pop("publishing", None)
            retry.update(state="stopped", stoppedBecause=f"publishing failed: {error}")
            if record.get("identify"):
                update_held_evidence(identify_path, {
                    "summary": f"Identified automatically, but could not publish: {error}",
                    "retry": dict(read_evidence(identify_path).get("retry") or {},
                                  state="stopped", nextAttemptAt=None),
                })
            print(f"Could not publish re-identified episodes: {error}", file=sys.stderr)
            return True
    iso = held_iso_for_key(directory, key)
    if iso is not None:
        plan = {
            "kind": "tv", "name": job["name"], "year": job.get("year"),
            "provider": job.get("provider"), "season": job["season"],
            "first_episode": job["first"], "titles": titles,
            "identification": {"status": "identified"},
            "output": str(args.shows_dir), "media_dir": str(season_dir.parent),
        }
        try:
            archived = archive_source(iso, processed_dir, plan, identified_iso_name(plan))
        except OSError as error:
            retry.update(publishError=f"archiving the ISO failed: {error}",
                         publishFailedAt=int(time.time()))
            if record.get("identify"):
                update_held_evidence(identify_path, {
                    "summary": "Published to the library automatically, but the ISO could "
                               f"not be archived yet: {error}"})
            print(f"Could not archive {iso.name} after publishing it: {error}", file=sys.stderr)
            return False
        if record.get("identify"):
            move_evidence(identify_path, archived.with_name(archived.name + ".identify.json"), {
                "status": "identified",
                "resolution": evidence_resolution("automatic retry", job["name"], job.get("year"),
                                                  job.get("provider"), job["season"],
                                                  job["first"], len(files)),
                "finishedAt": int(time.time()),
            })
        original_sidecar = directory / str(record.get("sidecar") or "")
        if record.get("sidecar") and original_sidecar.is_file():
            try:
                os.replace(original_sidecar, ripper_sidecar(archived))
            except OSError as error:
                print(f"Could not move {original_sidecar.name} with its ISO: {error}",
                      file=sys.stderr)
        if record.get("checksum"):
            move_checksum(directory / str(record["checksum"]), archived)
        print(f"Published held episodes of {iso.name} to {season_dir} after re-identifying them")
    del records[key]
    return True


def retry_transient_holds(args: argparse.Namespace, lock_path: Path, state_path: Path,
                          processed_dir: Path) -> None:
    """Re-identify one held disc whose blockers were all temporary.

    Runs between claims, like resolve_renamed_holds. queue.lock is held only
    to choose, lease and settle the record, never while the identifier runs.
    The attempt is counted when it starts, so a crash cannot retry forever;
    a shutdown gives it back. A person's rename or deletion always wins: the
    record or ISO is re-checked before anything is published.
    """
    if shutdown_signal is not None:
        raise ShutdownRequested("shutdown before re-identifying held discs")
    directory = needs_dir(args)
    if not directory.is_dir():
        return
    now = int(time.time())

    def candidate(records: dict[str, Any]) -> tuple[str, Path] | None:
        for key in sorted(records):
            record = records[key]
            retry = record.get("retry") if isinstance(record, dict) else None
            if not isinstance(retry, dict) or retry.get("state") != "scheduled":
                continue
            if record.get("special"):
                retry.pop("lease", None)
                retry.update(state="stopped", stoppedBecause="a person confirms specials")
                continue
            lease = retry.get("lease")
            if isinstance(lease, dict) and int(lease.get("expiresAt") or 0) > now:
                continue  # another worker is on it
            if int(retry.get("nextAt") or 0) > now:
                continue
            iso = held_iso_for_key(directory, key)
            if iso is None or (isinstance(record.get("mtimeNs"), int)
                               and iso.stat().st_mtime_ns != record["mtimeNs"]):
                continue
            try:
                named = source_hints(iso)
            except ValueError:
                continue
            if named.season is not None and named.episode is not None:
                continue  # the person named it; resolve_renamed_holds publishes
            if not all(Path(str(item)).is_file() for item in record.get("files") or [None]):
                retry.pop("lease", None)
                retry.update(state="stopped", stoppedBecause="the held videos are missing")
                continue
            return key, iso
        return None

    with locked_queue(lock_path):
        state = load_state(state_path)
        records = state.get("held")
        if not isinstance(records, dict) or not records:
            return
        for key, record in list(records.items()):
            if not isinstance(record, dict):
                continue
            if "retry" not in record:
                # Held before automatic retries existed: judge its evidence.
                evidence = read_evidence(directory / str(record.get("identify") or ""))
                held_at = int(evidence.get("finishedAt") or now)
                record["retry"] = initial_retry(classify_reasons(evidence.get("reasons") or []),
                                                held_at)
            retry = record["retry"]
            lease = retry.get("lease") if isinstance(retry, dict) else None
            if (isinstance(retry, dict) and retry.get("state") == "scheduled"
                    and int(retry.get("attempts") or 0) >= len(RETRY_DELAYS)
                    and not (isinstance(lease, dict) and int(lease.get("expiresAt") or 0) > now)):
                # Only a run killed mid-attempt leaves a used-up record
                # scheduled; it would otherwise be retried forever.
                retry.pop("lease", None)
                retry.update(state="stopped", stoppedBecause="automatic attempts used up")
                if record.get("identify"):
                    identify_path = directory / str(record["identify"])
                    update_held_evidence(identify_path, {"retry": dict(
                        read_evidence(identify_path).get("retry") or {},
                        state="stopped", nextAttemptAt=None)})
            if isinstance(record["retry"], dict) and record["retry"].get("publishing"):
                # A publish was interrupted; finish it before anything else,
                # unless it failed recently: then the other holds go on.
                failed_at = int(record["retry"].get("publishFailedAt") or 0)
                if failed_at and now - failed_at < RETRY_DELAYS[0]:
                    continue
                if complete_retry_publish(args, directory, processed_dir, records, key):
                    atomic_json(state_path, state)
                    return
        chosen = candidate(records)
        atomic_json(state_path, state)
    if chosen is None:
        return
    if postpone_for_busy_gate(args, int(time.time())):
        return

    lease_id = secrets.token_hex(16)
    with locked_queue(lock_path):
        state = load_state(state_path)
        records = state.get("held")
        again = candidate(records) if isinstance(records, dict) else None
        if again is None or again[0] != chosen[0]:
            atomic_json(state_path, state)
            return
        key, iso = again
        retry = records[key]["retry"]
        retry["attempts"] = int(retry.get("attempts") or 0) + 1
        retry["lease"] = {"workerId": args.worker_id, "leaseId": lease_id,
                          "expiresAt": int(time.time()) + args.lease_seconds}
        retry["lastAttemptAt"] = int(time.time())
        record = dict(records[key])
        atomic_json(state_path, state)

    def owned(state: dict[str, Any]) -> dict[str, Any] | None:
        held = state.get("held")
        current = held.get(key) if isinstance(held, dict) else None
        retry = current.get("retry") if isinstance(current, dict) else None
        lease = retry.get("lease") if isinstance(retry, dict) else None
        if isinstance(lease, dict) and lease.get("workerId") == args.worker_id \
                and lease.get("leaseId") == lease_id:
            return current
        return None

    def renew() -> bool:
        with locked_queue(lock_path):
            state = load_state(state_path)
            current = owned(state)
            if current is None:
                return False
            current["retry"]["lease"]["expiresAt"] = int(time.time()) + args.lease_seconds
            atomic_json(state_path, state)
            return True

    print(f"Re-identifying held disc {iso.name} "
          f"(automatic attempt {retry['attempts']} of {len(RETRY_DELAYS)})")
    try:
        result, outcomes, assignments = reidentify_held(args, directory, iso, record, renew)
    except ShutdownRequested:
        with locked_queue(lock_path):
            state = load_state(state_path)
            current = owned(state)
            if current is not None:
                # Not this disc's fault: give the attempt back.
                current["retry"]["attempts"] = max(0, int(current["retry"]["attempts"]) - 1)
                current["retry"].pop("lease", None)
                atomic_json(state_path, state)
        raise
    except LeaseLost as error:
        print(f"Stopped re-identifying {iso.name}: {error}", file=sys.stderr)
        return
    except Exception as error:  # noqa: BLE001 - becomes a transient failure
        result = uncertain("Episode identification failed.", f"identifier error: {error}")
        outcomes, assignments = {"disc": None, "content": None}, None

    with locked_queue(lock_path):
        state = load_state(state_path)
        current = owned(state)
        if current is None:
            print(f"{iso.name} was resolved or removed while it was being re-identified")
            return
        retry = current["retry"]
        retry.pop("lease", None)
        records = state["held"]
        identify_path = directory / str(current.get("identify") or "")
        live_iso = held_iso_for_key(directory, key)
        if live_iso is None:
            retry.update(state="stopped", stoppedBecause="the ISO left _NeedsIdentification")
            atomic_json(state_path, state)
            return
        try:
            named = source_hints(live_iso)
        except ValueError:
            named = None
        if named is not None and named.season is not None and named.episode is not None:
            atomic_json(state_path, state)  # the person's name wins
            return
        reasons = [str(reason) for reason in (result.get("reasons") or [])]
        classification = classify_reasons(reasons)
        titles = list(current.get("titles") or [])
        evidence = {
            "schemaVersion": EVIDENCE_SCHEMA_VERSION,
            "summary": str(result.get("summary") or "The episodes could not be identified."),
            "reasons": reasons[:12],
            "suggestion": held_suggestion(result, len(titles), args.shows_dir,
                                          (outcomes or {}).get("disc")),
            "outcomes": outcomes,
            "lastRetryAt": int(time.time()),
        }
        if assignments is None:
            if (classification["retryable"] and busy_gate_only(classification)
                    and int(retry.get("busyRefunds") or 0) < BUSY_GATE_REFUNDS):
                # Lost only to a full Bonsai queue: the attempt does not count.
                retry["attempts"] = max(0, int(retry.get("attempts") or 0) - 1)
                retry["busyRefunds"] = int(retry.get("busyRefunds") or 0) + 1
            attempts = int(retry.get("attempts") or 0)
            if classification["retryable"] and attempts < len(RETRY_DELAYS):
                retry.update(state="scheduled", nextAt=int(time.time()) + RETRY_DELAYS[attempts])
            else:
                retry.update(state="stopped", stoppedBecause=(
                    "automatic attempts used up" if classification["retryable"]
                    else "no longer a temporary problem"))
            if current.get("identify"):
                update_held_evidence(identify_path, dict(
                    evidence, status="held", retry=retry_view(classification, retry)))
            atomic_json(state_path, state)
            print(f"  {live_iso.name} is still held: {evidence['summary']}")
            return
        name, year, provider = library_identity(args.shows_dir, result["series"])
        retry["publishing"] = {
            "name": name, "year": year, "provider": provider,
            "season": assignments[0]["season"], "first": assignments[0]["episode"],
            "names": [str(a.get("name") or "") for a in assignments],
        }
        retry["state"] = "identified"
        if current.get("identify"):
            update_held_evidence(identify_path, dict(
                evidence, status="held", retry=retry_view(classification, retry)))
        # Durable before any file moves; see complete_retry_publish.
        atomic_json(state_path, state)
        complete_retry_publish(args, directory, processed_dir, records, key)
        atomic_json(state_path, state)


class ConverterOutput:
    """Forward converter output to the journal while keeping what a report needs."""

    def __init__(self) -> None:
        self.tail: collections.deque[str] = collections.deque(maxlen=60)
        self.errors: list[str] = []
        self.planned: list[str] = []
        self._in_plan = False

    def pump(self, stream: Any) -> None:
        pending = b""
        for chunk in iter(lambda: stream.read1(65536), b""):
            try:
                sys.stdout.buffer.write(chunk)
                sys.stdout.flush()
            except (OSError, ValueError):
                pass  # Keep draining so the converter never blocks on a full pipe.
            pending += chunk
            *lines, pending = re.split(rb"[\r\n]", pending)
            for line in lines:
                self.record(line.decode("utf-8", "replace"))
            if len(pending) > 65536:
                pending = pending[-4096:]
        if pending:
            self.record(pending.decode("utf-8", "replace"))

    def record(self, line: str) -> None:
        line = line.rstrip()
        if not line.strip():
            self._in_plan = False
            return
        if line.startswith("Planned outputs"):
            self._in_plan = True
            self.planned = []
        elif self._in_plan and line.startswith("  /"):
            self.planned.append(line.strip())
        else:
            self._in_plan = False
        for prefix in ("ERROR: ", "Error: "):
            if line.startswith(prefix):
                message = line.removeprefix(prefix).strip()
                if message != "batch completed with failures" and message not in self.errors:
                    self.errors.append(message)
        # HandBrake progress redraws are noise in a failure report.
        if not line.lstrip().startswith(("Encoding:", "Muxing:", "Scanning title")):
            self.tail.append(line[:500])


def run(args: argparse.Namespace) -> int:
    for path in (args.input_dir, args.movies_dir, args.shows_dir, args.state_dir):
        path.mkdir(parents=True, exist_ok=True)
    processed_dir = args.input_dir / "_Processed"
    failed_dir = args.input_dir / "_Failed"
    duplicate_dir = args.input_dir / "_Duplicate"
    processed_dir.mkdir(exist_ok=True)
    failed_dir.mkdir(exist_ok=True)
    duplicate_dir.mkdir(exist_ok=True)
    prune_orphaned_failure_reports(failed_dir)

    state_path = args.state_dir / "queue.json"
    lock_path = args.state_dir / "queue.lock"
    claims_dir = args.state_dir / "claims"
    claims_dir.mkdir(exist_ok=True)
    active_source_lock = None

    def candidates() -> list[Path]:
        return sorted(
            (
                path
                for path in args.input_dir.iterdir()
                if path.is_file() and not path.is_symlink() and path.suffix.casefold() == ".iso"
            ),
            key=lambda path: natural_key(path.name),
        )

    def pending_titles(exclude: str | None = None) -> list[str]:
        return [path.stem for path in candidates() if path.name != exclude]

    def claim_next() -> tuple[Path, str, dict[str, Any]] | None:
        nonlocal active_source_lock
        release_source_lock(active_source_lock)
        active_source_lock = None
        with locked_queue(lock_path):
            state = load_state(state_path)
            sources = state["sources"]
            now = int(time.time())
            available = candidates()
            live_keys = {path.name for path in available}
            for stale in set(sources) - live_keys:
                del sources[stale]

            claimed: tuple[Path, str, dict[str, Any]] | None = None
            for source in available:
                try:
                    signature = source_signature(source)
                except FileNotFoundError:
                    continue
                entry = sources.setdefault(source.name, {})
                if not signatures_match(entry.get("signature"), signature):
                    sources[source.name] = {
                        "signature": signature,
                        "unchanged_since": now,
                        "attempts": 0,
                    }
                    print(
                        f"Observed {source.name}; waiting {args.settle_seconds}s "
                        "for the upload to settle."
                    )
                    continue
                if entry.get("signature") != signature:
                    entry["signature"] = signature
                if now - int(entry.get("unchanged_since", now)) < args.settle_seconds:
                    continue
                if now < int(entry.get("retry_after", 0)):
                    continue
                candidate_lock = try_source_lock(claims_dir, source.name)
                if candidate_lock is None:
                    continue
                try:
                    # The pathname could have changed between enumeration and
                    # acquisition of its durable per-source lock.
                    if source_signature(source) != signature:
                        release_source_lock(candidate_lock)
                        continue
                except OSError:
                    release_source_lock(candidate_lock)
                    continue
                lease_id = secrets.token_hex(16)
                entry["lease"] = {
                    "workerId": args.worker_id,
                    "leaseId": lease_id,
                    "claimedAt": now,
                    "expiresAt": now + args.lease_seconds,
                }
                entry["status"] = "claimed"
                active_source_lock = candidate_lock
                claimed = (source, lease_id, dict(entry))
                break
            atomic_json(state_path, state)
            return claimed

    def reset_changed_claim(source: Path, lease_id: str, error: SourceChanged) -> None:
        with locked_queue(lock_path):
            state = load_state(state_path)
            entry = state["sources"].get(source.name)
            if not isinstance(entry, dict) or not lease_owned(entry, args.worker_id, lease_id):
                return
            try:
                signature = source_signature(source)
            except OSError:
                del state["sources"][source.name]
            else:
                state["sources"][source.name] = {
                    "signature": signature,
                    "unchanged_since": int(time.time()),
                    "attempts": 0,
                    "status": "source-changed",
                    "last_error": str(error)[-4000:],
                }
            atomic_json(state_path, state)

    def renew(source_name: str, lease_id: str, local_entry: dict[str, Any]) -> bool:
        with locked_queue(lock_path):
            state = load_state(state_path)
            entry = state["sources"].get(source_name)
            if not isinstance(entry, dict) or not lease_owned(entry, args.worker_id, lease_id):
                return False
            if isinstance(local_entry.get("plan"), dict):
                entry["plan"] = local_entry["plan"]
            entry["status"] = "processing"
            entry["lease"]["expiresAt"] = int(time.time()) + args.lease_seconds
            atomic_json(state_path, state)
            return True

    def tend_holds() -> None:
        try:
            resolve_renamed_holds(args, lock_path, state_path, processed_dir)
        except Exception as error:  # noqa: BLE001 - never block new conversions
            print(f"Could not process renamed ISOs awaiting identification: {error}", file=sys.stderr)
        try:
            retry_transient_holds(args, lock_path, state_path, processed_dir)
        except ShutdownRequested:
            raise
        except Exception as error:  # noqa: BLE001 - never block new conversions
            print(f"Could not re-identify a held disc: {error}", file=sys.stderr)

    if identification_enabled(args):
        tend_holds()
    public_status(args, "idle", queued=pending_titles())
    failures = 0
    first_claim = True
    while True:
        if identification_enabled(args) and not first_claim:
            # A long queue would otherwise delay renamed holds until it ends.
            tend_holds()
        first_claim = False
        claim = claim_next()
        if claim is None:
            break
        source, lease_id, local_entry = claim
        now = int(time.time())

        duplicate_handled = False
        duplicate_archive: tuple[Path, str, int] | None = None
        with locked_queue(lock_path):
            state = load_state(state_path)
            entry = state["sources"].get(source.name)
            if not isinstance(entry, dict) or not lease_owned(entry, args.worker_id, lease_id):
                continue
            cached_hashes = {
                name: digest
                for name, digest in state.get("processed_hashes", {}).items()
                if isinstance(name, str) and isinstance(digest, str)
            }
            source_hash = entry.get("sha256")

        # Whole-ISO reads deliberately happen outside queue.lock. The NFS
        # source lock still excludes another worker from this pathname.
        try:
            duplicate, source_hash, calculated_hashes, live_hashes = find_duplicate(
                source,
                processed_dir,
                source_hash if isinstance(source_hash, str) else None,
                cached_hashes,
            )
            ensure_source_unchanged(source, local_entry["signature"])
        except SourceChanged as error:
            failures += 1
            reset_changed_claim(source, lease_id, error)
            print(f"Stopped {source.name}: {error}", file=sys.stderr)
            duplicate_handled = True
        except Exception as duplicate_error:
            try:
                ensure_source_unchanged(source, local_entry["signature"])
            except SourceChanged as source_error:
                failures += 1
                reset_changed_claim(source, lease_id, source_error)
                print(f"Stopped {source.name}: {source_error}", file=sys.stderr)
                duplicate_handled = True
            else:
                with locked_queue(lock_path):
                    state = load_state(state_path)
                    entry = state["sources"].get(source.name)
                    if not isinstance(entry, dict) or not lease_owned(entry, args.worker_id, lease_id):
                        raise LeaseLost(f"queue lease for {source.name} was lost during duplicate detection")
                    failures += 1
                    entry["attempts"] = int(entry.get("attempts", 0)) + 1
                    entry["status"] = "duplicate-check-failed"
                    entry["last_error"] = (
                        f"Duplicate check unavailable: {duplicate_error}"[-4000:]
                    )
                    # Backoff starts when the failure is recorded, not when the
                    # ISO was claimed: duplicate detection can read every
                    # same-sized ISO in _Processed, so a claim-time stamp has
                    # already expired by the time it is persisted.
                    entry["retry_after"] = int(time.time()) + args.retry_seconds * entry["attempts"]
                    entry.pop("lease", None)
                    print(
                        f"Refusing to convert {source.name} because duplicate detection "
                        f"failed (attempt {entry['attempts']}/{args.max_attempts}): "
                        f"{duplicate_error}",
                        file=sys.stderr,
                    )
                    if entry["attempts"] >= args.max_attempts and source.exists():
                        archived = archive_source(source, failed_dir)
                        write_failure_report(
                            archived,
                            RuntimeError(entry["last_error"]),
                            entry["attempts"],
                            args.input_dir,
                        )
                        print(f"Moved unverifiable ISO to {archived}", file=sys.stderr)
                        del state["sources"][source.name]
                    atomic_json(state_path, state)
                    duplicate_handled = True
        else:
            with locked_queue(lock_path):
                state = load_state(state_path)
                entry = state["sources"].get(source.name)
                if not isinstance(entry, dict) or not lease_owned(entry, args.worker_id, lease_id):
                    raise LeaseLost(f"queue lease for {source.name} was lost during duplicate detection")
                ensure_source_unchanged(source, local_entry["signature"])
                hashes = state.setdefault("processed_hashes", {})
                for stale in set(hashes) - live_hashes:
                    del hashes[stale]
                hashes.update(calculated_hashes)
                if source_hash is not None:
                    entry["sha256"] = source_hash
                if duplicate is not None:
                    source_name = source.name
                    source_size = source.stat().st_size
                    archived = archive_source(source, duplicate_dir)
                    duplicate_archive = (archived, duplicate, source_size)
                    del state["sources"][source.name]
                    atomic_json(state_path, state)
                    duplicate_handled = True
                else:
                    entry["status"] = "processing"
                    local_entry = dict(entry)
                    atomic_json(state_path, state)
        if duplicate_archive is not None:
            archived, duplicate, source_size = duplicate_archive
            quarantined: list[dict[str, str]] = []
            cleanup_error = None
            try:
                quarantined = quarantine_duplicate_outputs(
                    args,
                    source.name,
                    duplicate,
                    source_size,
                    duplicate_dir,
                )
            except Exception as error:
                cleanup_error = str(error)[-4000:]
                print(
                    f"Duplicate output cleanup was incomplete for {source.name}: {error}",
                    file=sys.stderr,
                )
            write_duplicate_report(archived, duplicate, quarantined, cleanup_error)
            print(f"Moved duplicate ISO {source.name} to {archived}", file=sys.stderr)
        if duplicate_handled:
            public_status(args, "idle", queued=pending_titles())
            continue

        queued = pending_titles(exclude=source.name)
        try:
            process_source(
                args,
                source,
                local_entry,
                queued,
                renew_lease=lambda: renew(source.name, lease_id, local_entry),
            )
            ensure_source_unchanged(source, local_entry["signature"])
            digest = local_entry.get("sha256") or iso_sha256(source)
            ensure_source_unchanged(source, local_entry["signature"])
            with locked_queue(lock_path):
                state = load_state(state_path)
                entry = state["sources"].get(source.name)
                if not isinstance(entry, dict) or not lease_owned(entry, args.worker_id, lease_id):
                    raise LeaseLost(f"queue lease for {source.name} was lost before completion")
                ensure_source_unchanged(source, local_entry["signature"])
                finished_plan = local_entry.get("plan") or {}
                if finished_plan.get("needs_identification"):
                    archived = park_for_identification(
                        args, source, finished_plan["needs_identification"], state
                    )
                    print(f"Held {source.name} for identification; its ISO is at {archived}")
                else:
                    archived = archive_source(source, processed_dir, finished_plan,
                                              identified_iso_name(finished_plan))
                    print(f"Completed {source.name}; preserved the ISO at {archived}")
                    if finished_plan.get("identification") and finished_plan.get("kind") == "tv":
                        write_processed_evidence(archived, dict(finished_plan,
                                                                source_iso=source.name))
                    state.setdefault("processed_hashes", {})[archived.name] = digest
                del state["sources"][source.name]
                atomic_json(state_path, state)
        except ShutdownRequested as error:
            with locked_queue(lock_path):
                state = load_state(state_path)
                entry = state["sources"].get(source.name)
                if isinstance(entry, dict) and lease_owned(entry, args.worker_id, lease_id):
                    if isinstance(local_entry.get("plan"), dict):
                        entry["plan"] = local_entry["plan"]
                    entry["status"] = "interrupted"
                    entry["last_interrupted_at"] = now
                    entry.pop("retry_after", None)
                    entry.pop("lease", None)
                    atomic_json(state_path, state)
            print(
                f"Interrupted {source.name}; it will restart from durable state: {error}",
                file=sys.stderr,
            )
            raise
        except SourceChanged as error:
            failures += 1
            reset_changed_claim(source, lease_id, error)
            print(f"Stopped {source.name}: {error}", file=sys.stderr)
        except LeaseLost as error:
            failures += 1
            print(f"Stopped {source.name} after losing its worker lease: {error}", file=sys.stderr)
        except Exception as error:
            failures += 1
            try:
                ensure_source_unchanged(source, local_entry["signature"])
            except SourceChanged as source_error:
                reset_changed_claim(source, lease_id, source_error)
                print(f"Stopped {source.name}: {source_error}", file=sys.stderr)
            else:
                with locked_queue(lock_path):
                    state = load_state(state_path)
                    entry = state["sources"].get(source.name)
                    if isinstance(entry, dict) and lease_owned(entry, args.worker_id, lease_id):
                        if isinstance(local_entry.get("plan"), dict):
                            entry["plan"] = local_entry["plan"]
                        entry["attempts"] = int(entry.get("attempts", 0)) + 1
                        entry["status"] = "retrying"
                        entry["last_error"] = str(error)[-4000:]
                        entry["retry_after"] = int(time.time()) + args.retry_seconds * entry["attempts"]
                        entry.pop("lease", None)
                        print(
                            f"Failed {source.name} (attempt {entry['attempts']}/{args.max_attempts}): {error}",
                            file=sys.stderr,
                        )
                        if entry["attempts"] >= args.max_attempts and source.exists():
                            archived = archive_source(source, failed_dir)
                            write_failure_report(
                                archived, error, entry["attempts"], args.input_dir
                            )
                            print(f"Moved repeatedly failing ISO to {archived}", file=sys.stderr)
                            del state["sources"][source.name]
                        atomic_json(state_path, state)
        finally:
            public_status(args, "idle", queued=pending_titles())
    release_source_lock(active_source_lock)
    return 1 if failures else 0


def special_and_layout_self_test() -> None:
    """Specials and episode-title numbering: both misfiled real discs.

    Rumpole's Return (2026-11) went to _Movies instead of S00E03, and TVmaze
    S/E titles in a tmdbid-tagged folder (Sherlock Holmes (1984): 4 TVmaze
    seasons, 7 on TMDB) would name the wrong episodes.
    """
    special = source_hints(Path("Rumpole of the Bailey (1978) S00E03.iso"))
    assert (special.season, special.episode, special.last_episode) == (0, 3, None)
    assert source_hints(Path("Show S00 Disc 1.iso")).season is None

    def episodes(layout: str, tmdb_id: int | None, entries: list[tuple[int, int, str]]) -> dict[str, Any]:
        return {"schemaVersion": 1, "layout": layout,
                "series": {"name": "X", "year": None, "provider": None, "tmdbId": tmdb_id, "tvmazeId": 1},
                "episodes": [{"season": s, "episode": e, "name": n, "airdate": None, "runtime": None}
                             for s, e, n in entries],
                "reasons": []}

    tvmaze_sherlock = episodes("tvmaze", None, [(4, 1, "The Sign of Four"), (2, 1, "The Sign of Four")])
    tmdb_sherlock = episodes("tmdb", 799, [(4, 1, "The Sign of Four")])
    assert library_episodes(tvmaze_sherlock, 1984, "tmdbid-799") == {}
    assert library_episodes(tmdb_sherlock, 1984, "tmdbid-799") == {(4, 1): "The Sign of Four"}
    assert library_episodes(episodes("tmdb", 800, [(4, 1, "x")]), 1984, "tmdbid-799") == {}
    assert library_episodes(tvmaze_sherlock, None, "tvdbid-72995")[(4, 1)] == "The Sign of Four"
    assert library_episodes(episodes("none", None, [(1, 1, "x")]), None, None) == {}
    assert library_episodes(None, None, None) == {}

    with tempfile.TemporaryDirectory() as work:
        root = Path(work)
        titles_file, episodes_file, calls = root / "titles.json", root / "episodes.json", root / "calls"
        handbrake, identifier = root / "handbrake", root / "disc-identify"
        handbrake.write_text(f"#!/bin/sh\nprintf 'JSON Title Set: '\ncat '{titles_file}'\n", encoding="utf-8")
        identifier.write_text(f"#!/bin/sh\necho \"$@\" >> '{calls}'\ncat '{episodes_file}'\n",
                              encoding="utf-8")
        handbrake.chmod(0o755)
        identifier.chmod(0o755)
        shows, movies, held, state = root / "Shows", root / "Movies", root / "_Unidentified", root / "state"
        for folder in (shows / "Rumpole of the Bailey (1978) [tvdbid-72995]",
                       shows / "Sherlock Holmes (1984) [tmdbid-799]",
                       shows / "Mission Impossible (1966)", movies / "Rumpole of the Bailey (1975)",
                       held, state):
            folder.mkdir(parents=True)
        args = argparse.Namespace(
            handbrake=str(handbrake), lease_seconds=120, shows_dir=shows, movies_dir=movies,
            min_duration=300, dominant_ratio=0.85, metadata_timeout=1, identifier=str(identifier),
            held_dir=held, subtitle_socket=str(root / "broker.sock"), state_dir=state,
            staging_dir=None, input_dir=root / "inbox", sevenzip="7z", ffmpeg="ffmpeg",
        )

        def plan(iso: str, minutes: list[int], listing: dict[str, Any]) -> dict[str, Any]:
            titles_file.write_text(json.dumps({"MainFeature": 1, "TitleList": [
                {"Index": i + 1, "Duration": {"Hours": 0, "Minutes": m, "Seconds": 0}}
                for i, m in enumerate(minutes)]}), encoding="utf-8")
            episodes_file.write_text(json.dumps(listing), encoding="utf-8")
            (root / iso).touch()  # its owner names the uploader's TMDB account
            return build_plan(args, root / iso)

        rumpole_tmdb = episodes("tmdb", 1, [(0, 1, "Rumpole of the Bailey"), (0, 3, "Rumpole's Return"),
                                            (4, 1, "Rumpole and the Old, Old Story")])
        for entry in rumpole_tmdb["episodes"]:
            entry["runtime"] = {(0, 1): 65, (0, 3): 105}.get((entry["season"], entry["episode"]))
        original_tvmaze = globals()["tvmaze_match"]
        globals()["tvmaze_match"] = lambda *_args: None  # no network in self-tests
        try:
            filed = plan("Rumpole_of_the_Bailey_-_Rumpole's_Return.iso", [103, 3], rumpole_tmdb)
            assert (filed["kind"], filed["season"], filed["first_episode"]) == ("tv", 0, 3), filed
            assert (filed["name"], filed["year"], filed["provider"]) == (
                "Rumpole of the Bailey", 1978, "tvdbid-72995")
            assert filed["episode_names"] == ["Rumpole's Return"] and not filed.get("held")
            assert "--series tvdbid-72995" in calls.read_text(encoding="utf-8")
            assert "--provider-socket" in calls.read_text(encoding="utf-8")
            assert "--owner" in calls.read_text(encoding="utf-8")

            # Only TMDB numbers specials. Without its list (no TMDB account: a
            # TVmaze list, or none) a subtitle is no season-0 evidence, so the
            # disc follows the film path; a disc named only after the show is
            # held for a person, with nothing to suggest.
            for listing in (episodes("tvmaze", None, [(4, 1, "x")]), {"broken": True}):
                film = plan("Rumpole of the Bailey - Rumpole's Return.iso", [103], listing)
                assert film["kind"] == "movie" and not film.get("held"), film
                parked = plan("Rumpole_of_the_Bailey_D4.iso", [103], listing)
                assert parked["held"] and parked["special"] and parked["output"] == str(held), parked
                assert parked["identification"]["assignments"] == [], parked
            # A fair title match is still evidence: held with its guess.
            parked = plan("Rumpole of the Bailey - Rumpoles Return Special.iso", [103], rumpole_tmdb)
            assert parked["held"] and parked["identification"]["assignments"][0]["episode"] == 3, parked

            # A film named "<show> <subtitle>" with a year of its own is not a
            # special of the show (Sherlock Holmes (1984) [tmdbid-799]), with
            # or without a TMDB list, even when one special has its length.
            sherlock_specials = episodes("tmdb", 799, [(0, 1, "The Sign of Four"), (4, 1, "x")])
            sherlock_specials["episodes"][0].update(runtime=125, airdate="1987-12-29")
            for listing in (tvmaze_sherlock, tmdb_sherlock, sherlock_specials, {"broken": True}):
                film = plan("Sherlock_Holmes_A_Game_of_Shadows_2011.iso", [129], listing)
                assert film["kind"] == "movie" and not film.get("held"), (listing, film)
                assert (film["name"], film["year"]) == ("Sherlock Holmes A Game of Shadows", 2011)
            # A confident special name with a different year is the film too,
            # not filed straight into Season 00 (R2-3).
            hound = episodes("tmdb", 799, [(0, 2, "The Hound of the Baskervilles"), (4, 1, "x")])
            hound["episodes"][0].update(runtime=105, airdate="1988-08-31")
            film = plan("Sherlock_Holmes_The_Hound_of_the_Baskervilles_1959.iso", [87], hound)
            assert film["kind"] == "movie" and not film.get("held"), film
            special = plan("Sherlock_Holmes_The_Hound_of_the_Baskervilles_1988.iso", [105], hound)
            assert (special["kind"], special["season"], special["first_episode"]) == ("tv", 0, 2), special
            # Episodes plus short extras: TV with the extras dropped, unless
            # the person named the full range, which keeps every title.
            extras = plan("ALL_CREATURES_GREAT_AND_SMALL.iso", [54, 54, 9, 5], {"broken": True})
            assert extras["kind"] == "tv" and extras["titles"] == [1, 2], extras
            ranged = plan("All Creatures Great and Small (2020) S05E01-E04.iso", [54, 54, 9, 5],
                          {"broken": True})
            assert ranged["titles"] == [1, 2, 3, 4] and ranged["last_episode"] == 4, ranged
            guessed = plan("Rumpole_of_the_Bailey_D4.iso", [103], rumpole_tmdb)
            assert guessed["held"] and guessed["kind"] == "tv", guessed
            assert iso_suggestion(guessed["identification"]["series"],
                                  guessed["identification"]["assignments"], 1)["isoName"] == (
                "Rumpole of the Bailey (1978) S00E03.iso")
            # Held without a dialogue comparison, which ranks regular episodes.
            finish_held(args, root / "Rumpole_of_the_Bailey_D4.iso", guessed,
                        [str(held / "D4" / "Season 01" / "D4 S01E01.mkv")], None)
            record = guessed["needs_identification"]
            assert record["suggestion"]["isoName"] == "Rumpole of the Bailey (1978) S00E03.iso"
            assert record["suggestion"]["provider"] == "tvdbid-72995"

            # Films whose names are not an existing show's stay films.
            for iso in ("MISSION_IMPOSSIBLE_2.iso", "Mission_Impossible_2_Disc_1.iso",
                        "The Flight of Dragons (1982).iso", "Rumpole of the Bailey (1975).iso",
                        "Rumpole of the Bailey.iso"):
                film = plan(iso, [98], rumpole_tmdb)
                assert film["kind"] == "movie" and not film.get("held"), (iso, film)

            # Curated numbers keep their folder and numbers; titles only from
            # the list in that folder's numbering.
            named = plan("Sherlock Holmes (1984) [tmdbid-799] S04E01-E02.iso", [52, 51], tvmaze_sherlock)
            assert named["episode_names"] == ["DVD Title 01", "DVD Title 02"], named
            assert (named["season"], named["first_episode"]) == (4, 1)
            named = plan("Sherlock Holmes (1984) [tmdbid-799] S04E01-E02.iso", [52, 51], tmdb_sherlock)
            assert named["episode_names"] == ["The Sign of Four", "DVD Title 02"], named
            assert named["provider"] == "tmdbid-799"
            named = plan("Rumpole of the Bailey (1978) S04E01.iso", [50], rumpole_tmdb)
            assert named["episode_names"] == ["Rumpole and the Old, Old Story"], named
            assert (named["provider"], named["season"]) == ("tvdbid-72995", 4)
            identifier.write_text("#!/bin/sh\nexit 3\n", encoding="utf-8")
            named = plan("Rumpole of the Bailey (1978) S04E01.iso", [50], rumpole_tmdb)
            assert named["episode_names"] == ["DVD Title 01"], named
            identifier.write_text(f"#!/bin/sh\ncat '{episodes_file}'\n", encoding="utf-8")

            # A TVmaze-numbered identification never lands in a TMDB-numbered
            # folder, nor in a second folder beside it: it is held, with no
            # suggestion carrying TVmaze numbers. Sherlock Holmes (1984) has
            # 4 TVmaze seasons and 7 on TMDB (TMDB unconfigured here).
            tvmaze_series = {"name": "Sherlock Holmes", "year": 1984, "provider": "tvdbid-79588",
                             "tvmazeId": 1}
            assert library_identity(shows, tvmaze_series) == ("Sherlock Holmes", 1984, "tvdbid-79588")
            assert library_match(shows, tvmaze_series)[1] == "Sherlock Holmes (1984) [tmdbid-799]"
            mapped = dict(tvmaze_series, provider="tmdbid-799", tmdbId=799,
                          providerIds=["tmdbid-799", "tvdbid-79588"])
            assert library_match(shows, mapped) == (("Sherlock Holmes", 1984, "tmdbid-799"), None)
            assert library_match(shows, dict(tvmaze_series, name="Mission Impossible", year=1966))[1] is None
            disc = {"schemaVersion": 2, "stage": "disc", "status": "identified", "series": tvmaze_series,
                    "season": 4, "candidates": [], "summary": "Identified from the disc menu.",
                    "reasons": ["Episode numbering was not checked against TMDB (dsaw has no TMDB account saved in Media Manager's Online services)."],
                    "assignments": [{"title": 1, "season": 4, "episode": 1, "name": "The Sign of Four"},
                                    {"title": 2, "season": 4, "episode": 2, "name": "The Devil's Foot"}]}
            sherlock = plan("SHERLOCK_HOLMES_D7.iso", [52, 51], disc)
            assert sherlock["held"] and sherlock["numbering_conflict"], sherlock
            assert sherlock["identification"]["assignments"] == []
            assert any("[tmdbid-799] uses TMDB episode numbering" in r and "no TMDB account saved" in r
                       for r in sherlock["identification"]["reasons"]), sherlock
            calls.write_text("", encoding="utf-8")
            finish_held(args, root / "SHERLOCK_HOLMES_D7.iso", sherlock,
                        [str(held / "D7" / "Season 01" / f"D7 S01E0{n}.mkv") for n in (1, 2)], None)
            assert sherlock["needs_identification"]["suggestion"] is None
            assert "content" not in calls.read_text(encoding="utf-8"), "the dialogue cannot help"
            assert not (shows / "Sherlock Holmes (1984) [tvdbid-79588]").exists()
            assert sorted(p.name for p in shows.iterdir()) == [
                "Mission Impossible (1966)", "Rumpole of the Bailey (1978) [tvdbid-72995]",
                "Sherlock Holmes (1984) [tmdbid-799]"]
            # A disc held because TMDB could not renumber it offers no
            # suggestion in TVmaze numbers either.
            assert held_suggestion(dict(disc, status="uncertain", tmdbNumberingHeld=True), 2) is None
            assert held_suggestion(dict(disc, status="uncertain"), 2)["firstEpisode"] == 1
            # An unconfirmed proposal passed through by the content stage keeps
            # the disc stage's flag (R2-2), and a TVmaze series next to a
            # TMDB-numbered folder gets no suggestion either (R2-1).
            assert held_suggestion(dict(disc, status="uncertain"), 2, None,
                                   dict(disc, tmdbNumberingHeld=True)) is None
            assert held_suggestion(dict(disc, status="uncertain"), 2, shows) is None
        finally:
            globals()["tvmaze_match"] = original_tvmaze

        # A held special is published by renaming its ISO to one S00 episode.
        needs = args.input_dir / "_NeedsIdentification"
        needs.mkdir(parents=True)
        video = held / "disc" / "Season 01" / "disc S01E01 - DVD Title 01.mkv"
        video.parent.mkdir(parents=True)
        video.write_bytes(b"video")
        iso = needs / "Rumpole of the Bailey (1978) S00E03.iso"
        iso.write_bytes(b"iso")
        state_path = state / "queue.json"
        atomic_json(state_path, {"version": STATE_VERSION, "sources": {}, "held": {
            held_record_key(iso): {"identify": "disc.iso.identify.json", "files": [str(video)],
                                   "titles": [1], "mtimeNs": iso.stat().st_mtime_ns}}})
        episodes_file.write_text(json.dumps(rumpole_tmdb), encoding="utf-8")
        resolve_renamed_holds(args, state / "queue.lock", state_path, args.input_dir / "_Processed")
        published = (shows / "Rumpole of the Bailey (1978) [tvdbid-72995]" / "Season 00"
                     / "Rumpole of the Bailey (1978) S00E03 - Rumpole's Return.mkv")
        assert published.is_file() and not video.exists()
        assert (args.input_dir / "_Processed" / iso.name).is_file()

        # Only a failure text report whose ISO has left _Failed is removed.
        failed = root / "_Failed"
        failed.mkdir()
        for name in ("GONE.iso.error.txt", "GONE.iso.error.json", "KEPT.iso", "KEPT.iso.error.txt",
                     "UPPER.ISO", "UPPER.iso.error.txt", "notes.txt", "GONE.iso.error.txt.bak"):
            (failed / name).write_text("x", encoding="utf-8")
        (failed / "LINK.iso.error.txt").symlink_to(failed / "notes.txt")
        prune_orphaned_failure_reports(failed)
        assert sorted(path.name for path in failed.iterdir()) == [
            "GONE.iso.error.json", "GONE.iso.error.txt.bak", "KEPT.iso", "KEPT.iso.error.txt",
            "LINK.iso.error.txt", "UPPER.ISO", "UPPER.iso.error.txt", "notes.txt"]


def live_shaped_retry_self_test() -> None:
    """The held All Creatures discs (2026-11-14/15), retried end to end.

    Nine discs were held only because Bonsai's label split failed; they are
    retried automatically. The library already holds S01E01-06, S04 (less
    E04) and S05, so no single gap places a 2- or 3-title disc and no guess
    is made: a guess after the library's last episode (S05) would be
    contradicted and, worded as a contradiction, would stop the retry. The
    dialogue alone then decides, and the episodes are published.
    """
    with tempfile.TemporaryDirectory() as work:
        root = Path(work)
        inbox, held, shows, state_dir = root / "_DVDs", root / "_Unidentified", root / "_Shows", root / "state"
        needs, processed = inbox / "_NeedsIdentification", inbox / "_Processed"
        for folder in (needs, processed, held, shows, state_dir):
            folder.mkdir(parents=True)
        media = "All Creatures Great and Small (1978)"
        series_dir = shows / f"{media} [tvdbid-78289]"
        (series_dir / "Season 03").mkdir(parents=True)
        library = [(1, e, f"{media} [tvdbid-78289]") for e in range(1, 7)]
        library += [(4, e, media) for e in (1, 2, 3, 5, 6, 7)] + [(5, e, media) for e in range(1, 13)]
        for season, episode, prefix in library:
            folder = series_dir / f"Season {season:02d}"
            folder.mkdir(exist_ok=True)
            (folder / f"{prefix} S{season:02d}E{episode:02d} - x.mkv").write_bytes(b"")
        counts = {"1": 13, "2": 14, "3": 14, "4": 10, "5": 12, "6": 12, "7": 12}
        series = {"tvmazeId": 8090, "name": "All Creatures Great and Small", "year": 1978,
                  "provider": "tvdbid-78289"}
        disc = {"schemaVersion": 2, "stage": "disc", "status": "uncertain", "series": series,
                "season": None, "assignments": [], "candidates": [series],
                "seasonEpisodeCounts": counts, "summary": "episodes need confirming.",
                "reasons": ["TheDiscDB has no record of this exact disc (no_match).",
                            "The disc menus do not name any All Creatures Great and Small (1978) episode."]}
        order_args = argparse.Namespace(shows_dir=shows)
        unnamed = Path("ALLCREATURESGREATANDSMALL_20261114-162720_1TbgkU.iso")
        assert order_proposal(order_args, unnamed, disc, [3, 4]) is None
        assert order_proposal(order_args, unnamed, disc, [3, 4, 5]) is None
        # With only S04E08-E10 missing, that gap is the guess for 3 titles.
        complete = dict(disc, seasonEpisodeCounts={"1": 6, "4": 10, "5": 12})
        guess = order_proposal(order_args, unnamed, complete, [3, 4, 5])
        assert [(a["season"], a["episode"]) for a in guess["assignments"]] == [(4, 8), (4, 9), (4, 10)]
        # A one-episode hole (S04E04) has no room for two titles.
        guess = order_proposal(order_args, unnamed, complete, [3, 4])
        assert [(a["season"], a["episode"]) for a in guess["assignments"]] == [(4, 8), (4, 9)]

        titles_file, contexts, disc_file = root / "titles.json", root / "contexts", root / "disc.json"
        disc_file.write_text(json.dumps(disc), encoding="utf-8")
        titles_file.write_text(json.dumps({"MainFeature": 3, "TitleList": [
            {"Index": i, "Duration": {"Hours": 0, "Minutes": 50, "Seconds": 0}} for i in range(1, 6)]}),
            encoding="utf-8")
        handbrake, identifier = root / "handbrake", root / "disc-identify"
        handbrake.write_text(f"#!/bin/sh\nprintf 'JSON Title Set: '\ncat '{titles_file}'\n",
                             encoding="utf-8")
        # The fake identifier answers both stages; the content stage records
        # its context and "matches" the dialogue to S02E01-02 or S02E03-05.
        identifier.write_text(f"""#!/usr/bin/env python3
import json, sys
argv = sys.argv[1:]
if argv[0] == "disc":
    assert argv[argv.index("--name-hint") + 1] == "All Creatures Great and Small", argv
    print(open({str(disc_file)!r}).read())
    raise SystemExit
context = json.load(open(argv[argv.index("--context") + 1]))
with open({str(contexts)!r}, "a") as log:
    log.write(json.dumps(context) + "\\n")
titles = [int(argv[i + 1]) for i, a in enumerate(argv) if a == "--title"]
first = 1 if len(titles) == 2 else 3
print(json.dumps({{"schemaVersion": 2, "stage": "content", "status": "identified",
                   "series": context["series"], "season": 2, "candidates": [],
                   "summary": "Identified from the dialogue.",
                   "reasons": ["Episode numbering was not checked against TMDB (dsaw has no TMDB account saved in Media Manager's Online services)."],
                   "assignments": [{{"title": t, "season": 2, "episode": first + i, "name": "Ep"}}
                                   for i, t in enumerate(titles)]}}))
""", encoding="utf-8")
        handbrake.chmod(0o755)
        identifier.chmod(0o755)
        args = argparse.Namespace(
            input_dir=inbox, needs_dir=needs, held_dir=held, shows_dir=shows, state_dir=state_dir,
            identifier=str(identifier), worker_id="test", lease_seconds=60, bonsai_url=None,
            handbrake=str(handbrake), parakeet="parakeet", parakeet_model="model",
            identify_threads=1, ffmpeg="ffmpeg", sevenzip="7z", subtitle_socket=None,
            staging_dir=None)
        lock_path, state_path = state_dir / "queue.lock", state_dir / "queue.json"
        label_split = ["TheDiscDB has no record of this exact disc (no_match).",
                       "Bonsai could not split the label: Bonsai reply is not the requested JSON",
                       "No TV series on TVmaze matches the disc's name.",
                       "There is no TV series to compare the episodes against."]
        held_records = {}
        for stem, titles in (("ALLCREATURESGREATANDSMALL_20261114-162720_1TbgkU", [3, 4]),
                             ("ALLCREATURESGREATANDSMALL_20261114-180405_25Tx4H", [3, 4, 5])):
            iso = needs / f"{stem}.iso"
            iso.write_bytes(stem.encode())
            files = []
            for offset, title in enumerate(titles):
                video = held / stem / "Season 01" / f"{stem} S01E{offset + 1:02d} - DVD Title {title:02d}.mkv"
                video.parent.mkdir(parents=True, exist_ok=True)
                video.write_bytes(f"{stem}-{title}".encode())
                files.append(str(video))
            # As on the server: schema-1 evidence and a record from before
            # automatic retries existed (no "retry").
            atomic_json(needs / f"{iso.name}.identify.json", {
                "schemaVersion": 1, "sourceIso": iso.name, "titles": titles, "heldFiles": files,
                "summary": "The series could not be determined.", "reasons": label_split,
                "suggestion": None, "finishedAt": int(time.time()) - 2 * RETRY_DELAYS[0]})
            (needs / f"{stem}.jellyfin.json").write_text("{}", encoding="utf-8")
            held_records[held_record_key(iso)] = {
                "identify": f"{iso.name}.identify.json", "sidecar": f"{stem}.jellyfin.json",
                "files": files, "titles": titles, "heldDir": f"_Unidentified/{stem}",
                "mtimeNs": iso.stat().st_mtime_ns}
        atomic_json(state_path, {"version": STATE_VERSION, "sources": {}, "held": held_records})
        original_busy = bonsai_gate_busy
        globals()["bonsai_gate_busy"] = lambda _args: False
        try:
            for _ in held_records:
                retry_transient_holds(args, lock_path, state_path, processed)
        finally:
            globals()["bonsai_gate_busy"] = original_busy
        logged = [json.loads(line) for line in contexts.read_text(encoding="utf-8").splitlines()]
        assert len(logged) == 2 and all(not c.get("assignments") and "proposalSource" not in c
                                        for c in logged), logged
        season_two = sorted(path.name for path in (series_dir / "Season 02").glob("*.mkv"))
        assert season_two == [f"{media} S02E0{n} - Ep.mkv" for n in range(1, 6)], season_two
        assert load_state(state_path)["held"] == {}
        assert sorted(path.name for path in needs.iterdir()) == []
        for name in ("S02E01-E02", "S02E03-E05"):
            archived = processed / f"{media} [tvdbid-78289] {name}.iso"
            assert archived.is_file(), sorted(processed.iterdir())
            evidence = read_evidence(Path(f"{archived}.identify.json"))
            assert evidence["resolution"]["by"] == "automatic retry", evidence


def self_test() -> None:
    movie = source_hints(Path("THE_MATRIX_1999_DVD_DISC_2.iso"))
    assert movie.name == "The Matrix"
    assert movie.year == 1999 and movie.disc == 2 and movie.season is None
    assert movie.provider is None and not movie.is_jellyfin_named
    # Regression (All Creatures Great and Small, 2026-11-14): the desktop
    # ripper's capture stamp leaked into names and merged two discs' folders,
    # and two-episode discs were filed as films.
    stamped = source_hints(Path("ALLCREATURESGREATANDSMALL_20261114-162720_1TbgkU.iso"))
    assert stamped.name == "Allcreaturesgreatandsmall" and stamped.year is None
    assert source_hints(Path("ALLCREATURESGREATANDSMALL_20261114-155933.iso")).name == stamped.name
    assert looks_like_episode_set([Title(3, 3047, True), Title(4, 2952, False)])
    assert not looks_like_episode_set([Title(1, 6100, True), Title(2, 2952, False)])
    assert display_aspect({"Width": 720, "Height": 576, "PAR": {"Num": 16, "Den": 15}}) == 1.33
    assert identified_assignments(
        {"status": "identified", "series": {"name": "X"},
         "assignments": [{"title": 3, "season": 1, "episode": 5}, {"title": 4, "season": 1, "episode": 7}]},
        [3, 4],
    ) is None
    assert iso_suggestion(
        {"name": "All Creatures Great and Small", "year": 1978, "provider": "tvdbid-78289"},
        [{"season": 1, "episode": 5}, {"season": 1, "episode": 6}], 2,
    )["isoName"] == "All Creatures Great and Small (1978) S01E05-E06.iso"
    renamed = source_hints(Path("All Creatures Great and Small (1978) S01E05-E06.iso"))
    assert (renamed.season, renamed.episode, renamed.last_episode) == (1, 5, 6)
    show = source_hints(Path("The_Wire_S03_Disc_2.iso"))
    assert show.name == "The Wire" and show.season == 3 and show.disc == 2
    assert show.is_jellyfin_named and show.provider is None

    # M1: the user's Rumpole ISOs are curated. Bare trailing Roman/Arabic
    # series identifiers on a multi-disc TV set must encode the season and
    # bypass the internal/TVmaze metadata name.
    rumpole_iv = source_hints(Path("RUMPOLE_OF_THE_BAILEY_IV_DISC_2.iso"))
    assert rumpole_iv.name == "Rumpole Of The Bailey Iv", rumpole_iv.name
    assert rumpole_iv.trailing_series == 4 and rumpole_iv.disc == 2
    assert rumpole_iv.season is None and rumpole_iv.year is None
    assert rumpole_iv.is_jellyfin_named
    rumpole_3 = source_hints(Path("RUMPOLE_OF_THE_BAILEY_3_DISC_1.iso"))
    assert rumpole_3.name == "Rumpole Of The Bailey 3", rumpole_3.name
    assert rumpole_3.trailing_series == 3 and rumpole_3.disc == 1
    assert rumpole_3.is_jellyfin_named
    assert strip_trailing_series_token(rumpole_iv.name, rumpole_iv.trailing_series) == (
        "Rumpole Of The Bailey"
    )
    assert strip_trailing_series_token(rumpole_3.name, rumpole_3.trailing_series) == (
        "Rumpole Of The Bailey"
    )
    # A movie sequel keeps its title number on the movie path; it is not
    # stripped like a TV series season marker.
    movie_sequel = source_hints(Path("MISSION_IMPOSSIBLE_2_DISC_1.iso"))
    assert movie_sequel.name == "Mission Impossible 2", movie_sequel.name
    assert movie_sequel.trailing_series == 2 and movie_sequel.season is None
    assert strip_trailing_series_token(movie_sequel.name, 2) == "Mission Impossible"
    series_four = source_hints(Path("Rumpole_Of_The_Bailey_Series_IV.iso"))
    assert series_four.name == "Rumpole Of The Bailey", series_four.name
    assert series_four.season == 4 and series_four.disc is None
    assert series_four.is_jellyfin_named
    curated = source_hints(Path("The_Wire_(2002)_[tvdbid-12345]_S03E02.iso"))
    assert curated.name == "The Wire"
    assert curated.year == 2002 and curated.provider == "tvdbid-12345"
    assert curated.season == 3 and curated.episode == 2
    assert curated.is_jellyfin_named

    ranged = source_hints(Path("Rumpole of the Bailey - S02E04-E06.mkv.iso"))
    assert ranged.name == "Rumpole of the Bailey", ranged.name
    assert ranged.season == 2 and ranged.episode == 4 and ranged.last_episode == 6
    assert ranged.is_jellyfin_named

    duplicated_pairs = [
        Title(index=2, seconds=3029, main_feature=False),
        Title(index=3, seconds=3029, main_feature=False),
        Title(index=4, seconds=3157, main_feature=False),
        Title(index=5, seconds=3157, main_feature=False),
        Title(index=6, seconds=3013, main_feature=False),
        Title(index=7, seconds=3013, main_feature=False),
    ]
    assert [
        title.index for title in collapse_systematic_duplicate_title_pairs(duplicated_pairs)
    ] == [
        2,
        4,
        6,
    ]
    duplicated_with_play_all = duplicated_pairs + [
        Title(index=8, seconds=9199, main_feature=True)
    ]
    ranged_selected, ranged_dominant, _ = prepare_titles(
        duplicated_with_play_all,
        ranged,
        300,
        0.85,
    )
    assert not ranged_dominant
    assert [title.index for title in ranged_selected] == [2, 4, 6]

    duplicated_with_menu_and_play_all = [
        Title(index=1, seconds=45, main_feature=False),
        *duplicated_with_play_all,
        Title(index=9, seconds=90, main_feature=False),
    ]
    filtered_selected, filtered_dominant, _ = prepare_titles(
        duplicated_with_menu_and_play_all,
        ranged,
        300,
        0.85,
    )
    assert not filtered_dominant
    assert [title.index for title in filtered_selected] == [2, 4, 6]

    incidental_pairs = [
        Title(index=1, seconds=3000, main_feature=False),
        Title(index=2, seconds=3000, main_feature=False),
        Title(index=3, seconds=2500, main_feature=False),
        Title(index=4, seconds=2600, main_feature=False),
        Title(index=5, seconds=3100, main_feature=False),
        Title(index=6, seconds=3100, main_feature=False),
    ]
    assert collapse_systematic_duplicate_title_pairs(incidental_pairs) == incidental_pairs
    lone_pair = duplicated_pairs[:2]
    assert collapse_systematic_duplicate_title_pairs(lone_pair) == lone_pair

    movie_pairs = [
        Title(index=1, seconds=2400, main_feature=False),
        Title(index=2, seconds=2400, main_feature=False),
        Title(index=3, seconds=2600, main_feature=False),
        Title(index=4, seconds=2600, main_feature=False),
        Title(index=5, seconds=2500, main_feature=False),
        Title(index=6, seconds=2500, main_feature=False),
    ]
    movie_selected, _, _ = prepare_titles(movie_pairs, movie_sequel, 300, 0.85)
    assert movie_selected == movie_pairs
    confirmed_tv_selected, _, _ = prepare_titles(
        movie_pairs,
        rumpole_3,
        300,
        0.85,
        allow_trailing_tv=True,
    )
    assert [title.index for title in confirmed_tv_selected] == [1, 3, 5]

    composite_with_duplicate_episode = [
        Title(index=3, seconds=6263, main_feature=True),
        Title(index=4, seconds=3131, main_feature=False),
        Title(index=5, seconds=6271, main_feature=False),
        Title(index=6, seconds=3135, main_feature=False),
        Title(index=7, seconds=3116, main_feature=False),
        Title(index=8, seconds=3116, main_feature=False),
    ]
    series_four_range = source_hints(
        Path("Rumpole of the Bailey - S04E01-E03.iso")
    )
    composite_selected, composite_dominant, _ = prepare_titles(
        composite_with_duplicate_episode,
        series_four_range,
        300,
        0.85,
    )
    assert not composite_dominant
    assert [title.index for title in composite_selected] == [4, 6, 7]

    range_mismatch = duplicated_pairs + [
        Title(index=8, seconds=3200, main_feature=False),
        Title(index=9, seconds=3200, main_feature=False),
    ]
    try:
        prepare_titles(range_mismatch, ranged, 300, 0.85)
    except RuntimeError as error:
        assert "declares 3 episodes" in str(error)
    else:
        raise AssertionError("episode-range count mismatch must fail closed")

    try:
        source_hints(Path("Example_S02E06-E04.iso"))
    except ValueError as error:
        assert "reversed episode range" in str(error)
    else:
        raise AssertionError("reversed episode range must fail closed")

    high_season = source_hints(Path("Long_Running_Show_S31E01.iso"))
    assert high_season.season == 31 and high_season.episode == 1

    # M1 helper coverage.
    assert _roman_to_int("IV") == 4
    assert _roman_to_int("ii") == 2
    assert _roman_to_int("XIV") == 14
    assert _roman_to_int("IIV") is None
    assert _roman_to_int("MATRIX") is None
    assert _roman_to_int("") is None
    assert parse_provider("The Wire [tvdbid-12345]") == "tvdbid-12345"
    assert parse_provider("The Wire") is None
    assert strip_jellyfin_suffix("The Wire (2002) [tvdbid-12345]") == "The Wire"
    assert strip_jellyfin_suffix("Rumpole (1978)") == "Rumpole"
    base, year, provider = parse_jellyfin_folder("The Wire (2002) [tvdbid-12345]")
    assert base == "The Wire" and year == 2002 and provider == "tvdbid-12345"

    # The series folder keeps the Jellyfin provider tag; each episode file
    # names the series and numbers only, and the held evidence still supplies
    # the provider after the suggested ISO name dropped it.
    with tempfile.TemporaryDirectory() as publish_dir:
        root = Path(publish_dir)
        held = root / "_Held"
        held.mkdir()
        files = []
        for name in ("episode-1.mkv", "episode-2.mkv"):
            path = held / name
            path.write_bytes(b"video")
            files.append(path)
        library = root / "Shows"
        library.mkdir()
        season_dir = publish_episodes(
            argparse.Namespace(shows_dir=library, held_dir=held), files,
            "All Creatures Great and Small", 1978, "tvdbid-78289", 1, 5,
            ["Pilot", "Second"],
        )
        assert season_dir == (library / "All Creatures Great and Small (1978) [tvdbid-78289]"
                              / "Season 01")
        published = sorted(path.name for path in season_dir.glob("*.mkv"))
        assert published == [
            "All Creatures Great and Small (1978) S01E05 - Pilot.mkv",
            "All Creatures Great and Small (1978) S01E06 - Second.mkv",
        ], published
        evidence = root / "held.iso.identify.json"
        evidence.write_text(json.dumps({
            "suggestion": {"provider": "tvdbid-78289", "isoName": "x.iso"},
        }), encoding="utf-8")
        assert held_provider(evidence) == "tvdbid-78289"
        evidence.write_text(json.dumps({"suggestion": {"provider": "not-a-provider"}}),
                            encoding="utf-8")
        assert held_provider(evidence) is None
        evidence.write_text("not json", encoding="utf-8")
        assert held_provider(evidence) is None

    # M2: the queue-grouping fallback remembers an existing library folder so
    # two Rumpole discs (named differently per series) chain into one series
    # even when their filenames are not canonical Jellyfin.
    with tempfile.TemporaryDirectory() as library_dir:
        library = Path(library_dir)
        (library / "Rumpole Of The Bailey (1978) [tvdbid-7794]").mkdir()
        (library / "Some Other Series (1999) [tvdbid-111]").mkdir()
        (library / ".hidden").mkdir()
        existing = find_existing_series(library, "Rumpole Of The Bailey")
        assert existing is not None
        base, year, provider = existing
        assert base == "Rumpole Of The Bailey"
        assert year == 1978 and provider == "tvdbid-7794"
        # Unrelated query must not adopt a sibling series merely on shared
        # generic terms like "The" or "Series".
        assert find_existing_series(library, "Loose Canon") is None

        office = source_hints(Path("The Office S02E01-E03.iso"))
        (library / "The Office UK (2001) [tvdbid-272060]").mkdir()
        assert find_existing_for_hints(library, office, office.name) is None
        (library / "The Office (2005) [tvdbid-73244]").mkdir()
        assert find_existing_for_hints(library, office, office.name) == (
            "The Office",
            2005,
            "tvdbid-73244",
        )
        dark = source_hints(Path("Dark S01E01-E03.iso"))
        (library / "Dark Dark (2020) [tvdbid-999]").mkdir()
        assert find_existing_for_hints(library, dark, dark.name) is None

        # Curated metadata must prevent a remake or provider collision from
        # adopting a similarly named but different existing library folder.
        (library / "Dune (1984) [tmdbid-841]").mkdir()
        assert find_existing_series(library, "Dune", expected_year=2021) is None
        assert find_existing_series(library, "Dune", expected_provider="tmdbid-438631") is None
        (library / "Dune (2021) [tmdbid-438631]").mkdir()
        assert find_existing_series(library, "Dune", expected_year=2021) == (
            "Dune",
            2021,
            "tmdbid-438631",
        )
        # Without disambiguating metadata, equal matches are unsafe to reuse.
        assert find_existing_series(library, "Dune") is None

        # TMDB-checked series carry every provider id: an existing folder
        # tagged with any of them is reused, whatever its name.
        (library / "Sherlock Holmes (1984) [tmdbid-799]").mkdir()
        assert library_identity(library, {
            "name": "Sherlock Holmes", "year": 1984, "provider": "tmdbid-799",
            "providerIds": ["tmdbid-799", "tvdbid-77728"]}) == ("Sherlock Holmes", 1984, "tmdbid-799")
        assert library_identity(library, {
            "name": "The Adventures of Sherlock Holmes", "year": 1984, "provider": "tvdbid-77728",
            "providerIds": []}) == ("The Adventures of Sherlock Holmes", 1984, "tvdbid-77728")
        assert library_identity(library, {
            "name": "Rumpole of the Bailey", "year": 1978, "provider": "tmdbid-4280",
            "providerIds": ["tmdbid-4280", "tvdbid-7794"]}) == ("Rumpole Of The Bailey", 1978, "tvdbid-7794")
        # A same-kind tag that differs is another series.
        assert library_identity(library, {
            "name": "Dune", "year": 1984, "provider": "tmdbid-1"}) == ("Dune", 1984, "tmdbid-1")

    titles = [Title(1, 2700, False), Title(2, 2680, False), Title(3, 5380, True)]
    selected, dominant, _ = select_titles(titles, 300, 0.85)
    assert not dominant and [title.index for title in selected] == [1, 2]
    selected, dominant, ratio = select_titles([Title(1, 5400, True), Title(2, 500, False)], 300, 0.85)
    assert dominant and selected[0].index == 1 and ratio > 0.9
    assert looks_like_episode_set(
        [Title(2, 1326, True), Title(3, 1705, False), Title(4, 1638, False), Title(5, 1523, False)]
    )
    assert not looks_like_episode_set([Title(1, 5400, True), Title(2, 1200, False), Title(3, 900, False)])
    # Two episodes plus short extras are TV with the extras dropped; a film
    # with featurettes, or one episode with extras, is not.
    creatures = [Title(1, 3250, True), Title(2, 3271, False), Title(3, 548, False), Title(4, 334, False)]
    assert [title.index for title in episode_core(creatures)] == [1, 2]
    assert episode_core([Title(1, 6100, True), Title(2, 548, False), Title(3, 334, False)]) is None
    assert episode_core([Title(1, 3250, True), Title(2, 548, False)]) is None
    assert episode_core([Title(1, 3250, True), Title(2, 3271, False), Title(3, 1500, False)]) is None
    assert episode_core([Title(1, 3250, True), Title(2, 3271, False)]) is None
    with tempfile.TemporaryDirectory() as scan_dir:
        fake_handbrake = Path(scan_dir) / "fake-handbrake"
        fake_handbrake.write_bytes(
            b"#!/bin/sh\n"
            b"printf '\\377malformed DVD label\\n'\n"
            b"printf '%s\\n' 'JSON Title Set: {\"MainFeature\":1,\"TitleList\":[{\"Index\":1,\"Duration\":{\"Hours\":0,\"Minutes\":50,\"Seconds\":0}}]}'\n"
        )
        fake_handbrake.chmod(0o755)
        scanned = scan_titles(str(fake_handbrake), Path(scan_dir) / "disc.iso")
        assert scanned == [Title(index=1, seconds=3000, main_feature=True)]
    # Hold reasons: only temporary failures with nothing contradicting the
    # disc are retried. All Creatures S01E05-E06 (2026-11-15) was held after a
    # Bonsai 504 with no other blocker.
    creatures_reasons = [
        "TheDiscDB has no record of this exact disc (no_match).",
        "Bonsai could not read the menus: Bonsai returned HTTP 504 Gateway Timeout",
        "The disc menus do not name any All Creatures Great and Small (1978) episode.",
        "Title 3: the dialogue did not clearly match one episode.",
    ]
    assert classify_reasons(creatures_reasons)["retryable"]
    assert classify_reasons(["TMDB is unavailable: 503", "Title 3: x"])["retryable"]
    assert classify_reasons(["the identifier exceeded its deadline"])["retryable"]
    assert classify_reasons(["The OpenSubtitles daily download limit was reached."])["retryable"]
    assert not classify_reasons(creatures_reasons[:1] + creatures_reasons[2:])["retryable"]
    assert classify_reasons(
        ["Bonsai could not split the label: Bonsai reply is not the requested JSON",
         "No TV series on TVmaze matches the disc's name."])["retryable"]
    assert not classify_reasons(
        ["Title 4: transcription failed: the excerpt contains too little speech to compare"]
    )["retryable"]
    contradicted = classify_reasons(creatures_reasons + [
        "Title 3: dialogue matches S01E09 rather than the disc menu guess."])
    assert not contradicted["retryable"] and len(contradicted["substantiveReasons"]) == 1
    # A library-order or disc-number guess is only a guess: neither today's
    # wording nor the earlier one blocks a retry.
    for guess in ("Title 3: dialogue matches S01E09, not the library order guess.",
                  "Title 3: dialogue matches S01E09 rather than the library order guess.",
                  "Title 3: dialogue matches S01E09 rather than the disc number guess."):
        assert classify_reasons(creatures_reasons + [guess])["retryable"], guess
    # A menu reading cut off at its token limit is retried like a label split.
    assert classify_reasons([
        "Bonsai could not read the menus: Bonsai reply was cut off at its 2048-token "
        "limit before the answer"])["retryable"]
    # A partial menu read (some frames lost) is retried the same way, whether
    # the failed batch cut off or the gate answered busy; and a total failure
    # whose batches each cut off still matches.
    assert classify_reasons([
        "Bonsai could not read some menu frames: Bonsai reply was cut off at its "
        "1500-token limit before the answer"])["retryable"]
    assert classify_reasons([
        "Bonsai could not read the menus: Bonsai reply was cut off at its 1500-token "
        "limit before the answer; Bonsai reply was cut off at its 1500-token limit "
        "before the answer"])["retryable"]
    assert classify_reasons([
        "Bonsai could not read some menu frames: Bonsai returned HTTP 504 Gateway "
        "Timeout"])["retryable"]

    # Library order: the one run of missing episodes with room for the disc,
    # rolling into the next season once the provider says one is complete.
    with tempfile.TemporaryDirectory() as order_dir:
        root = Path(order_dir)
        shows = root / "Shows"
        series_dir = shows / "All Creatures Great and Small (1978) [tvdbid-78289]"
        season_one = series_dir / "Season 01"
        season_one.mkdir(parents=True)
        for number in range(1, 5):
            (season_one / f"All Creatures Great and Small (1978) S01E{number:02d} - x.mkv").write_bytes(b"")
        order_args = argparse.Namespace(shows_dir=shows)
        series = {"tvmazeId": 1, "name": "All Creatures Great and Small", "year": 1978,
                  "provider": "tvdbid-78289"}
        disc_outcome = {"status": "uncertain", "series": series, "season": None,
                        "assignments": [], "seasonEpisodeCounts": {"1": 6}}
        unnamed = Path("ALLCREATURESGREATANDSMALL_20261114-162720_1TbgkU.iso")
        proposal = order_proposal(order_args, unnamed, disc_outcome, [3, 4])
        assert proposal["proposalSource"] == "library order", proposal
        assert [(a["title"], a["season"], a["episode"]) for a in proposal["assignments"]] == [
            (3, 1, 5), (4, 1, 6)]
        assert "S01E05-E06" in proposal["reason"] and "S01E04" in proposal["reason"]
        # Three titles have no room in the six-episode season: no proposal.
        assert order_proposal(order_args, unnamed, disc_outcome, [3, 4, 5]) is None
        # An unstarted second season also has room: two gaps, no guess.
        two_seasons = dict(disc_outcome, seasonEpisodeCounts={"1": 6, "2": 6})
        assert order_proposal(order_args, unnamed, two_seasons, [3, 4]) is None
        for number in (5, 6):
            (season_one / f"All Creatures Great and Small (1978) S01E{number:02d} - x.mkv").write_bytes(b"")
        rolled = order_proposal(order_args, unnamed, two_seasons, [3, 4])
        assert [(a["season"], a["episode"]) for a in rolled["assignments"]] == [(2, 1), (2, 2)]
        # A season named on the disc is not rolled past.
        assert order_proposal(order_args, unnamed, dict(two_seasons, season=1), [3, 4]) is None
        # A hole inside a season is filled, not skipped.
        (season_one / "All Creatures Great and Small (1978) S01E03 - x.mkv").unlink()
        (season_one / "All Creatures Great and Small (1978) S01E04 - x.mkv").unlink()
        hole = order_proposal(order_args, unnamed, dict(two_seasons, season=1), [3, 4])
        assert [(a["season"], a["episode"]) for a in hole["assignments"]] == [(1, 3), (1, 4)], hole
        assert "after S01E02" in hole["reason"], hole
        # Anything the disc stage already proposed or identified is kept.
        assert order_proposal(order_args, unnamed, dict(
            disc_outcome, assignments=[{"title": 3, "season": 1, "episode": 1}]), [3, 4]) is None
        assert order_proposal(order_args, unnamed, dict(disc_outcome, series=None), [3, 4]) is None
        # No library folder: the disc number estimates the episodes instead.
        other = dict(disc_outcome, series=dict(series, name="Rumpole of the Bailey", year=1978,
                                               provider="tvdbid-7794"))
        by_disc = order_proposal(order_args, Path("RUMPOLE_OF_THE_BAILEY_DISC_3.iso"), other, [1, 2])
        assert by_disc["proposalSource"] == "disc number"
        assert [(a["season"], a["episode"]) for a in by_disc["assignments"]] == [(1, 5), (1, 6)]
        assert order_proposal(order_args, Path("RUMPOLE_OF_THE_BAILEY.iso"), other, [1, 2]) is None
        assert library_to_provider_episode(series, 1, 5) == (1, 5)

    # Automatic re-identification of transient holds. Concurrency and data
    # risk (publishing into the library, archiving ISOs, racing a person's
    # rename or deletion and shutdowns), so every transition is exercised.
    with tempfile.TemporaryDirectory() as retry_dir:
        root = Path(retry_dir)
        inbox = root / "_DVDs"
        needs = inbox / "_NeedsIdentification"
        processed = inbox / "_Processed"
        held = root / "_Unidentified"
        shows = root / "_Shows"
        state_dir = root / "state"
        for folder in (needs, processed, held, shows, state_dir):
            folder.mkdir(parents=True)
        retry_args = argparse.Namespace(
            input_dir=inbox, needs_dir=needs, held_dir=held, shows_dir=shows,
            state_dir=state_dir, identifier="disc-identify", worker_id="test",
            lease_seconds=60, bonsai_url=None, handbrake="HandBrakeCLI")
        lock_path = state_dir / "queue.lock"
        state_path = state_dir / "queue.json"
        series = {"tvmazeId": 1, "name": "All Creatures Great and Small", "year": 1978,
                  "provider": "tvdbid-78289"}

        def hold(name: str, reasons: list[str]) -> tuple[Path, str, list[Path]]:
            iso = inbox / f"{name}.iso"
            iso.write_bytes(name.encode())
            folder = held / name / "Season 01"
            folder.mkdir(parents=True)
            files = []
            for offset, title in enumerate((3, 4)):
                video = folder / f"{name} S01E{offset + 1:02d} - DVD Title {title:02d}.mkv"
                video.write_bytes(f"{name}-{title}".encode())
                files.append(video)
            record = {
                "schemaVersion": EVIDENCE_SCHEMA_VERSION, "status": "held",
                "sourceIso": iso.name, "heldDir": f"_Unidentified/{name}",
                "heldFiles": [str(f) for f in files], "titles": [3, 4],
                "summary": "held", "reasons": reasons, "suggestion": None,
                "outcomes": {"disc": None, "content": None},
                "retry": classify_reasons(reasons),
            }
            with locked_queue(lock_path):
                state = load_state(state_path)
                archived = park_for_identification(retry_args, iso, record, state)
                atomic_json(state_path, state)
            return archived, held_record_key(archived), files

        def retry_of(key: str) -> dict[str, Any] | None:
            record = load_state(state_path).get("held", {}).get(key)
            return record.get("retry") if record else None

        def make_due(key: str) -> None:
            state = load_state(state_path)
            state["held"][key]["retry"]["nextAt"] = 0
            atomic_json(state_path, state)

        calls: list[str] = []

        def scripted(answer: Any) -> None:
            def fake(_args: Any, _directory: Path, iso: Path, record: dict[str, Any],
                     renew: Any) -> Any:
                calls.append(iso.name)
                assert renew(), "the retry lease must be renewable while identifying"
                return answer(iso, record)
            globals()["reidentify_held"] = fake

        # Not only a busy gate (whose attempts are given back, tested below).
        transient = {"status": "uncertain", "series": series, "summary": "still busy",
                     "assignments": [], "reasons": creatures_reasons + [
                         "TVmaze search failed: operation timed out"]}

        def identified(first: int) -> dict[str, Any]:
            return {"status": "identified", "series": series, "summary": "Identified",
                    "reasons": [], "assignments": [
                        {"title": 3, "season": 1, "episode": first, "name": "One"},
                        {"title": 4, "season": 1, "episode": first + 1, "name": "Two"}]}

        original_reidentify = reidentify_held
        original_busy = bonsai_gate_busy
        try:
            # Backoff: 1 h, 6 h, 24 h, then the disc is left for a person.
            iso_a, key_a, files_a = hold("A", creatures_reasons)
            assert retry_of(key_a)["state"] == "scheduled"
            assert retry_of(key_a)["nextAt"] - int(time.time()) in range(3590, 3601)
            assert read_evidence(Path(f"{iso_a}.identify.json"))["retry"]["nextAttemptAt"]
            scripted(lambda iso, record: (dict(transient), {"disc": transient, "content": None}, None))
            retry_transient_holds(retry_args, lock_path, state_path, processed)
            assert calls == [], "a hold is not retried before its delay"
            for attempt, delay in ((1, RETRY_DELAYS[1]), (2, RETRY_DELAYS[2])):
                make_due(key_a)
                retry_transient_holds(retry_args, lock_path, state_path, processed)
                current = retry_of(key_a)
                assert current["attempts"] == attempt and current["state"] == "scheduled"
                assert current["nextAt"] - int(time.time()) in range(delay - 10, delay + 1)
                assert "lease" not in current
            make_due(key_a)
            retry_transient_holds(retry_args, lock_path, state_path, processed)
            assert retry_of(key_a)["state"] == "stopped" and retry_of(key_a)["attempts"] == 3
            evidence_a = read_evidence(Path(f"{iso_a}.identify.json"))
            assert evidence_a["retry"]["state"] == "stopped" and evidence_a["outcomes"]["disc"]
            make_due(key_a)
            calls.clear()
            retry_transient_holds(retry_args, lock_path, state_path, processed)
            assert calls == [] and all(f.is_file() for f in files_a)

            # The gate is busy: wait without spending an attempt.
            iso_h, key_h, _ = hold("H", creatures_reasons)
            make_due(key_h)
            globals()["bonsai_gate_busy"] = lambda _args: True
            retry_transient_holds(retry_args, lock_path, state_path, processed)
            assert calls == [] and retry_of(key_h)["attempts"] == 0
            globals()["bonsai_gate_busy"] = original_busy

            # A gate that stays busy for an hour no longer blocks retries:
            # one goes ahead, then the wait starts again.
            globals()["bonsai_gate_busy"] = lambda _args: True
            marker = state_dir / "retry-bonsai-busy-since"
            marker.unlink(missing_ok=True)
            start = int(time.time())
            assert postpone_for_busy_gate(retry_args, start) and marker.is_file()
            assert postpone_for_busy_gate(retry_args, start + BUSY_GATE_PATIENCE_SECONDS - 1)
            assert not postpone_for_busy_gate(retry_args, start + BUSY_GATE_PATIENCE_SECONDS)
            assert not marker.exists()
            assert postpone_for_busy_gate(retry_args, start + BUSY_GATE_PATIENCE_SECONDS + 1)
            globals()["bonsai_gate_busy"] = original_busy
            assert not postpone_for_busy_gate(retry_args, start) and not marker.exists()
            marker.write_text(str(start + 86400), encoding="utf-8")  # a clock that moved back
            globals()["bonsai_gate_busy"] = lambda _args: True
            assert postpone_for_busy_gate(retry_args, start)
            assert int(marker.read_text(encoding="utf-8")) == start
            globals()["bonsai_gate_busy"] = original_busy
            busy = classify_reasons(["Bonsai could not read the menus: Bonsai returned HTTP 504 Gateway Timeout"])
            assert busy["retryable"] and busy_gate_only(busy)
            ranking = classify_reasons(busy["transientReasons"] + [
                "Title 2: Bonsai ranking failed: Bonsai returned HTTP 429 Too Many Requests"])
            assert ranking["retryable"] and busy_gate_only(ranking)
            assert not busy_gate_only(classify_reasons(creatures_reasons + [
                "TVmaze search failed: timed out"]))

            # A shutdown gives the attempt back and releases the lease.
            def stop(_iso: Path, _record: Any) -> Any:
                raise ShutdownRequested("test")
            scripted(stop)
            try:
                retry_transient_holds(retry_args, lock_path, state_path, processed)
            except ShutdownRequested:
                pass
            else:
                raise AssertionError("a shutdown must reach the worker")
            assert retry_of(key_h)["attempts"] == 0 and "lease" not in retry_of(key_h)

            # Now dialogue contradicts the disc: stop, never publish.
            scripted(lambda iso, record: (dict(transient, reasons=creatures_reasons + [
                "Title 3: dialogue matches S01E09 rather than the disc menu guess."]),
                {"disc": None, "content": None}, None))
            retry_transient_holds(retry_args, lock_path, state_path, processed)
            assert retry_of(key_h)["state"] == "stopped" and iso_h.is_file()

            # A person named the ISO: the rename is theirs to resolve.
            iso_c, key_c, _ = hold("C", creatures_reasons)
            make_due(key_c)
            renamed_c = iso_c.with_name("All Creatures Great and Small (1978) S01E07-E08.iso")
            os.rename(iso_c, renamed_c)
            calls.clear()
            scripted(lambda iso, record: (identified(7), {}, identified(7)["assignments"]))
            retry_transient_holds(retry_args, lock_path, state_path, processed)
            assert calls == [] and renamed_c.is_file() and retry_of(key_c)["attempts"] == 0
            renamed_c.unlink()

            # Identified: published without re-encoding and archived as a
            # confirmed rename would be, with its evidence beside it.
            iso_d, key_d, files_d = hold("D", creatures_reasons)
            make_due(key_d)
            result_d = identified(5)
            scripted(lambda iso, record: (result_d, {"disc": transient, "content": result_d},
                                          result_d["assignments"]))
            retry_transient_holds(retry_args, lock_path, state_path, processed)
            season_dir = shows / "All Creatures Great and Small (1978) [tvdbid-78289]" / "Season 01"
            assert sorted(path.name for path in season_dir.glob("*.mkv")) == [
                "All Creatures Great and Small (1978) S01E05 - One.mkv",
                "All Creatures Great and Small (1978) S01E06 - Two.mkv"]
            assert not any(f.exists() for f in files_d) and not iso_d.exists()
            archived_d = processed / "All Creatures Great and Small (1978) [tvdbid-78289] S01E05-E06.iso"
            assert archived_d.is_file()
            evidence_d = read_evidence(Path(f"{archived_d}.identify.json"))
            assert evidence_d["status"] == "identified"
            assert evidence_d["resolution"]["by"] == "automatic retry"
            assert evidence_d["resolution"]["firstEpisode"] == 5
            assert evidence_d["outcomes"]["content"]["status"] == "identified"
            assert not Path(f"{iso_d}.identify.json").exists()
            assert key_d not in load_state(state_path).get("held", {})

            # Resolved elsewhere while identifying (a person's rename handled
            # by another worker removes the record): nothing is published.
            iso_f, key_f, files_f = hold("F", creatures_reasons)
            make_due(key_f)

            def resolved_elsewhere(iso: Path, record: Any) -> Any:
                with locked_queue(lock_path):
                    state = load_state(state_path)
                    del state["held"][key_f]
                    atomic_json(state_path, state)
                return identified(9), {}, identified(9)["assignments"]
            globals()["reidentify_held"] = lambda a, d, iso, r, renew: resolved_elsewhere(iso, r)
            retry_transient_holds(retry_args, lock_path, state_path, processed)
            assert all(f.is_file() for f in files_f) and iso_f.is_file()
            assert not (season_dir / "All Creatures Great and Small (1978) S01E09 - One.mkv").exists()

            # The person deleted the ISO meanwhile: stop, keep the videos.
            iso_j, key_j, files_j = hold("J", creatures_reasons)
            make_due(key_j)

            def deleted(iso: Path, record: Any) -> Any:
                iso.unlink()
                return identified(11), {}, identified(11)["assignments"]
            scripted(deleted)
            retry_transient_holds(retry_args, lock_path, state_path, processed)
            assert retry_of(key_j)["state"] == "stopped" and all(f.is_file() for f in files_j)

            # Killed after publishing but before archiving: the next run only
            # archives. A person's rename meanwhile does not interfere.
            iso_g, key_g, files_g = hold("G", creatures_reasons)
            job = {"name": series["name"], "year": 1978, "provider": "tvdbid-78289",
                   "season": 2, "first": 1, "names": ["", ""]}
            state = load_state(state_path)
            state["held"][key_g]["retry"].update(state="identified", publishing=job)
            atomic_json(state_path, state)
            publish_episodes(retry_args, files_g, series["name"], 1978, "tvdbid-78289", 2, 1, ["", ""])
            renamed_g = iso_g.with_name("All Creatures Great and Small (1978) S03E01-E02.iso")
            os.rename(iso_g, renamed_g)
            resolve_renamed_holds(retry_args, lock_path, state_path, processed)
            assert renamed_g.is_file() and key_g in load_state(state_path)["held"]
            retry_transient_holds(retry_args, lock_path, state_path, processed)
            assert not renamed_g.exists() and key_g not in load_state(state_path).get("held", {})
            assert (processed / "All Creatures Great and Small (1978) [tvdbid-78289] S02E01-E02.iso").is_file()

            # Killed before publishing: the next run publishes, then archives.
            iso_k, key_k, files_k = hold("K", creatures_reasons)
            state = load_state(state_path)
            state["held"][key_k]["retry"].update(state="identified", publishing=dict(job, first=3))
            atomic_json(state_path, state)
            retry_transient_holds(retry_args, lock_path, state_path, processed)
            assert not any(f.exists() for f in files_k) and not iso_k.exists()
            assert (shows / "All Creatures Great and Small (1978) [tvdbid-78289]" / "Season 02"
                    / "All Creatures Great and Small (1978) S02E03.mkv").is_file()

            # Held before retries existed: judged from its evidence once.
            iso_l, key_l, _ = hold("L", creatures_reasons)
            state = load_state(state_path)
            del state["held"][key_l]["retry"]
            atomic_json(state_path, state)
            calls.clear()
            scripted(lambda iso, record: (dict(transient), {}, None))
            retry_transient_holds(retry_args, lock_path, state_path, processed)
            assert retry_of(key_l)["state"] == "scheduled"

            # Killed during its last attempt (the lease expired, still
            # "scheduled"): stopped, never retried again, and the next due
            # hold is re-identified in the same run.
            iso_m, key_m, _ = hold("M", creatures_reasons)
            iso_n, key_n, _ = hold("N", creatures_reasons)
            state = load_state(state_path)
            state["held"][key_m]["retry"].update(attempts=len(RETRY_DELAYS), nextAt=0, lease={
                "workerId": "gone", "leaseId": "x", "expiresAt": 1})
            state["held"][key_n]["retry"]["nextAt"] = 0
            atomic_json(state_path, state)
            calls.clear()
            scripted(lambda iso, record: (dict(transient), {}, None))
            retry_transient_holds(retry_args, lock_path, state_path, processed)
            assert retry_of(key_m)["state"] == "stopped" and "lease" not in retry_of(key_m)
            assert retry_of(key_m)["stoppedBecause"] == "automatic attempts used up"
            assert read_evidence(Path(f"{iso_m}.identify.json"))["retry"]["state"] == "stopped"
            assert calls == [iso_n.name], calls

            # Archiving fails after publishing: recorded on the retry, other
            # holds go on, and a later run archives it.
            iso_p, key_p, files_p = hold("P", creatures_reasons)
            state = load_state(state_path)
            state["held"][key_p]["retry"].update(state="identified", publishing=dict(job, first=5))
            state["held"][key_n]["retry"]["nextAt"] = 0
            atomic_json(state_path, state)
            original_archive = archive_source

            def failing_archive(*_args: Any, **_kwargs: Any) -> Path:
                raise PermissionError("read-only _Processed")
            globals()["archive_source"] = failing_archive
            calls.clear()
            try:
                retry_transient_holds(retry_args, lock_path, state_path, processed)
            finally:
                globals()["archive_source"] = original_archive
            pending = retry_of(key_p)
            assert pending["publishing"] and "read-only _Processed" in pending["publishError"], pending
            assert not any(f.exists() for f in files_p) and iso_p.is_file()
            assert "could not be archived" in read_evidence(Path(f"{iso_p}.identify.json"))["summary"]
            assert calls == [iso_n.name], "the failed archive must not block other holds"
            calls.clear()
            retry_transient_holds(retry_args, lock_path, state_path, processed)
            assert retry_of(key_p)["publishing"], "not retried before its delay"
            state = load_state(state_path)
            state["held"][key_p]["retry"]["publishFailedAt"] = 1
            atomic_json(state_path, state)
            retry_transient_holds(retry_args, lock_path, state_path, processed)
            assert not iso_p.exists() and key_p not in load_state(state_path).get("held", {})
            assert (processed / "All Creatures Great and Small (1978) [tvdbid-78289] S02E05-E06.iso").is_file()

            # A held special is never re-identified as regular episodes.
            iso_s = inbox / "S.iso"
            iso_s.write_bytes(b"S")
            with locked_queue(lock_path):
                state = load_state(state_path)
                archived_s = park_for_identification(retry_args, iso_s, {
                    "titles": [1], "heldFiles": [str(files_d[0])], "reasons": creatures_reasons,
                    "retry": classify_reasons(creatures_reasons), "special": True}, state)
                atomic_json(state_path, state)
            key_s = held_record_key(archived_s)
            assert retry_of(key_s)["state"] == "not retryable"
            assert load_state(state_path)["held"][key_s]["special"]
            state = load_state(state_path)
            state["held"][key_s]["retry"] = {"state": "scheduled", "attempts": 0, "nextAt": 0}
            atomic_json(state_path, state)
            calls.clear()
            retry_transient_holds(retry_args, lock_path, state_path, processed)
            assert calls == [] and retry_of(key_s)["state"] == "stopped"
        finally:
            globals()["reidentify_held"] = original_reidentify
            globals()["bonsai_gate_busy"] = original_busy

    live_shaped_retry_self_test()

    special_and_layout_self_test()
    checksum_manifest_self_test()
    assert match_score("The Wire", "The Wire") == 1.0
    assert natural_key("disc2.iso") < natural_key("disc10.iso")
    with tempfile.NamedTemporaryFile() as handle:
        handle.write(b"mkvmaker duplicate self-test\n")
        handle.flush()
        digest = iso_sha256(Path(handle.name))
    assert digest == hashlib.sha256(b"mkvmaker duplicate self-test\n").hexdigest()
    print("mkvmaker auto-import self-tests passed")


def checksum_manifest_self_test() -> None:
    """The ripper's .sha256 manifest follows its ISO and names it correctly."""
    with tempfile.TemporaryDirectory() as work:
        inbox = Path(work)
        processed = inbox / "_Processed"
        digest = "ab" * 32
        source = inbox / "DISC_1.iso"
        source.write_bytes(b"iso")
        checksum_manifest(source).write_text(f"{digest}  DISC_1.iso\n", encoding="utf-8")
        ripper_sidecar(source).write_text("{}", encoding="utf-8")
        archived = archive_source(source, processed, name="Show (1978) S01E01.iso")
        assert not checksum_manifest(source).exists(), "manifest left in the inbox"
        assert checksum_manifest(archived).read_text(encoding="utf-8") == \
            f"{digest}  Show (1978) S01E01.iso\n"
        # A later disc of the same name: the existing manifest is never replaced.
        again = inbox / "Show (1978) S01E01.iso"
        again.write_bytes(b"other")
        checksum_manifest(again).write_text(f"{'cd' * 32}  {again.name}\n", encoding="utf-8")
        second = archive_source(again, processed)
        assert second.name == "Show (1978) S01E01-2.iso"
        assert checksum_manifest(second).read_text(encoding="utf-8").startswith("cd" * 32)
        assert checksum_manifest(archived).read_text(encoding="utf-8").startswith(digest)
        # A manifest that is not sha256sum-shaped is moved as it is.
        odd = inbox / "ODD.iso"
        odd.write_bytes(b"odd")
        checksum_manifest(odd).write_text("not a digest\n", encoding="utf-8")
        moved = archive_source(odd, processed)
        assert checksum_manifest(moved).read_text(encoding="utf-8") == "not a digest\n"
        # A held ISO a person renamed: its record names the original manifest.
        held = inbox / "_NeedsIdentification"
        held.mkdir()
        parked = held / "RENAMED S01E05.iso"
        parked.write_bytes(b"held")
        (held / "HELD.iso.sha256").write_text(f"{'ef' * 32}  HELD.iso\n", encoding="utf-8")
        final = archive_source(parked, processed)
        move_checksum(held / "HELD.iso.sha256", final)
        assert not (held / "HELD.iso.sha256").exists()
        assert checksum_manifest(final).read_text(encoding="utf-8") == \
            f"{'ef' * 32}  RENAMED S01E05.iso\n"


def main() -> int:
    args = parse_args()
    if args.self_test:
        self_test()
        return 0
    if args.settle_seconds < 1 or args.min_duration < 1 or args.max_attempts < 1 or args.retry_seconds < 1:
        raise SystemExit("timing, duration, and attempt values must be positive")
    if not 0.5 <= args.dominant_ratio <= 1.0:
        raise SystemExit("dominant ratio must be between 0.5 and 1.0")
    signal.signal(signal.SIGINT, request_shutdown)
    signal.signal(signal.SIGTERM, request_shutdown)
    try:
        return run(args)
    except ShutdownRequested as error:
        print(f"Mkvmaker stopped safely: {error}", file=sys.stderr)
        return 130
    except InvalidQueueState as error:
        print(f"Mkvmaker queue unavailable: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
