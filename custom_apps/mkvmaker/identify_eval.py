#!/usr/bin/env python3
"""Measure `disc-identify content` against episodes already in the library.

An on-demand evaluation, not a CI test. Ground truth comes from the library's
Jellyfin file names (`Show (Year) [tag] SxxEyy - Title.mkv`). Consecutive
episodes are grouped into synthetic "discs" of 1-4 titles and identified
under several disc-stage contexts:

  a  series known, no proposal
  b  series known, correct proposal (as a menu reading would give)
  c  series known, deliberately wrong proposal (shifted one episode); it must
     never be reported as identified with those wrong episodes
  d  two candidate series and no proposal (for shows given with --rival)

The identifier answers in TVmaze numbering while the library may use another
layout (Sherlock Holmes 1984: TMDB 7 seasons, TVmaze 4), so episodes are
compared by normalised title; a number that only matches the library layout is
reported as `layout_only`, not as wrong.

Python rather than Rust (AGENTS.md prefers Rust): this only orchestrates the
existing `disc-identify` binary and parses its JSON, and it has to run on the
server against the deployed binaries with the deployed Python, without a new
build or deployment. Every identification decision stays in the binary;
`--offline` re-runs that binary on its own replay cache instead of re-deriving
its rules here.
"""
from __future__ import annotations

import argparse
import difflib
import json
import os
import random
import re
import shlex
import subprocess
import sys
import time
import unicodedata
import urllib.request
from pathlib import Path
from typing import Any

EPISODE_FILE = re.compile(r"^(?P<show>.+?) S(?P<season>\d{2,})E(?P<episode>\d{2,})(?:-E\d+)? - (?P<title>.+)\.mkv$")
TVMAZE = "https://api.tvmaze.com"
KNOWN_OUTCOME_KEYS = {"schemaVersion", "stage", "status", "series", "season", "assignments",
                      "candidates", "summary", "reasons", "menu", "contentDiagnostics"}


def normalize(text: str) -> str:
    """Same idea as disc-identify's text::normalize, plus accent folding."""
    text = unicodedata.normalize("NFKD", text)
    text = "".join(ch for ch in text if not unicodedata.combining(ch))
    text = text.replace("&", " and ").replace("'", "").replace("’", "")
    words = re.findall(r"[^\W_]+", text.lower())
    if len(words) > 1 and words[0] in ("the", "a", "an"):
        words = words[1:]
    return " ".join(words)


def label(season: int | None, episode: int | None) -> str:
    if season is None or episode is None:
        return "?"
    return f"S{season:02d}E{episode:02d}"


def fetch_json(url: str, cache: Path) -> Any:
    cache.mkdir(parents=True, exist_ok=True)
    file = cache / (re.sub(r"[^A-Za-z0-9]+", "_", url) + ".json")
    if file.exists():
        return json.loads(file.read_text())
    request = urllib.request.Request(url, headers={"User-Agent": "nixhomeserver-identify-eval/1"})
    with urllib.request.urlopen(request, timeout=30) as response:
        value = json.load(response)
    file.write_text(json.dumps(value))
    return value


def show_record(tvmaze_id: int, cache: Path) -> dict[str, Any]:
    """The `Show` object disc-identify reads from a context (camelCase)."""
    value = fetch_json(f"{TVMAZE}/shows/{tvmaze_id}", cache)
    externals = value.get("externals") or {}
    provider = None
    if externals.get("thetvdb"):
        provider = f"tvdbid-{externals['thetvdb']}"
    elif externals.get("imdb"):
        provider = f"imdbid-{externals['imdb']}"
    premiered = value.get("premiered") or ""
    return {
        "tvmazeId": tvmaze_id,
        "name": value["name"].strip(),
        "year": int(premiered[:4]) if premiered[:4].isdigit() else None,
        "provider": provider,
        "imdbId": externals.get("imdb") or None,
    }


