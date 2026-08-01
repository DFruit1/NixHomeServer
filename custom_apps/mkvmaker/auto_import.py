#!/usr/bin/env python3
"""Unattended, restart-safe DVD ISO ingestion for disc-to-jellyfin."""

from __future__ import annotations

import argparse
import difflib
import fcntl
import json
import os
import re
import signal
import shutil
import subprocess
import sys
import time
import urllib.parse
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Any


STATE_VERSION = 1
TVMAZE_API = "https://api.tvmaze.com"
USER_AGENT = "NixHomeServer-mkvmaker/1.0 (automated personal media metadata lookup)"
shutdown_signal: int | None = None


class ShutdownRequested(Exception):
    """The supervisor was asked to stop without charging a job retry."""


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
    disc: int | None


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input-dir", type=Path, required=True)
    parser.add_argument("--movies-dir", type=Path, required=True)
    parser.add_argument("--shows-dir", type=Path, required=True)
    parser.add_argument("--state-dir", type=Path, required=True)
    parser.add_argument("--progress-file", type=Path)
    parser.add_argument("--converter", required=True)
    parser.add_argument("--handbrake", default=os.environ.get("DISC_TO_JELLYFIN_HANDBRAKE", "HandBrakeCLI"))
    parser.add_argument("--settle-seconds", type=int, default=60)
    parser.add_argument("--min-duration", type=int, default=300)
    parser.add_argument("--dominant-ratio", type=float, default=0.85)
    parser.add_argument("--metadata-timeout", type=int, default=10)
    parser.add_argument("--max-attempts", type=int, default=3)
    parser.add_argument("--retry-seconds", type=int, default=900)
    parser.add_argument("--profile", choices=("standard", "compatible", "archive"), default="standard")
    parser.add_argument("--video-preset", choices=("balanced", "compact", "maximum", "fast"), default="balanced")
    parser.add_argument("--self-test", action="store_true")
    return parser.parse_args()


