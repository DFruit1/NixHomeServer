#!/usr/bin/env bash
# Push agent work off this machine and mirror the kanban board to the server.
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
#   2. Copy a consistent snapshot of the board to the server's /persist, which
#      Kopia already snapshots. Restoring is then a kopia restore plus a file
#      copy, with no dependency on this machine being bootable.
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
# Only the board is mirrored, not all of ~/.hermes: that tree is 5.1 GB of
# virtualenvs, model weights and tool installs, all of which reinstall from
# their own sources. The irreplaceable part is a few megabytes.
#
# Usage
# -----
#   scripts/hermes/kanban-durability-sync.sh            # push + mirror
#   scripts/hermes/kanban-durability-sync.sh --check    # report only, push nothing
#
# Environment
# -----------
#   HERMES_ROOT          hermes state dir  (default: ~/.hermes)
#   HERMES_BOARD         board slug        (default: nixhomeserver)
#   DURABILITY_TARGET    user@host         (default: auto-resolved from vars.nix)
#   DURABILITY_REMOTE_DIR remote dir under /persist (default:
#                        /persist/home/dsaw/.hermes-durability)
#
# The default sits under /persist because that is the only root Kopia snapshots
# (repo.backups.snapshotRoots = [ "/persist" ]), so the mirror inherits the
# server's existing encrypted, off-site backup schedule with no new machinery.
# It is the user's own subdirectory rather than /persist itself because
# /persist is root-owned; using sudo from a cron tick would add a privileged
# path to a job that runs unattended.

set -euo pipefail

HERMES_ROOT="${HERMES_ROOT:-$HOME/.hermes}"
HERMES_BOARD="${HERMES_BOARD:-nixhomeserver}"
REMOTE_DIR="${DURABILITY_REMOTE_DIR:-/persist/home/dsaw/.hermes-durability}"

check_only=false
[[ "${1:-}" == "--check" ]] && check_only=true

log() { printf 'durability: %s\n' "$*" >&2; }

repo="$HERMES_ROOT/kanban/boards/$HERMES_BOARD"
db="$repo/kanban.db"
board_json="$repo/board.json"

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

  local config
  config="$(nix_flake_json '{
    localAdminUser = if vars ? localAdminUser then vars.localAdminUser else vars.identity.localAdminUser;
    serverLanIP = vars.serverLanIP;
  }')" || return 1
  jq -er '"\(.localAdminUser)@\(.serverLanIP)"' <<<"$config"
}

work_repo=""
for candidate in "$PWD" "$repo/../../.." ; do
  if [[ -n "$candidate" ]] && git -C "$candidate" rev-parse --git-dir >/dev/null 2>&1; then
    work_repo="$(cd "$candidate" && pwd)"
    break
  fi
done

if [[ -z "$work_repo" ]]; then
  log "no git checkout found; skipping branch push"
elif [[ "$check_only" == true ]]; then
  log "check-only: would push from $work_repo"
else
  # Bounded fetch so an unreachable remote cannot stall the mirror.
  timeout 60 git -C "$work_repo" fetch --quiet origin 2>/dev/null || \
    log "fetch failed; comparing against last known remote refs"

  pushed=0
  while read -r branch sha; do
    [[ -n "$branch" ]] || continue
    ahead="$(git -C "$work_repo" rev-list --count "$sha" --not --remotes 2>/dev/null || printf '?')"
    [[ "$ahead" =~ ^[0-9]+$ ]] || { log "cannot count commits on $branch; skipping"; continue; }
    ((ahead > 0)) || continue
    if git -C "$work_repo" push --quiet origin "$sha:refs/heads/$branch" 2>/dev/null; then
      log "pushed $branch ($ahead commit(s))"
      pushed=$((pushed + 1))
    else
      log "push FAILED for $branch; left untouched for the operator"
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
        log "push FAILED for master; left untouched for the operator"
      fi
    fi
  fi
  log "branch push complete ($pushed pushed)"
fi