def tvmaze_episodes(tvmaze_id: int, cache: Path) -> list[dict[str, Any]]:
    items = fetch_json(f"{TVMAZE}/shows/{tvmaze_id}/episodes", cache)
    return sorted(({"season": i["season"], "episode": i["number"], "name": (i.get("name") or "").strip()}
                   for i in items if isinstance(i.get("number"), int)),
                  key=lambda e: (e["season"], e["episode"]))


def match_title(title: str, episodes: list[dict[str, Any]]) -> dict[str, Any] | None:
    wanted = normalize(title)
    exact = [e for e in episodes if normalize(e["name"]) == wanted]
    if len(exact) == 1:
        return exact[0]
    scored = sorted(((difflib.SequenceMatcher(None, wanted, normalize(e["name"])).ratio(), i)
                     for i, e in enumerate(episodes)), reverse=True)
    if scored and scored[0][0] >= 0.88 and (len(scored) == 1 or scored[1][0] < scored[0][0] - 0.05):
        return episodes[scored[0][1]]
    return None


def library_episodes(folder: Path) -> list[dict[str, Any]]:
    found = []
    for path in sorted(folder.rglob("*.mkv")):
        match = EPISODE_FILE.match(path.name)
        if not match or int(match["season"]) == 0:
            continue
        found.append({"path": str(path), "season": int(match["season"]),
                      "episode": int(match["episode"]), "title": match["title"]})
    return sorted(found, key=lambda e: (e["season"], e["episode"]))


def make_discs(episodes: list[dict[str, Any]], budget: int, rng: random.Random) -> list[list[dict[str, Any]]]:
    """Up to `budget` episodes as non-overlapping runs of 1-4 consecutive ones."""
    by_season: dict[int, list[dict[str, Any]]] = {}
    for episode in episodes:
        by_season.setdefault(episode["season"], []).append(episode)
    used: set[str] = set()
    discs: list[list[dict[str, Any]]] = []
    attempts = 0
    while sum(len(d) for d in discs) < budget and attempts < 500:
        attempts += 1
        size = min(rng.randint(1, 4), budget - sum(len(d) for d in discs))
        season = rng.choice(sorted(by_season))
        run = by_season[season]
        if len(run) < size:
            continue
        start = rng.randrange(0, len(run) - size + 1)
        chosen = run[start:start + size]
        if any(e["episode"] != chosen[0]["episode"] + i for i, e in enumerate(chosen)):
            continue
        if any(e["path"] in used for e in chosen):
            continue
        used.update(e["path"] for e in chosen)
        discs.append(chosen)
    return sorted(discs, key=lambda d: (d[0]["season"], d[0]["episode"]))


def disc_name(show: dict[str, Any], disc: list[dict[str, Any]]) -> str:
    """Library numbering of a synthetic disc, e.g. "Rumpole of the Bailey S03E03-E06"."""
    first = disc[0]
    return f"{show['name']} {label(first['season'], first['episode'])}" + (
        f"-E{disc[-1]['episode']:02d}" if len(disc) > 1 else "")


def identifier_features(identifier: str) -> set[str]:
    try:
        text = subprocess.run([identifier, "content", "--help"], capture_output=True, text=True,
                              timeout=60).stdout
    except OSError as error:
        sys.exit(f"cannot run {identifier}: {error}")
    return {flag for flag in ("--replay-cache", "--replay-only") if flag in text}


def subtitle_cache_entries(replay: Path | None) -> int:
    if replay is None or not replay.is_dir():
        return 0
    return sum(1 for p in replay.glob("subtitle-*.json"))


def content_digest(outcome: dict[str, Any]) -> dict[str, Any] | None:
    """The deciding parts of `contentDiagnostics` (schema 2), when present."""
    diagnostics = outcome.get("contentDiagnostics")
    if not isinstance(diagnostics, dict):
        return None
    decision = diagnostics.get("decision") or {}
    budget = diagnostics.get("subtitleDownloads") or {}
    titles = []
    for title in diagnostics.get("titles") or []:
        scores = sorted((c["containment"] for c in title.get("subtitles") or []
                         if isinstance(c.get("containment"), (int, float))), reverse=True)
        pick = title.get("pick") or {}
        titles.append({
            "title": title.get("title"),
            "pick": label(pick.get("season"), pick.get("episode")) if pick else None,
            "pickRule": title.get("pickRule"),
            "verdict": title.get("verdict"),
            "bonsaiConfidence": title.get("bonsaiConfidence"),
            "bestContainment": scores[0] if scores else None,
            "runnerUpContainment": scores[1] if len(scores) > 1 else None,
        })
    return {
        "rule": decision.get("rule"),
        "subtitleDownloadsUsed": budget.get("used"),
        "subtitleCacheHits": budget.get("cacheHits"),
        "titles": titles,
    }