def atomic_json(path: Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    os.replace(temporary, path)


def load_state(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
        if value.get("version") == STATE_VERSION and isinstance(value.get("sources"), dict):
            return value
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        pass
    return {"version": STATE_VERSION, "sources": {}}


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
    result = subprocess.run(command, check=False, capture_output=True, text=True)
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


def looks_like_episode_set(titles: list[Title]) -> bool:
    if len(titles) < 3:
        return False
    durations = [title.seconds for title in titles]
    shortest = min(durations)
    longest = max(durations)
    return 8 * 60 <= shortest and longest <= 75 * 60 and longest / shortest <= 1.5


def source_hints(path: Path) -> SourceHints:
    stem = path.stem
    year_match = re.search(r"(?<!\d)((?:19|20)\d{2})(?!\d)", stem)
    season_match = re.search(r"(?i)(?:^|[^a-z0-9])(?:s|season)[ ._-]*0*(\d{1,2})(?:e\d+)?", stem)
    episode_match = re.search(r"(?i)(?:^|[^a-z0-9])s\d{1,2}[ ._-]*e0*(\d{1,3})", stem)
    disc_match = re.search(r"(?i)(?:^|[^a-z0-9])(?:disc|disk|dvd|vol(?:ume)?)[ ._-]*0*(\d{1,2})(?:[^a-z0-9]|$)", stem)

    cleaned = stem.replace("_", " ").replace(".", " ")
    cleaned = re.sub(r"(?i)\b(?:s|season)[ -]*\d{1,2}(?:[ -]*e\d{1,3})?\b", " ", cleaned)
    cleaned = re.sub(r"(?i)\b(?:disc|disk|dvd|vol(?:ume)?)[ -]*\d{1,2}\b", " ", cleaned)
    cleaned = re.sub(r"(?i)\b(?:dvd|pal|ntsc|iso|rip|backup|widescreen|fullscreen)\b", " ", cleaned)
    cleaned = re.sub(r"(?<!\d)(?:19|20)\d{2}(?!\d)", " ", cleaned)
    cleaned = re.sub(r"[\[\](){}]+", " ", cleaned)
    cleaned = re.sub(r"\s+", " ", cleaned).strip(" -")
    if not cleaned:
        cleaned = stem.replace("_", " ").strip() or "Unknown DVD"
    if cleaned.isupper() or cleaned.islower():
        cleaned = cleaned.title()
    return SourceHints(
        name=cleaned,
        year=int(year_match.group(1)) if year_match else None,
        season=int(season_match.group(1)) if season_match else None,
        episode=int(episode_match.group(1)) if episode_match else None,
        disc=int(disc_match.group(1)) if disc_match else None,
    )


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
    selected, dominant, ratio = select_titles(titles, args.min_duration, args.dominant_ratio)
    hints = source_hints(source)
    metadata = tvmaze_match(hints, len(selected), args.metadata_timeout)
    episode_like = looks_like_episode_set(selected)
    is_tv = hints.season is not None or (not dominant and episode_like)

    if is_tv:
        show = metadata["show"] if metadata else {}
        name = str(show.get("name") or hints.name)
        premiered = str(show.get("premiered") or "")
        year = int(premiered[:4]) if premiered[:4].isdigit() else hints.year
        provider = provider_id(show)
        season = hints.season or 1
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
            "episode_names": names,
            "titles": [title.index for title in selected],
            "dominant_ratio": ratio,
            "output": str(args.shows_dir),
        }

    return {
        "kind": "movie",
        "name": hints.name,
        "year": hints.year,
        "provider": None,
        "movie_disc": hints.disc,
        "titles": [title.index for title in selected],
        "dominant_ratio": ratio,
        "output": str(args.movies_dir),
    }


def converter_command(args: argparse.Namespace, source: Path, plan: dict[str, Any]) -> list[str]:
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


def public_status(args: argparse.Namespace, state: str, plan: dict[str, Any] | None = None) -> None:
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
    try:
        atomic_json(
            args.progress_file,
            {
                "schemaVersion": 1,
                "state": state,
                "updatedAt": int(time.time()),
                "conversions": conversions,
            },
        )
    except OSError as error:
        print(f"Progress reporting unavailable: {error}", file=sys.stderr)


def unique_destination(directory: Path, name: str) -> Path:
    candidate = directory / name
    counter = 2
    while candidate.exists() or candidate.is_symlink():
        candidate = directory / f"{Path(name).stem}-{counter}{Path(name).suffix}"
        counter += 1
    return candidate


def archive_source(source: Path, directory: Path) -> Path:
    directory.mkdir(parents=True, exist_ok=True)
    destination = unique_destination(directory, source.name)
    os.replace(source, destination)
    return destination


def process_source(args: argparse.Namespace, source: Path, entry: dict[str, Any]) -> None:
    plan = entry.get("plan")
    if not isinstance(plan, dict):
        plan = build_plan(args, source)
        entry["plan"] = plan
        entry["status"] = "planned"
    print(
        f"Selected DVD titles {plan['titles']} as {plan['kind']} "
        f"(largest/runtime={plan['dominant_ratio']:.1%})"
    )
    public_status(args, "converting", plan)
    command = converter_command(args, source, plan)
    process = subprocess.Popen(command)
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
    processed_dir.mkdir(exist_ok=True)
    failed_dir.mkdir(exist_ok=True)

    state_path = args.state_dir / "queue.json"
    lock_path = args.state_dir / "queue.lock"
    with lock_path.open("a+", encoding="utf-8") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print("Another mkvmaker import is already running; leaving the queue untouched.")
            return 0

        public_status(args, "idle")
        state = load_state(state_path)
        sources = state["sources"]
        now = int(time.time())
        candidates = sorted(
            (
                path
                for path in args.input_dir.iterdir()
                if path.is_file() and not path.is_symlink() and path.suffix.casefold() == ".iso"
            ),
            key=lambda path: natural_key(path.name),
        )
        live_keys = {path.name for path in candidates}
        for stale in set(sources) - live_keys:
            del sources[stale]

        failures = 0
        for source in candidates:
            stat = source.stat()
            signature = {"size": stat.st_size, "mtime_ns": stat.st_mtime_ns}
            entry = sources.setdefault(source.name, {})
            if entry.get("signature") != signature:
                sources[source.name] = {"signature": signature, "unchanged_since": now, "attempts": 0}
                print(f"Observed {source.name}; waiting {args.settle_seconds}s for the upload to settle.")
                continue
            if now - int(entry.get("unchanged_since", now)) < args.settle_seconds:
                continue
            if now < int(entry.get("retry_after", 0)):
                continue

            try:
                entry["status"] = "processing"
                atomic_json(state_path, state)
                process_source(args, source, entry)
                archived = archive_source(source, processed_dir)
                print(f"Completed {source.name}; preserved the ISO at {archived}")
                del sources[source.name]
            except ShutdownRequested as error:
                entry["status"] = "interrupted"
                entry["last_interrupted_at"] = now
                entry.pop("retry_after", None)
                print(f"Interrupted {source.name}; it will restart from durable state: {error}", file=sys.stderr)
                raise
            except Exception as error:
                failures += 1
                entry["attempts"] = int(entry.get("attempts", 0)) + 1
                entry["status"] = "retrying"
                entry["last_error"] = str(error)[-4000:]
                entry["retry_after"] = now + args.retry_seconds * entry["attempts"]
                print(f"Failed {source.name} (attempt {entry['attempts']}/{args.max_attempts}): {error}", file=sys.stderr)
                if entry["attempts"] >= args.max_attempts and source.exists():
                    archived = archive_source(source, failed_dir)
                    error_path = archived.with_suffix(archived.suffix + ".error.txt")
                    error_path.write_text(entry["last_error"] + "\n", encoding="utf-8")
                    print(f"Moved repeatedly failing ISO to {archived}", file=sys.stderr)
                    del sources[source.name]
            finally:
                public_status(args, "idle")
                atomic_json(state_path, state)
        atomic_json(state_path, state)
        return 1 if failures else 0


def self_test() -> None:
    movie = source_hints(Path("THE_MATRIX_1999_DVD_DISC_2.iso"))
    assert movie.name == "The Matrix"
    assert movie.year == 1999 and movie.disc == 2 and movie.season is None
    show = source_hints(Path("The_Wire_S03_Disc_2.iso"))
    assert show.name == "The Wire" and show.season == 3 and show.disc == 2
    titles = [Title(1, 2700, False), Title(2, 2680, False), Title(3, 5380, True)]
    selected, dominant, _ = select_titles(titles, 300, 0.85)
    assert not dominant and [title.index for title in selected] == [1, 2]
    selected, dominant, ratio = select_titles([Title(1, 5400, True), Title(2, 500, False)], 300, 0.85)
    assert dominant and selected[0].index == 1 and ratio > 0.9
    assert looks_like_episode_set(
        [Title(2, 1326, True), Title(3, 1705, False), Title(4, 1638, False), Title(5, 1523, False)]
    )
    assert not looks_like_episode_set([Title(1, 5400, True), Title(2, 1200, False), Title(3, 900, False)])
    assert match_score("The Wire", "The Wire") == 1.0
    assert natural_key("disc2.iso") < natural_key("disc10.iso")
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


if __name__ == "__main__":
    raise SystemExit(main())
