#!/usr/bin/env bash
# Reclaim stale kanban worktrees from <repo>/.worktrees/.
#
# Why this exists
# ---------------
# Hermes removes a completed card's worktree at completion time, but only when
# the tree is clean AND every commit is reachable from a remote-tracking ref.
# A worker that finishes before the durability sync has pushed its branch is
# therefore preserved on purpose, and nothing later revisits it once the sync
# has published it. `hermes worktree prune` deliberately skips kanban `t_*`
# trees (they belong to the dispatcher lifecycle), and `hermes kanban gc` only
# prunes DB events and logs. This closes that gap without touching a live card.
#
# Safety contract (mirrors hermes_cli.kanban_db_workspace._cleanup_worktree_workspace)
# ---------------------------------------------------------------------------------
# A tree is removed only when ALL of the following hold:
#   * it is a linked worktree under <repo>/.worktrees/ (never the main checkout);
#   * the board positively attributes it to a card whose status is terminal,
#     so a tree owned by an open card, or by no card on this board, is kept;
#   * the working tree is clean (tracked and untracked — untouched scratch is
#     preserved, matching hermes);
#   * any ignored content is reproducible scratch/build output, so a gitignored
#     evidence file, dataset or credential document is never destroyed;
#   * every commit is reachable from a remote-tracking ref (fully published);
#   * no open card on any board cites the tree's path or workspace ID, so a
#     workspace a finished producer card left behind stays while an open
#     decision, review or audit card still references it as retained evidence
#     (citation guard).
# The board read includes archived cards and its shape is validated: an
# unreadable or unexpected board fails the run instead of silently treating
# every tree as unowned. The citation guard reads every board database under
# HERMES_ROOT (default ~/.hermes) the same fail-closed way. The default action
# is a dry run; pass --apply to remove. Local `wt/<id>` branches are kept; only
# the directory is reclaimed.
#
# Ownership is the only path to deletion. A clean, published tree that no card
# on the selected board owns is reported as unowned and preserved, because it
# may belong to another board, to a manual checkout, or to retained evidence
# that git does not track. `--include-unowned` opts into reaping those.
#
# Board state is read through `hermes kanban list --json --archived` so this
# never depends on the board DB schema. The current board is used unless
# --board is given.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The reaper is repository-wide: target the primary checkout's .worktrees even
# when invoked through a linked checkout's copy of this script, so a run from a
# worktree cannot silently classify nothing. `git worktree list` prints the main
# working tree first. Fall back to the script's own location when git metadata
# is unavailable.
repo_root=""
if wt_list="$(git -C "$script_dir" worktree list --porcelain 2>/dev/null)" && [[ -n "$wt_list" ]]; then
  first_line="${wt_list%%$'\n'*}"
  if [[ "$first_line" == "worktree "* ]]; then
    repo_root="$(realpath -m -- "${first_line#worktree }")"
  fi
fi
[[ -n "$repo_root" ]] || repo_root="$(cd "$script_dir/../.." && pwd)"
worktrees_dir="$repo_root/.worktrees"
worktrees_real="$(realpath -m -- "$worktrees_dir")"

apply=false
board=""
bytes=false
include_unowned=false
accept_ignored=false
hermes_bin="${HERMES_BIN:-hermes}"

# Statuses after which a card no longer needs its workspace. Archived cards are
# terminal too, and `kanban list` hides them unless --archived is passed.
terminal_statuses="done archived failed cancelled"
is_terminal() {
  case " $terminal_statuses " in
    *" $1 "*) return 0 ;;
    *) return 1 ;;
  esac
}

# Ignored paths that are safe to delete: reproducible build output and agent
# scratch. Anything else (an ignored note, dataset, database or credential
# file) preserves the tree, so local-only evidence is never destroyed.
ignored_disposable() { # <ignored path from git status>
  local p="${1%/}" base
  base="${p##*/}"
  case "$base" in
    .tmp|.cache|.direnv|target|node_modules|dist|result|__pycache__|\
    test-results|playwright-report|playwright|.shutlog)
      return 0 ;;
    *.pyc|*.pyo) return 0 ;;
  esac
  return 1
}