# ---------------------------------------------------------------------------
# 2. Mirror the board to Kopia-covered storage on the server
# ---------------------------------------------------------------------------

if [[ ! -f "$db" ]]; then
  log "no kanban.db for board $HERMES_BOARD; nothing to mirror"
  exit 0
fi

target="$(resolve_target)" || { log "could not resolve durability target; board not mirrored"; exit 0; }

snapshot_dir="$(mktemp -d)"
trap 'rm -rf "$snapshot_dir"' EXIT

# `.backup` is the online backup API: safe against a database being written by
# the gateway. The plain file copy this replaces could tear under WAL.
if ! sqlite3 "$db" ".backup '$snapshot_dir/kanban.db'" 2>/dev/null; then
  log "sqlite online backup failed; board not mirrored"
  exit 0
fi

# Carry the audit records out of the database into readable files. Two of the
# three audits from the current sweep survive only as these blobs, so a restore
# should not require an operator to know the schema to read them.
if [[ -f "$board_json" ]]; then
  cp "$board_json" "$snapshot_dir/board.json"
fi

# Integrity gate: a snapshot that will not read back is worse than none,
# because it looks like a backup until the day it is needed.
if ! sqlite3 "$snapshot_dir/kanban.db" 'PRAGMA integrity_check;' 2>/dev/null | grep -qx ok; then
  log "snapshot failed integrity_check; refusing to mirror"
  exit 0
fi

manifest="$snapshot_dir/MANIFEST"
{
  printf 'board=%s\n' "$HERMES_BOARD"
  printf 'tasks=%s\n' "$(sqlite3 "$snapshot_dir/kanban.db" 'SELECT count(*) FROM tasks;' 2>/dev/null || printf '?')"
  printf 'comments=%s\n' "$(sqlite3 "$snapshot_dir/kanban.db" 'SELECT count(*) FROM task_comments;' 2>/dev/null || printf '?')"
  # Commit of the checkout the board was driving, so a restore can tell whether
  # the board's world matches the code it will be resumed against.
  if [[ -n "$work_repo" ]]; then
    printf 'repo_head=%s\n' "$(git -C "$work_repo" rev-parse HEAD 2>/dev/null || printf '?')"
  fi
  printf 'integrity=ok\n'
} >"$manifest"

if [[ "$check_only" == true ]]; then
  log "check-only: would mirror board $HERMES_BOARD to $target:$REMOTE_DIR"
  cat "$manifest" >&2
  exit 0
fi

# Tar so the transfer is one stream and the server side is atomic: unpack to a
# temp name beside the target, then swap. A half-written kanban.db on the
# server is worse than a stale one, so the swap is the only visible step.
if ! tar -C "$snapshot_dir" -czf - . | \
     timeout 120 ssh -o BatchMode=yes -o ConnectTimeout=10 "$target" \
       "set -eu
        umask 077
        mkdir -p '$REMOTE_DIR'
        tmp=\$(mktemp -d '$REMOTE_DIR/.incoming.XXXXXX')
        trap 'rm -rf \"\$tmp\"' EXIT
        # The workstation and the server clocks differ by a fraction of a second,
        # which makes tar warn about future timestamps on every file. The
        # warning is noise on an unattended job and hides real failures.
        tar -xzf - -C \"\$tmp\" --warning=no-timestamp
        rm -rf '$REMOTE_DIR'.previous
        if [ -d '$REMOTE_DIR/current' ]; then mv '$REMOTE_DIR/current' '$REMOTE_DIR'.previous; fi
        mkdir -p '$REMOTE_DIR/current'
        mv \"\$tmp\"/* '$REMOTE_DIR/current'/
        trap - EXIT
        rm -rf \"\$tmp\"
        echo durability: mirrored board to '$REMOTE_DIR/current' >&2" 2>&1; then
  log "mirror to $target failed; board remains local-only"
  exit 0
fi

log "board mirrored to $target:$REMOTE_DIR/current (Kopia covers /persist)"
exit 0