def judge(outcome: dict[str, Any], disc: list[dict[str, Any]], show: dict[str, Any],
          wrong_proposal: list[tuple[int, int]] | None) -> dict[str, Any]:
    """Compare an outcome with the ground truth, by episode title."""
    series = outcome.get("series") or {}
    series_ok = series.get("tvmazeId") == show["tvmazeId"]
    by_title = {a.get("title"): a for a in outcome.get("assignments") or [] if isinstance(a, dict)}
    titles = []
    for index, truth in enumerate(disc, start=1):
        assigned = by_title.get(index)
        entry = {
            "title": index,
            "file": Path(truth["path"]).name,
            "truthLibrary": label(truth["season"], truth["episode"]),
            "truthTvmaze": label(truth["tvmaze"]["season"], truth["tvmaze"]["episode"]),
            "truthName": truth["title"],
        }
        if not assigned:
            entry["verdict"] = "none"
        else:
            numbers = (assigned.get("season"), assigned.get("episode"))
            entry.update({"assigned": label(*numbers), "assignedName": assigned.get("name", ""),
                          "evidence": assigned.get("evidence", "")})
            name_ok = normalize(str(assigned.get("name", ""))) == normalize(truth["tvmaze"]["name"]) \
                or normalize(str(assigned.get("name", ""))) == normalize(truth["title"])
            tvmaze_ok = numbers == (truth["tvmaze"]["season"], truth["tvmaze"]["episode"])
            library_ok = numbers == (truth["season"], truth["episode"])
            if series_ok and (name_ok or tvmaze_ok):
                entry["verdict"] = "correct"
                entry["layoutDiffers"] = not library_ok
            elif series_ok and library_ok:
                entry["verdict"] = "layout_only"
            else:
                entry["verdict"] = "wrong"
        titles.append(entry)
    verdicts = {t["verdict"] for t in titles}
    status = outcome.get("status")
    if status == "identified":
        if "wrong" in verdicts or "none" in verdicts:
            result = "identified-WRONG"
        elif "layout_only" in verdicts:
            result = "identified-layout-mismatch"
        else:
            result = "identified-correct"
    else:
        result = "held"
    guess_ok = bool(titles) and all(t["verdict"] == "correct" for t in titles)
    followed_wrong = wrong_proposal is not None and status == "identified" and [
        (by_title.get(i + 1) or {}).get("episode") for i in range(len(disc))] == [e for _, e in wrong_proposal]
    return {"result": result, "guessCorrect": guess_ok, "followedWrongProposal": followed_wrong,
            "titles": titles}


