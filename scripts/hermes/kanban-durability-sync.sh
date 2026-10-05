#!/usr/bin/env bash
# Push agent work off this machine and mirror the kanban boards to the server.
#
# Why
# ---
# The hermes board and the per-card worktrees are the only place two kinds of
# work exist. Neither is on the server, and neither is in the repository:
#
#   * Worktree branches hold the only copy of their commits until pushed. A
#     normal `git push` is the operator's job, and agents commit to their own
#     branch and stop. So "done" cards can sit on a branch that exists only in
#     this clone. That is exactly how four deploy-path cards ended up complete
#     on the board and absent from `master`.
#
#   * The board itself (kanban.db) is the sole record of every card, comment,
#     audit report, dependency edge and review verdict. Two of the three audits
#     from the current sweep exist *only* as rows in that database -- there is
#     no report file. Kopia snapshots the server's /persist, and this clone is
#     not on the server, so a disk failure loses the entire history of the
#     work, not just the code.
#
# So this does two things on a timer:
#
#   1. Push every local branch that has commits no remote ref holds, plus
#      `master` when it is ahead of `origin/master`.
#   2. Copy a consistent snapshot of every board to the server's /persist, which
#      Kopia already snapshots. Restoring is then a kopia restore plus a file
#      copy, with no dependency on this machine being bootable.
#
# Every board, not one
# --------------------
# This used to mirror a single board, defaulting to `nixhomeserver`. There is a
# second live board here -- `pcops`, with its own cards, comments and audit rows
# -- and it was not mirrored at all. That is precisely the single-copy loss this
# script exists to prevent: the one board it happened to pick up was safe, and
# every other board was one disk failure from gone. So the default is now every
# board found under the hermes boards directory, and HERMES_BOARD narrows a run
# to one board for an operator who wants that.
#
# Each board gets its own subtree on the server, `$DURABILITY_REMOTE_DIR/<board>/`,
# so mirroring a second board cannot overwrite the first one's copy.
#
# Safety
# ------
# Push only, never force, never delete, never rebase. Branches are pushed to
# their same-named remote ref, so a branch that is already on the remote is a
# no-op and a branch that is ahead is fast-forwarded. `--force-with-lease` is
# deliberately not used: if a remote ref moved in a way that would require
# history rewriting, the push fails and the operator decides.
#
# The board snapshot uses SQLite's online backup API rather than `cp`. The
# gateway holds the database open in WAL mode, so a plain file copy can capture
# a torn main file that omits committed transactions still sitting in the -wal
# sidecar. `.backup` takes a transactionally consistent copy of a live database.
#
# More than one generation is kept
# --------------------------------
# The mirror used to hold exactly one generation and unconditionally `rm -rf` the
# previous one before installing the new copy. So a truncated database, or a run
# that failed midway, replaced the only healthy copy and left nothing to restore
# from -- a backup that destroys itself when it is needed is the worst outcome
# available. There are now `current` plus `DURABILITY_GENERATIONS-1` older
# generations, chosen by modification time so the newest healthy ones survive
# pruning, and pruning happens only after the incoming snapshot has been received,
# unpacked and verified.
#
# Only the board is mirrored, not all of ~/.hermes: that tree is 5.1 GB of
# virtualenvs, model weights and tool installs, all of which reinstall from
# their own sources. The irreplaceable part is a few megabytes.
#
# Loud failure, always
# --------------------
# Every one of these used to log a sentence and exit 0: no board found, no
# durability target resolvable, a failed sqlite backup, a failed integrity check,
# a failed upload. A cron job that reports success while holding the only copy of
# the work history is worse than one that reports failure, because it is not
# looked at. Failures are counted and the script exits non-zero; the mirror is
# still attempted after a branch-push problem, because the data is what matters.
#
# Usage
# -----
#   scripts/hermes/kanban-durability-sync.sh            # push + mirror
#   scripts/hermes/kanban-durability-sync.sh --check    # report only, push nothing
#
# Environment
# -----------
#   HERMES_ROOT          hermes state dir  (default: ~/.hermes)
#   HERMES_BOARD         mirror only this board       (default: every board found)
#   DURABILITY_TARGET    user@host         (default: auto-resolved from vars.nix)
#   DURABILITY_REMOTE_DIR remote dir under /persist (default:
#                        /persist/home/dsaw/.hermes-durability)
#   DURABILITY_GENERATIONS  snapshots kept per board, current included
#                        (default: 3)
#
# The default sits under /persist because that is the only root Kopia snapshots
# (repo.backups.snapshotRoots = [ "/persist" ]), so the mirror inherits the
# server's existing encrypted, off-site backup schedule with no new machinery.
# It is the user's own subdirectory rather than /persist itself because
# /persist is root-owned; using sudo from a cron tick would add a privileged
# path to a job that runs unattended.

