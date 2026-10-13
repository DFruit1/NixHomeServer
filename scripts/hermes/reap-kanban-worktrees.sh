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
#   * its task (matched by workspace_path) is not on a non-terminal card, so a
#     todo/ready/running/review/blocked/scheduled/triage card keeps its tree;
#   * the working tree is clean (tracked and untracked — untouched scratch is
#     preserved, matching hermes);
#   * every commit is reachable from a remote-tracking ref (fully published).
# Local `wt/<id>` branches are kept; only the worktree directory is reclaimed.
# The default action is a dry run; pass --apply to remove.
#
# Board state is read through `hermes kanban list --json` so this never depends
# on the board DB schema. The current board is used unless --board is given.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
worktrees_dir="$repo_root/.worktrees"

apply=false
board=""
hermes_bin="${HERMES_BIN:-hermes}"

usage() {
  cat <<'EOF'
Usage: scripts/hermes/reap-kanban-worktrees.sh [--apply] [--board <slug>]

Classify and reclaim stale kanban worktrees under .worktrees/.

  --apply          Remove the trees classified reap; default is a dry run.
  --board <slug>   Read card state from this board (default: current board).
  -h, --help       Show this help.

A tree is reapable only when its card is terminal, the tree is clean, and every
commit is reachable from a remote-tracking ref. Everything else is preserved and
reported with its reason.
EOF
}

while (($# > 0)); do
  case "$1" in
    --apply) apply=true; shift ;;
    --dry-run) apply=false; shift ;;
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

board_args=()
[[ -n "$board" ]] && board_args=(--board "$board")

# Statuses after which a card no longer needs its workspace.
board_json="$("$hermes_bin" kanban "${board_args[@]}" list --json 2>/dev/null)" || {
  echo "❌ Could not read the board through '$hermes_bin kanban list --json'." >&2
  exit 1
}
active_paths="$(jq -r '.[] | select(.status | IN("done","archived","failed","cancelled") | not) | .workspace_path // empty' <<<"$board_json")"

# Path identity: resolve symlinks so a card path and a worktree list entry agree.
declare -A active=()
while IFS= read -r p; do
  [[ -n "$p" ]] || continue
  active["$(realpath -m "$p")"]=1
done <<<"$active_paths"

reap=0 reap_bytes=0 keep=0 keep_bytes=0 dirty=0 dirty_bytes=0 unpublished=0 unpublished_bytes=0
reap_paths=()

human() { awk -v b="$1" 'BEGIN{printf "%.1f GiB", b/1024/1024/1024}'; }

while IFS= read -r line; do
  path="${line#worktree }"
  # Only ever touch trees inside this repo's .worktrees directory.
  case "$path" in
    "$worktrees_dir"/*) ;;
    *) continue ;;
  esac
  [[ -d "$path" ]] || continue

  rpath="$(realpath -m "$path")"
  bytes="$(du -sb "$path" 2>/dev/null | cut -f1)"; bytes="${bytes:-0}"

  if [[ -n "${active[$rpath]:-}" ]]; then
    keep=$((keep+1)); keep_bytes=$((keep_bytes+bytes))
    continue
  fi

  # Clean working tree? Untracked-only scratch counts as dirty, as in hermes.
  if [[ -n "$(git -C "$path" status --porcelain 2>/dev/null | head -c1)" ]]; then
    dirty=$((dirty+1)); dirty_bytes=$((dirty_bytes+bytes))
    echo "  preserve (uncommitted changes): ${path#"$repo_root"/}"
    continue
  fi

  head="$(git -C "$path" rev-parse HEAD 2>/dev/null || true)"
  if [[ -z "$head" ]] || [[ -z "$(git -C "$repo_root" branch -r --contains "$head" 2>/dev/null)" ]]; then
    unpublished=$((unpublished+1)); unpublished_bytes=$((unpublished_bytes+bytes))
    echo "  preserve (unpublished commits): ${path#"$repo_root"/}"
    continue
  fi

  reap=$((reap+1)); reap_bytes=$((reap_bytes+bytes))
  reap_paths+=("$path")
done < <(git -C "$repo_root" worktree list --porcelain)

echo "Reapable (terminal card, clean, published): ${reap} ($(human "$reap_bytes"))"
echo "Preserve (uncommitted changes):             ${dirty} ($(human "$dirty_bytes"))"
echo "Preserve (unpublished commits):             ${unpublished} ($(human "$unpublished_bytes"))"
echo "Preserve (active card):                     ${keep} ($(human "$keep_bytes"))"

if [[ "$apply" != true ]]; then
  echo "ℹ️  Dry run. Re-run with --apply to remove the ${reap} reapable tree(s)."
  exit 0
fi

removed=0
for path in "${reap_paths[@]}"; do
  # No --force: git re-verifies the dirty guard at removal time (fail safe).
  if git -C "$repo_root" worktree remove "$path" 2>/dev/null; then
    removed=$((removed+1))
  else
    echo "⚠️  git worktree remove failed (kept): ${path#"$repo_root"/}" >&2
  fi
done

# Drop admin entries whose directories are already gone; metadata only.
git -C "$repo_root" worktree prune

echo "✅ Removed ${removed} worktree(s); local wt/* branches were kept."