def run_identifier(args: argparse.Namespace, context: dict[str, Any], disc: list[dict[str, Any]],
                   run_dir: Path, variant_args: list[str], subtitles: tuple[int, bool],
                   replay: Path | None) -> tuple[dict[str, Any] | None, str, float]:
    run_dir.mkdir(parents=True, exist_ok=True)
    context_file = run_dir / "context.json"
    context_file.write_text(json.dumps(context))
    command = [args.identifier, "content", "--context", str(context_file),
               "--cache-dir", str(args.work / "identify-cache"),
               "--work-dir", str(run_dir / "work"),
               "--ffmpeg", args.ffmpeg, "--parakeet", args.parakeet,
               "--parakeet-model", args.parakeet_model, "--threads", str(args.threads)]
    if args.bonsai_url:
        command += ["--bonsai-url", args.bonsai_url]
    allowance, enabled = subtitles
    if enabled:
        command += ["--owner", args.owner, "--subtitle-socket", args.subtitle_socket,
                    "--max-subtitle-downloads", str(allowance)]
    if replay is not None:
        command += ["--replay-cache", str(replay)]
        if args.offline:
            command += ["--replay-only"]
    for index, episode in enumerate(disc, start=1):
        command += ["--video", episode["path"], "--title", str(index)]
    command += variant_args
    started = time.monotonic()
    try:
        process = subprocess.run(command, capture_output=True, text=True, timeout=args.run_timeout)
    except subprocess.TimeoutExpired:
        return None, "timed out", time.monotonic() - started
    elapsed = time.monotonic() - started
    if process.returncode != 0:
        return None, (process.stderr or "").strip()[-500:], elapsed
    (run_dir / "outcome.json").write_text(process.stdout)
    try:
        return json.loads(process.stdout), "", elapsed
    except json.JSONDecodeError:
        return None, "invalid JSON", elapsed


def scenarios_for(disc: list[dict[str, Any]], show: dict[str, Any], rival: dict[str, Any] | None,
                  episodes: list[dict[str, Any]], wanted: set[str]) -> list[tuple[str, dict[str, Any], Any]]:
    tv = [e["tvmaze"] for e in disc]
    one_season = all(t["season"] == tv[0]["season"] and t["episode"] == tv[0]["episode"] + i
                     for i, t in enumerate(tv))
    out = []
    if "a" in wanted:
        out.append(("a", {"series": show, "season": None, "assignments": [], "candidates": [show]}, None))
    if one_season and ("b" in wanted or "c" in wanted):
        season = tv[0]["season"]
        numbers = {e["episode"]: e["name"] for e in episodes if e["season"] == season}

        def proposal(shift: int) -> list[dict[str, Any]]:
            return [{"title": i, "season": season, "episode": t["episode"] + shift,
                     "name": numbers.get(t["episode"] + shift, ""), "evidence": "menu lists this title"}
                    for i, t in enumerate(tv, start=1)]
        if "b" in wanted:
            out.append(("b", {"series": show, "season": season, "assignments": proposal(0),
                              "candidates": [show]}, None))
        if "c" in wanted:
            shift = 1 if tv[-1]["episode"] + 1 in numbers else -1
            if tv[0]["episode"] + shift in numbers:
                wrong = proposal(shift)
                out.append(("c", {"series": show, "season": season, "assignments": wrong,
                                  "candidates": [show]},
                            [(w["season"], w["episode"]) for w in wrong]))
    if "d" in wanted and rival is not None:
        out.append(("d", {"series": None, "season": None, "assignments": [],
                          "candidates": [show, rival]}, None))
    return out