set -euo pipefail

HERMES_ROOT="${HERMES_ROOT:-$HOME/.hermes}"
BOARDS_DIR="$HERMES_ROOT/kanban/boards"
REMOTE_DIR="${DURABILITY_REMOTE_DIR:-/persist/home/dsaw/.hermes-durability}"
GENERATIONS="${DURABILITY_GENERATIONS:-3}"

check_only=false
[[ "${1:-}" == "--check" ]] && check_only=true

failures=0
log() { printf 'durability: %s\n' "$*" >&2; }

# A step that failed. Keeps going wherever later work still protects data, and
# makes the job's exit status disagree with a success that never happened.
fail() {
  failures=$((failures + 1))
  log "FAILED: $*"
}

# The retention depth decides how much is deleted on the server, so it is held to
# the same rule as every other knob in this repo's cron scripts: a positive
# integer, or the job refuses to start rather than prune at a nonsense depth.
[[ "$GENERATIONS" =~ ^[1-9][0-9]*$ ]] || {
  log "DURABILITY_GENERATIONS must be a positive integer, got '$GENERATIONS'"
  exit 2
}

# Board slugs to mirror, name order for a stable job log. `_archived` and
# anything else prefixed with an underscore is hermes's own bookkeeping, not a
# board. HERMES_BOARD, when set, is a filter rather than a default: it is the
# single-board mode an operator asks for explicitly, and the only way to name a
# board this scan cannot see.
boards=()
if [[ -n "${HERMES_BOARD:-}" ]]; then
  boards=("$HERMES_BOARD")
else
  for board_dir in "$BOARDS_DIR"/*/; do
    [[ -d "$board_dir" ]] || continue
    slug="${board_dir%/}"
    slug="${slug##*/}"
    [[ "$slug" == _* ]] && continue
    boards+=("$slug")
  done
fi