usage() {
  cat <<'EOF'
Usage: scripts/hermes/reap-kanban-worktrees.sh [--apply] [--bytes] [--board <slug>]
                                               [--include-unowned] [--accept-ignored]

Classify and reclaim stale kanban worktrees under .worktrees/.

  --apply             Remove the trees classified reap; default is a dry run.
  --bytes             Include disk-byte accounting (walks every tree with du);
                      the default dry run reports counts only and stays cheap.
  --board <slug>      Read card state from this board (default: current board).
  --include-unowned   Also reap clean, published trees that no card on this
                      board owns. Destructive: a tree belonging to another
                      board, to a manual checkout, or to retained evidence looks
                      identical. Review the default dry run first.
  --accept-ignored    Also reap trees whose ignored content is not reproducible
                      scratch/build output, e.g. an ignored evidence document.
                      Destructive; the dry run lists the paths involved.
  -h, --help          Show this help.

A tree is reapable only when a terminal card owns it, the tree is clean, its
ignored content is disposable, every commit is reachable from a
remote-tracking ref, and no open card on any board cites its path or workspace
ID. Everything else is preserved and reported with its reason.
EOF
}

while (($# > 0)); do
  case "$1" in
    --apply) apply=true; shift ;;
    --dry-run) apply=false; shift ;;
    --bytes) bytes=true; shift ;;
    --include-unowned) include_unowned=true; shift ;;
    --accept-ignored) accept_ignored=true; shift ;;
    --board) [[ $# -ge 2 ]] || { echo "❌ --board needs a value" >&2; exit 2; }; board="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "❌ Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

command -v "$hermes_bin" >/dev/null 2>&1 || {
  echo "❌ '$hermes_bin' not found; set HERMES_BIN to the hermes executable." >&2
  exit 1
}
command -v jq >/dev/null 2>&1 || { echo "❌ jq is required." >&2; exit 1; }

[[ -d "$worktrees_dir" ]] || { echo "ℹ️  No .worktrees directory at $worktrees_dir; nothing to do."; exit 0; }

# One reaper at a time. Concurrent runs double-attempt the same removal (git
# re-verifies, so it is safe but noisy), and the du walk in --bytes mode is
# expensive enough that overlapping runs are a real waste. A held lock skips
# this run entirely rather than queueing behind the running one.
# Resolve against the target repository, never the caller's cwd. Linked
# checkouts also share this lock through their common Git directory.
if ! git_dir="$(git -C "$repo_root" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"; then
  echo "❌ $repo_root is not a readable git checkout; refusing to continue." >&2
  exit 1
fi
exec 9>"$git_dir/reap-kanban-worktrees.lock" || {
  echo "❌ Cannot lock $git_dir/reap-kanban-worktrees.lock; refusing to continue." >&2
  exit 1
}
if ! flock -n 9; then
  echo "ℹ️  Another reap run holds the lock; skipping."
  exit 0
fi

board_args=()
[[ -n "$board" ]] && board_args=(--board "$board")

# Path -> card attribution. `owned` is every card that names the path;
# `active` is the subset that is not terminal. Active always wins, so a path
# shared by a finished and an open card is never reaped.
declare -A card_owned=() card_active=()
board_count=0

load_board() { # <board-json>; returns non-zero when the shape is unusable
  local json="$1" rows status raw key
  # A schema change must not silently turn every tree into an unowned one.
  jq -e 'type == "array"
         and all(.[]; type == "object")
         and all(.[]; (.status | type) == "string")
         and all(.[]; (.workspace_path == null) or ((.workspace_path | type) == "string"))' \
    >/dev/null 2>&1 <<<"$json" || return 1
  rows="$(jq -r '.[] | [(.status // ""), (.workspace_path // "")] | @tsv' <<<"$json")" || return 1
  card_owned=()
  card_active=()
  while IFS=$'\t' read -r status raw; do
    [[ -n "$raw" ]] || continue
    # Relative card paths are relative to the repository, never the caller's cwd.
    [[ "$raw" == /* ]] || raw="$repo_root/$raw"
    key="$(realpath -m -- "$raw")" || continue
    [[ -n "$key" ]] || continue
    card_owned["$key"]=1
    if ! is_terminal "$status"; then
      card_active["$key"]=1
    fi
  done <<<"$rows"
  board_count="$(jq -r 'length' <<<"$json")" || return 1
}

read_board() {
  local out
  out="$("$hermes_bin" kanban "${board_args[@]}" list --json --archived 2>/dev/null)" || return 1
  load_board "$out" || return 1
}

# Open-card citation guard. A finished producer card's workspace can still be
# load-bearing evidence for a decision, review or audit card that cites its
# path or workspace ID, and losing it mid-decision triggers the fail-closed
# deploy gate, which then demands a provenance investigation (the 2026-10
# deploy d52f1cf..aedbce9 saga). Scan every board's open cards — title, body,
# comments and attachment names — and keep any tree they mention.
load_citations() { # sets citation_blob; nonzero when the data is unusable
  local root="${HERMES_ROOT:-$HOME/.hermes}"
  citation_blob="$(python3 - "$root" <<'PY'
import sqlite3
import sys
from contextlib import closing
from pathlib import Path

BOARD_ROOT = Path(sys.argv[1]) / 'kanban' / 'boards'
OPEN = "('done', 'archived', 'failed', 'cancelled')"

try:
    if not BOARD_ROOT.is_dir():
        sys.exit(3)
    for db_path in sorted(BOARD_ROOT.glob('*/kanban.db')):
        # Archived board copies cannot hold open cards, and their legacy
        # schemas are not worth keeping current; only active boards count.
        if db_path.parent.name.startswith('_archived'):
            continue
        board = db_path.parent.name
        with closing(sqlite3.connect(db_path.as_uri() + '?mode=ro', uri=True, timeout=5)) as db:
            db.row_factory = sqlite3.Row
            db.execute('PRAGMA query_only=ON')
            cards = db.execute(
                'SELECT id, title, body FROM tasks'
                f' WHERE status NOT IN {OPEN}').fetchall()
            for card in cards:
                parts = [card['title'] or '', card['body'] or '']
                for row in db.execute(
                        'SELECT body FROM task_comments WHERE task_id=?',
                        (card['id'],)):
                    parts.append(row['body'] or '')
                if db.execute("SELECT 1 FROM sqlite_master WHERE name='task_events'").fetchone():
                    for row in db.execute(
                            "SELECT payload FROM task_events WHERE task_id=? AND kind='task_record'",
                            (card['id'],)):
                        parts.append(row['payload'] or '')
                for row in db.execute(
                        'SELECT filename, stored_path FROM task_attachments'
                        ' WHERE task_id=?', (card['id'],)):
                    parts.append(row['filename'] or '')
                    parts.append(row['stored_path'] or '')
                text = ' '.join(parts).replace('\n', ' ').strip()
                if text:
                    print(f"{board}/{card['id']}\t{text}")
except (sqlite3.Error, OSError) as exc:
    print(f'citation scan failed: {exc}', file=sys.stderr)
    sys.exit(2)
PY
)" || return 1
}

# Print the citing card label when a tree is cited by an open card; the blob is
# line-oriented: "<board>/<card id>\t<searchable text>".
first_citation() { # <path> -> label via stdout; return 1 when uncited
  local needle="$1" base="${1##*/}" hit
  hit="$(awk -v a="$needle" -v b="$base" '
      index($0, a) || index($0, b) { print $1; exit }' <<<"${citation_blob:-}")"
  [[ -n "$hit" ]] || return 1
  printf '%s' "$hit"
}

if ! read_board; then
  echo "❌ Could not read a valid board through '$hermes_bin kanban list --json --archived'." >&2
  echo "   Expected a JSON array of cards with string 'status' and optional 'workspace_path'." >&2
  echo "   Nothing was removed." >&2
  exit 1
fi

reap=0 reap_bytes=0 keep=0 keep_bytes=0 unowned=0 unowned_bytes=0
dirty=0 dirty_bytes=0 unpublished=0 unpublished_bytes=0
ignored=0 ignored_bytes=0 unknown=0 stale=0
reap_paths=()
registered=()

human() { awk -v b="$1" 'BEGIN{printf "%.1f GiB", b/1024/1024/1024}'; }
# Byte suffixes only in --bytes mode: the du walk over every tree is the
# expensive part of a dry run, and the steward scan wants the cheap counts.
sum() { # <bytes> -> " (X GiB)" or ""
  if [[ "$bytes" == true ]]; then
    printf ' (%s)' "$(human "$1")"
  fi
}

if ! worktree_list="$(git -C "$repo_root" worktree list --porcelain 2>/dev/null)"; then
  echo "❌ 'git worktree list' failed in $repo_root; nothing was removed." >&2
  exit 1
fi

while IFS= read -r line; do
  [[ "$line" == "worktree "* ]] || continue
  path="${line#worktree }"
  rpath="$(realpath -m -- "$path")"
  # Only ever touch trees inside this repo's .worktrees directory. Compare
  # resolved paths so a symlinked .worktrees still matches, and so a tree that
  # merely shares the prefix (e.g. .worktrees-archive) never does.
  # Also track registered trees for the stray-directory report below.
  case "$rpath" in
    "$worktrees_real"/*) registered+=("$rpath") ;;
    *) continue ;;
  esac

  if [[ ! -d "$path" ]]; then
    stale=$((stale+1))
    echo "  stale (directory missing): ${path#"$repo_root"/}"
    continue
  fi

  bytes_now=0
  if [[ "$bytes" == true ]]; then
    bytes_now="$(du -sb "$path" 2>/dev/null | cut -f1)"; bytes_now="${bytes_now:-0}"
  fi

  if [[ -n "${card_active[$rpath]:-}" ]]; then
    keep=$((keep+1)); keep_bytes=$((keep_bytes+bytes_now))
    continue
  fi

  if [[ -z "${card_owned[$rpath]:-}" ]] && [[ "$include_unowned" != true ]]; then
    unowned=$((unowned+1)); unowned_bytes=$((unowned_bytes+bytes_now))
    echo "  preserve (no owning card): ${path#"$repo_root"/}"
    continue
  fi

  # Clean working tree? Untracked-only scratch counts as dirty, as in hermes.
  # A failing git status is its own preserve reason: classifying a broken
  # worktree as clean would reap on a false negative.
  if ! status_out="$(git --no-optional-locks -C "$path" status --porcelain 2>/dev/null)"; then
    unknown=$((unknown+1))
    echo "  preserve (git status failed): ${path#"$repo_root"/}"
    continue
  fi
  if [[ -n "$status_out" ]]; then
    dirty=$((dirty+1)); dirty_bytes=$((dirty_bytes+bytes_now))
    echo "  preserve (uncommitted changes): ${path#"$repo_root"/}"
    continue
  fi

  # `git status` treats ignored files as absent, but `git worktree remove`
  # deletes them. Keep a tree that holds ignored content git cannot reproduce,
  # and only reap when all of it is scratch or build output.
  if [[ "$accept_ignored" != true ]]; then
    if ! ignored_out="$(git --no-optional-locks -C "$path" status --porcelain \
        --ignored=matching --untracked-files=normal 2>/dev/null)"; then
      unknown=$((unknown+1))
      echo "  preserve (git status failed): ${path#"$repo_root"/}"
      continue
    fi
    kept_ignored=()
    while IFS= read -r entry; do
      [[ "$entry" == '!! '* ]] || continue
      entry="${entry#!! }"
      ignored_disposable "$entry" || kept_ignored+=("$entry")
    done <<<"$ignored_out"
    if ((${#kept_ignored[@]} > 0)); then
      ignored=$((ignored+1)); ignored_bytes=$((ignored_bytes+bytes_now))
      echo "  preserve (ignored content): ${path#"$repo_root"/} [${kept_ignored[*]}]"
      continue
    fi
  fi

  head="$(git -C "$path" rev-parse HEAD 2>/dev/null || true)"
  if [[ -z "$head" ]] || [[ -z "$(git -C "$repo_root" branch -r --contains "$head" 2>/dev/null)" ]]; then
    unpublished=$((unpublished+1)); unpublished_bytes=$((unpublished_bytes+bytes_now))
    echo "  preserve (unpublished commits): ${path#"$repo_root"/}"
    continue
  fi

  reap=$((reap+1)); reap_bytes=$((reap_bytes+bytes_now))
  reap_paths+=("$path")
done <<<"$worktree_list"

# Citation guard pass: partition the otherwise-reapable trees against open
# cards on every board. Fail closed when the citation data is unusable — an
# unreadable intersection means the run tells nothing about what is safe.
cited=0
if ((${#reap_paths[@]} > 0)); then
  citation_blob=""
  if ! load_citations; then
    echo "❌ Could not read open-card citations under ${HERMES_ROOT:-$HOME/.hermes}/kanban/boards;" >&2
    echo "   a tree cited by an open card could not be distinguished. Nothing was removed." >&2
    exit 1
  fi
  keep_paths=()
  for path in "${reap_paths[@]}"; do
    if cited_label="$(first_citation "$path")"; then
      cited=$((cited+1))
      echo "  preserve (cited by open card $cited_label): ${path#"$repo_root"/}"
    else
      keep_paths+=("$path")
    fi
  done
  reap=$((reap - cited))
  reap_paths=("${keep_paths[@]}")
fi

# Directories under .worktrees/ that git does not track as worktrees and that
# do not contain one. They are never deleted (a full manual clone or a pruned
# worktree's leftovers look the same), but they must not pile up unseen.
stray=0
while IFS= read -r dir; do
  dir_real="$(realpath -m -- "$dir")"
  is_registered=0
  for reg in "${registered[@]}"; do
    if [[ "$reg" == "$dir_real" || "$reg" == "$dir_real"/* ]]; then
      is_registered=1
      break
    fi
  done
  ((is_registered == 0)) || continue
  stray=$((stray+1))
  echo "  stray (not a registered worktree): ${dir#"$repo_root"/}"
done < <(find "$worktrees_real" -mindepth 1 -maxdepth 1 \( -type d -o -type l \) -print 2>/dev/null)

printf '%-44s %d%s\n' 'Reapable (terminal card, clean, published):' "$reap" "$(sum "$reap_bytes")"
printf '%-44s %d%s\n' 'Preserve (unowned tree):' "$unowned" "$(sum "$unowned_bytes")"
printf '%-44s %d%s\n' 'Preserve (uncommitted changes):' "$dirty" "$(sum "$dirty_bytes")"
printf '%-44s %d%s\n' 'Preserve (ignored content):' "$ignored" "$(sum "$ignored_bytes")"
printf '%-44s %d%s\n' 'Preserve (unpublished commits):' "$unpublished" "$(sum "$unpublished_bytes")"
printf '%-44s %d\n' 'Preserve (git status failed):' "$unknown"
printf '%-44s %d\n' 'Preserve (cited by open card):' "$cited"
printf '%-44s %d%s\n' 'Preserve (active card):' "$keep" "$(sum "$keep_bytes")"
printf '%-44s %d\n' 'Stale admin entry (directory missing):' "$stale"
printf '%-44s %d\n' 'Stray directory (unregistered):' "$stray"

if ((unowned > 0)) && [[ "$include_unowned" != true ]]; then
  echo "ℹ️  Unowned trees are preserved; review them, then re-run with --include-unowned to reap the safe ones."
fi
if ((ignored > 0)) && [[ "$accept_ignored" != true ]]; then
  echo "ℹ️  Trees with non-disposable ignored content are preserved; move that content or re-run with --accept-ignored."
fi
if ((stale > 0 || stray > 0)); then
  echo "ℹ️  Stale admin entries are pruned by --apply; stray directories need manual review."
fi

if [[ "$apply" != true ]]; then
  for path in "${reap_paths[@]}"; do
    echo "  reapable (dry run would remove): ${path#"$repo_root"/}"
  done
  echo "ℹ️  Dry run. Re-run with --apply to remove the ${reap} reapable tree(s)."
  exit 0
fi

# Re-read the board after classification. A card may have been created or
# reopened in a tree while the (slow) git checks ran, and `git worktree remove`
# only re-verifies cleanliness, not ownership.
if ! read_board; then
  echo "❌ Board re-read failed; refusing to remove anything." >&2
  exit 1
fi
if ((board_count == 0)); then
  echo "❌ The board returned no cards, so tree ownership cannot be verified." >&2
  echo "   Refusing to remove anything; check --board and the board database." >&2
  exit 1
fi

# Re-read citations after classification: a card may have started citing a
# tree while the git checks ran, exactly like the ownership re-read above.
became_cited=0
if ((${#reap_paths[@]} > 0)); then
  if ! load_citations; then
    echo "❌ Citation re-read failed; refusing to remove anything." >&2
    exit 1
  fi
  keep_paths=()
  for path in "${reap_paths[@]}"; do
    if cited_label="$(first_citation "$path")"; then
      became_cited=$((became_cited+1))
      echo "  keep (card cites tree): ${path#"$repo_root"/} ($cited_label)"
    else
      keep_paths+=("$path")
    fi
  done
  reap_paths=("${keep_paths[@]}")
fi

removed=0 failed=0 became_active=0
for path in "${reap_paths[@]}"; do
  rpath="$(realpath -m -- "$path")"
  if [[ -n "${card_active[$rpath]:-}" ]]; then
    became_active=$((became_active+1))
    echo "  keep (card became active): ${path#"$repo_root"/}"
    continue
  fi
  # No --force: git re-verifies the dirty guard at removal time (fail safe).
  if git -C "$repo_root" worktree remove "$path" 2>/dev/null; then
    removed=$((removed+1))
  else
    failed=$((failed+1))
    echo "⚠️  git worktree remove failed (kept): ${path#"$repo_root"/}" >&2
  fi
done

# Drop admin entries whose directories are already gone; metadata only.
prune_failed=0
if ! git -C "$repo_root" worktree prune 2>/dev/null; then
  prune_failed=1
  echo "⚠️  'git worktree prune' failed; stale admin entries remain." >&2
fi

echo "✅ Removed ${removed} worktree(s); local wt/* branches were kept."
if ((became_active > 0)); then
  echo "ℹ️  Kept ${became_active} tree(s) whose card became active during the run."
fi
if ((became_cited > 0)); then
  echo "ℹ️  Kept ${became_cited} tree(s) that an open card cited during the run."
fi
if ((failed > 0)); then
  echo "❌ ${failed} tree(s) could not be removed and remain on disk; inspect the warnings above." >&2
fi
((failed == 0 && prune_failed == 0))
