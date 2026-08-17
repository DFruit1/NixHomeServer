#!/usr/bin/env python3
"""Unattended, restart-safe DVD ISO ingestion for disc-to-jellyfin."""

from __future__ import annotations

import argparse
import difflib
import fcntl
import hashlib
import json
import os
import re
import secrets
import signal
import shutil
import subprocess
import sys
import tempfile
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


def request_shutdown(signum: int, _frame: Any) -> None:
    global shutdown_signal
    shutdown_signal = signum


@dataclass(frozen=True)
class Title:
    index: int
    seconds: int
    main_feature: bool


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
        if 1 <= candidate <= 99:
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


def scan_titles(handbrake: str, source: Path) -> list[Title]:
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
    result = subprocess.run(
        command,
        check=False,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
    )
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
            titles.append(Title(index=index, seconds=seconds, main_feature=index == main))
    return sorted(titles, key=lambda title: title.index)


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
    if len(titles) < 3:
        return False
    durations = [title.seconds for title in titles]
    shortest = min(durations)
    longest = max(durations)
    return 8 * 60 <= shortest and longest <= 75 * 60 and longest / shortest <= 1.5


def source_hints(path: Path) -> SourceHints:
    stem = path.stem
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


def build_plan(args: argparse.Namespace, source: Path) -> dict[str, Any]:
    titles = scan_titles(args.handbrake, source)
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
    if not hints.is_jellyfin_named:
        metadata = tvmaze_match(hints, len(selected), args.metadata_timeout)
    else:
        metadata = None
    episode_like = looks_like_episode_set(selected)
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
        season = season or 1
        media_name = jellyfin_name(name, year, provider)
        first = hints.episode or existing_next_episode(args.shows_dir, media_name, season)
        if first is None:
            first = ((hints.disc or 1) - 1) * len(selected) + 1
        by_number = {
            (int(episode["season"]), int(episode["number"])): str(episode.get("name") or "")
            for episode in (metadata or {}).get("episodes", [])
            if episode.get("season") is not None and episode.get("number") is not None
        }
        names = [
            by_number.get((season, first + offset)) or f"DVD Title {title.index:02d}"
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


def archive_source(source: Path, directory: Path, plan: dict[str, Any] | None = None) -> Path:
    directory.mkdir(parents=True, exist_ok=True)
    destination = unique_destination(directory, source.name)
    os.replace(source, destination)
    if plan:
        manifest = destination.with_suffix(".iso.output.json")
        manifest.write_text(
            json.dumps({
                "sourceIso": source.name,
                "outputDir": plan.get("output", ""),
                "title": plan.get("name", ""),
                "kind": plan.get("kind", ""),
            }),
            encoding="utf-8",
        )
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
        plan = build_plan(args, source)
        entry["plan"] = plan
        entry["status"] = "planned"
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
    )
    renew_after = time.monotonic() + max(1.0, args.lease_seconds / 3)
    while True:
        if shutdown_signal is not None:
            if process.poll() is None:
                process.send_signal(signal.SIGINT)
            try:
                process.wait(timeout=30)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
            raise ShutdownRequested(f"received {signal.Signals(shutdown_signal).name}")
        if renew_lease is not None and time.monotonic() >= renew_after:
            if not renew_lease():
                if process.poll() is None:
                    process.send_signal(signal.SIGINT)
                try:
                    process.wait(timeout=30)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
                raise LeaseLost(f"queue lease for {source.name} could not be renewed")
            renew_after = time.monotonic() + max(1.0, args.lease_seconds / 3)
        try:
            return_code = process.wait(timeout=0.5)
            break
        except subprocess.TimeoutExpired:
            continue
    if return_code in (130, -signal.SIGINT, -signal.SIGTERM):
        raise ShutdownRequested(f"converter stopped with status {return_code}")
    if return_code != 0:
        raise subprocess.CalledProcessError(return_code, command)


def run(args: argparse.Namespace) -> int:
    for path in (args.input_dir, args.movies_dir, args.shows_dir, args.state_dir):
        path.mkdir(parents=True, exist_ok=True)
    processed_dir = args.input_dir / "_Processed"
    failed_dir = args.input_dir / "_Failed"
    duplicate_dir = args.input_dir / "_Duplicate"
    processed_dir.mkdir(exist_ok=True)
    failed_dir.mkdir(exist_ok=True)
    duplicate_dir.mkdir(exist_ok=True)

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

    public_status(args, "idle", queued=pending_titles())
    failures = 0
    while True:
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
                    entry["retry_after"] = now + args.retry_seconds * entry["attempts"]
                    entry.pop("lease", None)
                    print(
                        f"Refusing to convert {source.name} because duplicate detection "
                        f"failed (attempt {entry['attempts']}/{args.max_attempts}): "
                        f"{duplicate_error}",
                        file=sys.stderr,
                    )
                    if entry["attempts"] >= args.max_attempts and source.exists():
                        archived = archive_source(source, failed_dir)
                        error_path = archived.with_suffix(".iso.error.txt")
                        error_path.write_text(entry["last_error"] + "\n", encoding="utf-8")
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
                archived = archive_source(source, processed_dir, local_entry.get("plan"))
                print(f"Completed {source.name}; preserved the ISO at {archived}")
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
                            error_path = archived.with_suffix(".iso.error.txt")
                            error_path.write_text(entry["last_error"] + "\n", encoding="utf-8")
                            print(f"Moved repeatedly failing ISO to {archived}", file=sys.stderr)
                            del state["sources"][source.name]
                        atomic_json(state_path, state)
        finally:
            public_status(args, "idle", queued=pending_titles())
    release_source_lock(active_source_lock)
    return 1 if failures else 0


def self_test() -> None:
    movie = source_hints(Path("THE_MATRIX_1999_DVD_DISC_2.iso"))
    assert movie.name == "The Matrix"
    assert movie.year == 1999 and movie.disc == 2 and movie.season is None
    assert movie.provider is None and not movie.is_jellyfin_named
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

    titles = [Title(1, 2700, False), Title(2, 2680, False), Title(3, 5380, True)]
    selected, dominant, _ = select_titles(titles, 300, 0.85)
    assert not dominant and [title.index for title in selected] == [1, 2]
    selected, dominant, ratio = select_titles([Title(1, 5400, True), Title(2, 500, False)], 300, 0.85)
    assert dominant and selected[0].index == 1 and ratio > 0.9
    assert looks_like_episode_set(
        [Title(2, 1326, True), Title(3, 1705, False), Title(4, 1638, False), Title(5, 1523, False)]
    )
    assert not looks_like_episode_set([Title(1, 5400, True), Title(2, 1200, False), Title(3, 900, False)])
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
    assert match_score("The Wire", "The Wire") == 1.0
    assert natural_key("disc2.iso") < natural_key("disc10.iso")
    with tempfile.NamedTemporaryFile() as handle:
        handle.write(b"mkvmaker duplicate self-test\n")
        handle.flush()
        digest = iso_sha256(Path(handle.name))
    assert digest == hashlib.sha256(b"mkvmaker duplicate self-test\n").hexdigest()
    print("mkvmaker auto-import self-tests passed")


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