if ((${#boards[@]} == 0)); then
  fail "no boards found under $BOARDS_DIR; nothing was mirrored"
  exit "$failures"
fi

# This script's own directory. The board push resolves each board's checkout from
# its board.json, but the Nix target fallback below needs the repository's shared
# helper library, and an installed copy under ~/.hermes/scripts does not sit
# beside it.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# 1. Push branches that exist nowhere else
# ---------------------------------------------------------------------------

# Target resolution, cheapest first. This runs every few minutes unattended, so
# it must not start a Nix evaluation to read two variables: nix_flake_json
# instantiates the module system locally, which on this workstation is the
# multi-second, 4-core path that helpers/remote-eval.sh exists to avoid. The
# Nix path stays as the authoritative fallback for when the cheap probe fails.
resolve_target() {
  if [[ -n "${DURABILITY_TARGET:-}" ]]; then
    printf '%s\n' "$DURABILITY_TARGET"
    return 0
  fi

  # `server` is a stable name for the NixHomeServer box (LAN DNS / /etc/hosts),
  # and already used by the qwen tunnel and the agent tunnel autostart.
  if getent hosts server >/dev/null 2>&1 &&
     timeout 10 ssh -o BatchMode=yes -o ConnectTimeout=5 server true 2>/dev/null; then
    printf '%s\n' "server"
    return 0
  fi

  # nix_flake_json lives in scripts/helpers/repo-common.sh. This script used to
  # call it as a fallback without ever sourcing that helper, so every run that
  # actually needed the fallback got `command not found` -- indistinguishable, in
  # the log, from an unreachable server. Source the helper when it is alongside
  # this script (running from the checkout) and only use the fallback when the
  # function really exists.
  local helper="$SCRIPT_DIR/../helpers/repo-common.sh"
  if [[ -r "$helper" ]]; then
    # shellcheck source=scripts/helpers/repo-common.sh
    source "$helper"
  fi
  if ! declare -F nix_flake_json >/dev/null; then
    log "no durability target: set DURABILITY_TARGET, or run this script from the checkout so the vars.nix fallback is available"
    return 1
  fi

  local config
  config="$(nix_flake_json '{
    localAdminUser = if vars ? localAdminUser then vars.localAdminUser else vars.identity.localAdminUser;
    serverLanIP = vars.serverLanIP;
  }')" || return 1
  jq -er '"\(.localAdminUser)@\(.serverLanIP)"' <<<"$config"
}

# Which checkout holds a board's work. board.json's default_workdir is the same
# source kanban-board-health.sh reads for its UNPUSHED findings, and using the
# same one matters: this script used to look at $PWD, so a tick that started
# anywhere but the checkout found nothing, logged "no git checkout found", and
# exited 0 -- a silent false negative on the one job whose entire purpose is to
# stop unpushed commits being lost. $PWD is now only the fallback.
board_workdir() {
  local board_json="$BOARDS_DIR/$1/board.json" workdir=""
  if [[ -r "$board_json" ]]; then
    workdir="$(python3 - "$board_json" <<'PY' 2>/dev/null || true
import json, sys
try:
    with open(sys.argv[1]) as fh:
        print(json.load(fh).get("default_workdir") or "")
except Exception:
    print("")
PY
)"
  fi
  if [[ -n "$workdir" ]] && git -C "$workdir" rev-parse --git-dir >/dev/null 2>&1; then
    (cd "$workdir" && pwd -P)
    return 0
  fi
  if git -C "$PWD" rev-parse --git-dir >/dev/null 2>&1; then
    (cd "$PWD" && pwd -P)
    return 0
  fi
  return 1
}

# Branches held only by this clone, pushed fast-forward only.
push_branches() {
  local work_repo="$1" pushed=0 refname sha ahead

  # Bounded fetch so an unreachable remote cannot stall the mirror.
  timeout 60 git -C "$work_repo" fetch --quiet origin 2>/dev/null || \
    log "fetch failed; comparing against last known remote refs"

  while read -r refname sha; do
    [[ -n "$refname" ]] || continue
    ahead="$(git -C "$work_repo" rev-list --count "$sha" --not --remotes 2>/dev/null || printf '?')"
    [[ "$ahead" =~ ^[0-9]+$ ]] || { log "cannot count commits on $refname; skipping"; continue; }
    ((ahead > 0)) || continue
    if git -C "$work_repo" push --quiet origin "$sha:refs/heads/$refname" 2>/dev/null; then
      log "pushed $refname ($ahead commit(s))"
      pushed=$((pushed + 1))
    else
      # Counted, not merely logged. A rejected push means commits this clone is
      # the only holder of were not written anywhere, which is the whole reason
      # this job exists; reporting success for it is the same silent false
      # negative as the other failure paths above. The mirror still runs, so the
      # board data is protected either way.
      fail "push FAILED for $refname; $ahead commit(s) exist only in this clone"
    fi
  done < <(git -C "$work_repo" for-each-ref \
             --format='%(refname:short) %(objectname)' \
             refs/heads/wt refs/heads/master 2>/dev/null | sort)

  # master needs its own check. The loop above compares every branch against all
  # remote refs, so a commit that also happens to live on some origin/wt/* branch
  # counts as safe and is skipped -- correct for "would a disk failure lose
  # this", but wrong for the integration branch, which a fresh clone pulls and
  # which no other ref guarantees to keep. So push master to origin/master
  # explicitly, fast-forward only.
  if git -C "$work_repo" rev-parse --verify --quiet master >/dev/null 2>&1 &&
     git -C "$work_repo" rev-parse --verify --quiet origin/master >/dev/null 2>&1; then
    if ! git -C "$work_repo" merge-base --is-ancestor origin/master master 2>/dev/null; then
      log "master has diverged from origin/master; not pushing, operator must reconcile"
    elif [[ "$(git -C "$work_repo" rev-list --count origin/master..master 2>/dev/null || echo 0)" != 0 ]]; then
      ahead="$(git -C "$work_repo" rev-list --count origin/master..master)"
      if git -C "$work_repo" push --quiet origin master:master 2>/dev/null; then
        log "pushed master ($ahead commit(s) ahead of origin/master)"
        pushed=$((pushed + 1))
      else
        fail "push FAILED for master; $ahead commit(s) ahead of origin/master exist only in this clone"
      fi
    fi
  fi
  log "branch push complete for $work_repo ($pushed pushed)"
}

declare -A board_repo=()
seen_repos=()
for board in "${boards[@]}"; do
  if ! work_repo="$(board_workdir "$board")"; then
    # A board whose workdir is not a checkout has no commits to lose from here.
    # Not fatal on its own -- it is expected for a board that drives work
    # somewhere else -- but it is reported every tick, because it is also the
    # shape a misconfigured workdir takes.
    log "board $board: workdir is not a git checkout; no branches to push for it"
    continue
  fi
  board_repo["$board"]="$work_repo"

  # One push pass per distinct checkout: two boards sharing a repo must not push
  # it twice on every tick.
  already=false
  for seen_repo in ${seen_repos[@]+"${seen_repos[@]}"}; do
    [[ "$seen_repo" == "$work_repo" ]] && already=true
  done
  [[ "$already" == true ]] && continue
  seen_repos+=("$work_repo")

  if [[ "$check_only" == true ]]; then
    log "check-only: would push from $work_repo (board $board)"
  else
    push_branches "$work_repo"
  fi
done

if ((${#seen_repos[@]} == 0)); then
  # Nothing was pushed and nothing could be. This used to be a log line and exit
  # 0, which is indistinguishable from a tick where every branch was already safe.
  fail "no board resolved to a git checkout; no branch could be pushed"
fi

# ---------------------------------------------------------------------------
# 2. Mirror the boards to Kopia-covered storage on the server
# ---------------------------------------------------------------------------

if ! target="$(resolve_target)"; then
  fail "could not resolve a durability target; no board was mirrored"
  exit "$failures"
fi

# Card text and audit records are private, and `mktemp -d` creates the directory
# with whatever umask the cron session happens to carry. Set the umask first so
# the snapshot directory and the board copy inside it are never briefly readable
# by another user on this workstation.
umask 077

snapshot_root="$(mktemp -d)"
trap 'rm -rf "$snapshot_root"' EXIT

# Generation rotation, written as a remote script rather than a wall of escaped
# quotes inside an ssh argument. It travels base64-encoded because the tar stream
# already occupies ssh's stdin, so the script cannot be piped there, and because
# the two values it needs then need no quoting of their own.
#
# `remotedir` and `keep` are prepended to the body rather than passed as
# arguments: ssh concatenates its arguments into one command string, so anything
# with a space or a quote in it has to be escaped, and printf '%q' does that once
# here instead of at every use site.
remote_rotation_body="$(cat <<'REMOTE'
set -eu

mkdir -p "$remotedir"
incoming="$(mktemp -d "$remotedir/.incoming.XXXXXX")"
trap 'rm -rf "$incoming"' EXIT
# The workstation and the server clocks differ by a fraction of a second, which
# makes tar warn about future timestamps on every file. The warning is noise on
# an unattended job and hides real failures.
tar -xzf - -C "$incoming" --warning=no-timestamp

# Inventory the generations already on disk, newest first. Two orderings, because
# one of them is not always available: the modification time, at nanosecond
# precision when stat supports it, and the slot the generation already occupies.
# The tie-break is not decoration -- two mirrors inside one second is exactly
# what a retry after a failed run looks like, and slot order is the only thing
# that still says which copy is newer: slot 0 is `current`, slot 1 `previous`,
# slot N `previous.N`, so ascending slot is newest first. An ascending-slot
# tie-break on an ascending-mtime list is also what made retention pick the wrong
# copies: with tied mtimes the list ended up oldest-in-slot-order and `tail`
# then deleted the *newest* predecessor, which is the copy most wanted.
inventory="$incoming/.generations"
: >"$inventory"
for dir in "$remotedir"/current "$remotedir"/previous "$remotedir"/previous.*; do
  [ -d "$dir" ] || continue
  mtime="$(stat -c '%.9Y' "$dir" 2>/dev/null || echo 0)"
  case "${dir##*/}" in
    current) slot=0 ;;
    previous) slot=1 ;;
    previous.*) slot="${dir##*/previous.}" ;;
    *) continue ;;
  esac
  case "$slot" in
    ''|*[!0-9]*) continue ;;
  esac
  printf '%s %s %s\n' "$mtime" "$slot" "$dir" >>"$inventory"
