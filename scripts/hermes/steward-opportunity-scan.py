#!/usr/bin/env python3
"""Find cheap, safe, repo-grounded cleanup candidates for the board steward.

Wired as a ``hermes cron --monitor-script`` on the board-steward profile. The
monitor hashes this output byte-for-byte and suppresses the agent run while the
hash is unchanged, so the output must be stable across ticks: sorted, no
timestamps, no pids, no absolute paths that move, no ages in seconds.

It prints one ``CANDIDATE <id> <TAG> :: <detail>`` line per finding and nothing
else. The steward reads the MONITOR CHANGE DETECTED diff and files at most a
couple of low-priority cards to ``local-implementer``, each carrying the printed
id as its ``--idempotency-key``. A candidate already covered by an open
``steward-cleanup`` card is omitted, so once the steward has filed it the line
stops appearing and the next tick does not wake the agent again.

Scope is deliberately narrow. Every check is mechanical and its fix is
git-backed and revertible: a broken script, an empty stray file, an untracked
top-level artifact. Nothing here needs a judgement call, an approval, or an edit
outside the repository. Anything richer (dead code, stale comments, board or
Hermes-config drift) is the daily report's business, not an auto-filed card.

Environment overrides (used by tests and for a different checkout):
  STEWARD_REPO      repo root (default: the board's default_workdir)
  STEWARD_BOARD_DB  board sqlite path (default: ~/.hermes/.../<board>/kanban.db)
  STEWARD_BOARD     board slug (default: nixhomeserver)
"""
from __future__ import annotations

import hashlib
import json
import os
import sqlite3
import subprocess
from pathlib import Path

HERMES_ROOT = Path(os.environ.get("HERMES_ROOT", str(Path.home() / ".hermes")))
TENANT = "steward-cleanup"
BOARD = os.environ.get("STEWARD_BOARD", "nixhomeserver")


def board_repo() -> Path:
    override = os.environ.get("STEWARD_REPO")
    if override:
        return Path(override)
    board_json = HERMES_ROOT / "kanban" / "boards" / BOARD / "board.json"
    try:
        workdir = json.loads(board_json.read_text()).get("default_workdir")
    except (OSError, ValueError):
        workdir = None
    return Path(workdir) if workdir else Path("/home/dsaw/Projects/NixOS")


def board_db() -> Path:
    override = os.environ.get("STEWARD_BOARD_DB")
    if override:
        return Path(override)
    return HERMES_ROOT / "kanban" / "boards" / BOARD / "kanban.db"


def run(args: list[str], cwd: Path) -> subprocess.CompletedProcess:
    return subprocess.run(args, cwd=str(cwd), capture_output=True, text=True, timeout=30)


def git(repo: Path, *args: str) -> str:
    return run(["git", "-C", str(repo), *args], cwd=repo).stdout


def candidate_id(tag: str, detail: str) -> str:
    return hashlib.sha1(f"{tag}\x00{detail}".encode()).hexdigest()[:12]


def covered_keys() -> set[str]:
    """Idempotency keys of open steward-cleanup cards (never suppress a resolved one)."""
    db = board_db()
    if not db.exists():
        return set()
    keys: set[str] = set()
    try:
        conn = sqlite3.connect(f"file:{db}?mode=ro", uri=True, timeout=5)
    except sqlite3.Error:
        return keys
    try:
        rows = conn.execute(
            "select idempotency_key from tasks where tenant = ? and status not in"
            " ('done','archived') and idempotency_key is not null",
            (TENANT,),
        ).fetchall()
        keys = {row[0] for row in rows if row[0]}
    except sqlite3.Error:
        pass
    finally:
        conn.close()
    return keys


def shebang(path: Path) -> str:
    try:
        with path.open("r", encoding="utf-8", errors="replace") as handle:
            line = handle.readline()
    except OSError:
        return ""
    return line.strip() if line.startswith("#!") else ""


def check_syntax(repo: Path, tracked: list[str]) -> list[tuple[str, str]]:
    out = []
    for rel in tracked:
        if not rel.startswith("scripts/"):
            continue
        path = repo / rel
        if not path.is_file():
            continue
        if rel.endswith(".py"):
            try:
                compile(path.read_bytes(), rel, "exec")
            except SyntaxError as exc:
                out.append(("BROKEN_SYNTAX", f"{rel} :: line {exc.lineno}: {exc.msg}"))
            continue
        if not rel.endswith((".sh", ".bash")):
            continue
        interp = "bash" if "bash" in shebang(path) else "sh"
        proc = run([interp, "-n", str(path)], cwd=repo)
        if proc.returncode != 0:
            err = (proc.stderr or proc.stdout).strip().splitlines()
            msg = (err[-1] if err else "syntax error").replace(str(path), rel)
            out.append(("BROKEN_SYNTAX", f"{rel} :: {msg[:120]}"))
    return out


def check_empty(repo: Path, tracked: list[str]) -> list[tuple[str, str]]:
    out = []
    for rel in tracked:
        if not rel.startswith("scripts/"):
            continue
        if rel.endswith((".gitkeep", ".keep")):
            continue
        path = repo / rel
        try:
            if path.is_file() and path.stat().st_size == 0:
                out.append(("EMPTY_FILE", rel))
        except OSError:
            continue
    return out


def check_untracked_root(repo: Path) -> list[tuple[str, str]]:
    out = []
    for line in git(repo, "status", "--porcelain").splitlines():
        if not line.startswith("?? "):
            continue
        rel = line[3:].strip().rstrip("/")
        if "/" not in rel and rel:
            out.append(("UNTRACKED_ROOT", rel))
    return out


def main() -> None:
    repo = board_repo()
    if not (repo / ".git").exists():
        return
    tracked = git(repo, "ls-files").splitlines()
    caps = {"BROKEN_SYNTAX": 10, "EMPTY_FILE": 8, "UNTRACKED_ROOT": 8}
    per_tag: dict[str, int] = {}
    candidates: list[tuple[str, str]] = []
    for check in (lambda: check_syntax(repo, tracked),
                  lambda: check_empty(repo, tracked),
                  lambda: check_untracked_root(repo)):
        try:
            found = check()
        except (OSError, subprocess.SubprocessError):
            continue
        for tag, detail in found:
            if per_tag.get(tag, 0) >= caps.get(tag, 10):
                continue
            per_tag[tag] = per_tag.get(tag, 0) + 1
            candidates.append((tag, detail))

    covered = covered_keys()
    lines: list[str] = []
    seen: set[str] = set()
    for tag, detail in sorted(candidates, key=lambda c: (c[0], c[1])):
        cid = candidate_id(tag, detail)
        line = f"CANDIDATE {cid} {tag} :: {detail}"
        if f"{TENANT}:{cid}" in covered or line in seen:
            continue
        seen.add(line)
        lines.append(line)
        if len(lines) >= 12:
            break

    if lines:
        print("\n".join(lines))


if __name__ == "__main__":
    main()