def summarize(report: dict[str, Any]) -> str:
    lines = [f"identify-eval {report['startedAt']}  identifier {report['identifier']}"]
    for variant, runs in report["variants"].items():
        lines.append(f"\nvariant {variant} {report['variantArgs'].get(variant) or '(production thresholds)'}")
        for scenario in sorted({r["scenario"] for r in runs}):
            subset = [r for r in runs if r["scenario"] == scenario]
            counts: dict[str, int] = {}
            for run in subset:
                counts[run["result"]] = counts.get(run["result"], 0) + 1
            titles = sum(len(r["titles"]) for r in subset)
            correct_titles = sum(len(r["titles"]) for r in subset if r["result"] == "identified-correct")
            guess = sum(1 for r in subset if r["result"] == "held" and r["guessCorrect"])
            relabelled = sum(1 for r in subset if r["result"] == "identified-correct"
                             for t in r["titles"] if t.get("layoutDiffers"))
            lines.append(
                f"  {scenario}: discs={len(subset)} titles={titles} "
                f"identified-correct={counts.get('identified-correct', 0)} ({correct_titles} titles) "
                f"identified-WRONG={counts.get('identified-WRONG', 0)} "
                f"layout-mismatch={counts.get('identified-layout-mismatch', 0)} "
                f"held={counts.get('held', 0)} (best guess right {guess}) errors={counts.get('error', 0)} "
                f"correct-but-TVmaze-numbered={relabelled}")
        for run in runs:
            if run["result"] in ("identified-WRONG", "identified-layout-mismatch", "error"):
                detail = run.get("error") or "; ".join(
                    f"{t['truthName']}→{t.get('assigned', '-')} {t.get('assignedName', '')}" for t in run["titles"])
                rule = (run.get("content") or {}).get("rule")
                lines.append(f"  !! {run['scenario']} {run['disc']}: {run['result']}: {detail}"
                             + (f" [{rule}]" if rule else ""))
    lines.append(f"\nsubtitle broker requests charged: {report['subtitleDownloadsCharged']}")
    return "\n".join(lines)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--shows-root", type=Path, default=Path("/mnt/data/shared/_Videos/_Shows"))
    parser.add_argument("--show", action="append", required=True, metavar="FOLDER=TVMAZEID",
                        help="library series folder (or its prefix) and its TVmaze id")
    parser.add_argument("--rival", action="append", default=[], metavar="TVMAZEID=TVMAZEID",
                        help="second candidate series for scenario d")
    parser.add_argument("--episodes-per-show", type=int, default=5)
    parser.add_argument("--seed", type=int, default=1)
    parser.add_argument("--disc", help="only evaluate discs whose name matches this regular expression")
    parser.add_argument("--scenarios", default="abcd")
    parser.add_argument("--work", type=Path, required=True, help="cache and output directory")
    parser.add_argument("--identifier", default="disc-identify")
    parser.add_argument("--ffmpeg", default="ffmpeg")
    parser.add_argument("--parakeet", required=True)
    parser.add_argument("--parakeet-model", required=True)
    parser.add_argument("--threads", type=int, default=4)
    parser.add_argument("--bonsai-url")
    parser.add_argument("--subtitle-budget", type=int, default=0,
                        help="total OpenSubtitles requests this evaluation may make (default none)")
    parser.add_argument("--subtitle-scenarios", default="b",
                        help="scenarios that may use the subtitle budget")
    parser.add_argument("--owner", default="")
    parser.add_argument("--subtitle-socket", default="")
    parser.add_argument("--variant", action="append", default=[], metavar="NAME=ARGS",
                        help="extra identifier arguments, e.g. 'loose=--bonsai-min-confidence 0.4'")
    parser.add_argument("--offline", action="store_true",
                        help="answer only from the identifier's replay cache (no ASR, Bonsai or subtitles)")
    parser.add_argument("--run-timeout", type=int, default=3600)
    parser.add_argument("--out", type=Path)
    parser.add_argument("--plan-only", action="store_true", help="print the discs and scenarios, run nothing")
    args = parser.parse_args()
    if args.subtitle_budget and not (args.owner and args.subtitle_socket):
        parser.error("--subtitle-budget needs --owner and --subtitle-socket")
    return args