done
# `-k1,1nr` reverses the mtime key alone. A global `-r` would reverse the slot
# key as well and reintroduce the oldest-first order this list must not have.
sort -k1,1nr -k2,2n "$inventory" >"$inventory.sorted"

# `current` is always replaced by the incoming copy, so the slots behind it
# compete for the generations that are not it. The list is newest-first, so the
# survivors are the *first* `survivors` entries and the deletion pass at the end
# only sees what fell off the end.
survivors=$((keep - 2))
[ "$survivors" -lt 0 ] && survivors=0
awk -v cur="$remotedir/current" '$3 != cur' "$inventory.sorted" >"$inventory.older"
head -n "$survivors" "$inventory.older" >"$inventory.keep"

# Stage the survivors under names that cannot collide with the slot they are
# about to occupy. Renaming straight into place would let `previous.3` overwrite
# the `previous.2` still waiting to be read.
stage="$incoming/.staged"
mkdir -p "$stage"
slot=2
while read -r _ _ dir; do
  [ -n "$dir" ] || continue
  mv "$dir" "$stage/gen.$slot"
  slot=$((slot + 1))
done <"$inventory.keep"

# Everything the inventory did not place is beyond the retention horizon. This is
# the only destructive step, and by now the incoming copy is unpacked beside it.
while read -r _ _ dir; do
  [ -n "$dir" ] || continue
  [ "$dir" = "$remotedir/current" ] && continue
  rm -rf "$dir"
done <"$inventory.sorted"

for staged in "$stage"/gen.*; do
  [ -d "$staged" ] || continue
  target="$remotedir/previous.${staged##*.}"
  rm -rf "$target"
  mv "$staged" "$target"
done

# Only now, with the incoming snapshot unpacked and the older generations
# settled, does `current` move aside.
if [ -d "$remotedir/current" ]; then
  if [ "$keep" -ge 2 ]; then
    rm -rf "$remotedir/previous"
    mv "$remotedir/current" "$remotedir/previous"
  else
    rm -rf "$remotedir/current"
  fi
fi
mkdir -p "$remotedir/current"
for entry in "$incoming"/*; do
  [ -e "$entry" ] || continue
  mv "$entry" "$remotedir/current/"
done
rm -rf "$incoming"
trap - EXIT
echo "durability: mirrored to $remotedir/current" >&2
REMOTE
)"

# Build the remote command for one board's subtree.
remote_command() {
  local board_target="$1"
  local script
  script="$(printf 'remotedir=%s\nkeep=%s\n%s' \
    "$(printf '%q' "$board_target")" "$GENERATIONS" "$remote_rotation_body")"
  printf 'bash -c "$(printf %%s %s | base64 -d)"' \
    "$(printf '%q' "$(printf '%s' "$script" | base64 | tr -d '\n')")"
}

# One board's snapshot, in its own directory under the temp root so a board that
# fails its integrity check cannot leave another board's snapshot looking broken.
stage_board() {
  local board="$1" stage_dir="$2" board_dir="$BOARDS_DIR/$1"

  if [[ ! -f "$board_dir/kanban.db" ]]; then
    fail "board $board: no kanban.db; not mirrored"
    return 1
  fi

  # `.backup` is the online backup API: safe against a database being written by
  # the gateway. The plain file copy this replaces could tear under WAL.
  if ! sqlite3 "$board_dir/kanban.db" ".backup '$stage_dir/kanban.db'" 2>/dev/null; then
    fail "board $board: sqlite online backup failed; not mirrored"
    return 1
  fi

  # Carry the board's identity across too, so a restore knows which board the
  # rows belong to without needing this script's naming scheme.
  if [[ -f "$board_dir/board.json" ]]; then
    cp "$board_dir/board.json" "$stage_dir/board.json"
  fi

  # Integrity gate: a snapshot that will not read back is worse than none,
  # because it looks like a backup until the day it is needed.
  if ! sqlite3 "$stage_dir/kanban.db" 'PRAGMA integrity_check;' 2>/dev/null | grep -qx ok; then
    fail "board $board: snapshot failed integrity_check; refusing to mirror"
    return 1
  fi

  {
    printf 'board=%s\n' "$board"
    printf 'tasks=%s\n' "$(sqlite3 "$stage_dir/kanban.db" 'SELECT count(*) FROM tasks;' 2>/dev/null || printf '?')"
    printf 'comments=%s\n' "$(sqlite3 "$stage_dir/kanban.db" 'SELECT count(*) FROM task_comments;' 2>/dev/null || printf '?')"
    # Commit of the checkout the board was driving, so a restore can tell whether
    # the board's world matches the code it will be resumed against.
    local board_checkout="${board_repo[$board]:-}"
    if [[ -n "$board_checkout" ]]; then
      printf 'repo_head=%s\n' "$(git -C "$board_checkout" rev-parse HEAD 2>/dev/null || printf '?')"
    fi
    printf 'integrity=ok\n'
  } >"$stage_dir/MANIFEST"
}

mirrored=0
for board in "${boards[@]}"; do
  board_snapshot="$snapshot_root/$board"
  mkdir -p "$board_snapshot"
  stage_board "$board" "$board_snapshot" || continue

  board_target="$REMOTE_DIR/$board"

  if [[ "$check_only" == true ]]; then
    log "check-only: would mirror board $board to $target:$board_target/current"
    cat "$board_snapshot/MANIFEST" >&2
    mirrored=$((mirrored + 1))
    continue
  fi

  if tar -C "$board_snapshot" -czf - . | \
     timeout 120 ssh -o BatchMode=yes -o ConnectTimeout=10 "$target" \
       "$(remote_command "$board_target")" 2>&1; then
    log "board $board mirrored to $target:$board_target/current (Kopia covers /persist)"
    mirrored=$((mirrored + 1))
  else
    # The remote script only touches an older generation after the incoming
    # snapshot has been unpacked, so a failure here leaves the previous copy in
    # place rather than replacing it with nothing.
    fail "board $board: mirror to $target failed; the board remains local-only"
  fi
done

if ((mirrored == 0)); then
  fail "no board was mirrored"
fi

log "done: $mirrored board(s) mirrored, $failures problem(s)"
exit "$failures"