def main() -> None:
    args = parse_args()
    args.work.mkdir(parents=True, exist_ok=True)
    features = identifier_features(args.identifier)
    replay = args.work / "replay" if "--replay-cache" in features else None
    if args.offline and "--replay-only" not in features:
        sys.exit("--offline needs an identifier with --replay-only")
    if replay is None:
        print("note: this identifier has no --replay-cache; every run transcribes again", flush=True)
    meta = args.work / "tvmaze"
    rivals = {int(a): int(b) for a, b in (item.split("=", 1) for item in args.rival)}
    variants: dict[str, list[str]] = {"production": []}
    for item in args.variant:
        name, _, extra = item.partition("=")
        variants[name] = shlex.split(extra)
    rng = random.Random(args.seed)
    wanted = set(args.scenarios)

    plan = []
    for item in args.show:
        prefix, _, ident = item.rpartition("=")
        tvmaze_id = int(ident)
        folders = [p for p in args.shows_root.iterdir() if p.is_dir() and p.name.startswith(prefix)]
        if len(folders) != 1:
            sys.exit(f"--show {prefix!r} matches {len(folders)} library folders")
        show = show_record(tvmaze_id, meta)
        rival = show_record(rivals[tvmaze_id], meta) if tvmaze_id in rivals else None
        episodes = tvmaze_episodes(tvmaze_id, meta)
        library = library_episodes(folders[0])
        unmatched = []
        for episode in library:
            episode["tvmaze"] = match_title(episode["title"], episodes)
            if episode["tvmaze"] is None:
                unmatched.append(episode["title"])
        if unmatched:
            print(f"{show['name']}: no TVmaze title match for {unmatched}; left out", flush=True)
        library = [e for e in library if e["tvmaze"] is not None]
        for disc in make_discs(library, args.episodes_per_show, rng):
            if args.disc and not re.search(args.disc, disc_name(show, disc)):
                continue
            plan.append((show, rival, episodes, disc))

    if args.plan_only:
        for show, rival, episodes, disc in plan:
            kinds = "".join(s for s, _, _ in scenarios_for(disc, show, rival, episodes, wanted))
            print(f"{show['name']}: " + ", ".join(
                f"{label(e['season'], e['episode'])}={label(e['tvmaze']['season'], e['tvmaze']['episode'])}"
                for e in disc) + f"  scenarios {kinds}")
        return
    budget = args.subtitle_budget
    charged = 0
    report: dict[str, Any] = {
        "startedAt": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "identifier": args.identifier,
        "offline": args.offline, "replayCache": bool(replay),
        "variantArgs": {k: shlex.join(v) for k, v in variants.items()}, "variants": {},
    }
    run_number = 0
    out = args.out or args.work / "identify-eval.json"
    stamp = time.strftime("%Y%m%d-%H%M%S")
    for variant, extra in variants.items():
        runs = report["variants"].setdefault(variant, [])
        for show, rival, episodes, disc in plan:
            name = disc_name(show, disc)
            for scenario, context, wrong in scenarios_for(disc, show, rival, episodes, wanted):
                run_number += 1
                allowance = 0
                use_subtitles = False
                if scenario in args.subtitle_scenarios and (budget - charged > 0 or replay is not None):
                    allowance = max(0, min(budget - charged, 3 * len(disc)))
                    use_subtitles = allowance > 0 or (replay is not None and budget > 0)
                before = subtitle_cache_entries(replay)
                print(f"[{run_number}] {variant} {scenario} {name}", flush=True)
                outcome, error, elapsed = run_identifier(
                    args, context, disc, args.work / "runs" / f"{stamp}-{run_number:03d}", extra,
                    (allowance, use_subtitles), replay)
                digest = content_digest(outcome) if outcome is not None else None
                if use_subtitles and not args.offline:
                    if digest is not None and isinstance(digest["subtitleDownloadsUsed"], int):
                        # Broker cache hits are free; only spent downloads count.
                        charged += digest["subtitleDownloadsUsed"]
                    else:
                        charged += subtitle_cache_entries(replay) - before if replay is not None else allowance
                if outcome is None:
                    judged = {"result": "error", "guessCorrect": False, "followedWrongProposal": False,
                              "titles": [], "error": error}
                else:
                    judged = judge(outcome, disc, show, wrong)
                    judged["status"] = outcome.get("status")
                    judged["summary"] = outcome.get("summary")
                    judged["reasons"] = outcome.get("reasons") or []
                    if digest is not None:
                        judged["content"] = digest
                    extra_keys = {k: v for k, v in outcome.items() if k not in KNOWN_OUTCOME_KEYS}
                    if extra_keys:
                        judged["diagnostics"] = extra_keys
                runs.append({"scenario": scenario, "disc": name, "series": show["name"],
                             "subtitles": use_subtitles, "seconds": round(elapsed, 1), **judged})
                print(f"    {judged['result']} in {elapsed:.0f}s", flush=True)
                report["subtitleDownloadsCharged"] = charged
                out.write_text(json.dumps(report, indent=2))
    report["subtitleDownloadsCharged"] = charged
    out.write_text(json.dumps(report, indent=2))
    text = summarize(report)
    out.with_suffix(".txt").write_text(text + "\n")
    print(text)


if __name__ == "__main__":
    main()
