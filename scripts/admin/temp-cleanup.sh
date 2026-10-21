#!/usr/bin/env bash
# Reclaim Hermes and development temporary files on a workstation or server.
#
# Why this exists
# ---------------
# Hermes keeps caches, scratch directories, logs and worktrees under its home,
# and development work leaves test output and scratch trees in the repository.
# The server already reclaims aged tmpfiles and the Nix store, but only under
# disk pressure, and the workstation has no equivalent routine at all. This is
# the regular, conservative pass: it deletes only entries inside an explicit
# allowlist that are older than the configured age, and it never touches
# recorded work, boards, backups, secrets, model weights or worktrees it cannot
# prove are safe.
#
# Safety contract
# ---------------
# * The default action is a dry run; nothing is removed without --apply.
# * Only entries directly inside the allowlisted roots are considered:
#     - $HERMES_HOME/cache/*            (14 days)
#     - $HERMES_HOME/profiles/*/cache/* (14 days)
#     - $HERMES_HOME/logs/*.log         (14 days)
#     - $HERMES_HOME/profiles/*/scratch/* with --include-scratch (30 days)
#     - $HERMES_HOME/installs/* with --include-installs (30 days)
#     - $TMP_DIR/nixhomeserver-*, $TMP_DIR/hermes-*  (7 days)
#     - $REPO/.tmp/*                    (7 days)
#     - $REPO/output/*, test-results/*, playwright-report/* (14 days)
# * An entry is preserved when it is a symlink, a mount point, or when it
#   contains protected content: .git, SOUL.md, *.db/*.sqlite, *.age, *.gguf,
#   *.env, secrets, models, *.kdbx, *.pem, *.key, or an archive.
# * The filesystem boundary is never crossed (find -xdev, rm --one-file-system),
#   so a bind mount or NFS share under a cache root cannot be deleted through it.
# * Worktrees are never deleted here. With --include-worktrees the script runs
#   Hermes' own audited `worktree prune` (which keeps uncommitted and unpushed
#   work) and this repository's kanban reaper when both are available.
# * The script refuses to run under a second concurrent invocation.
#
# Run as the user who owns the temporary files. The default is a dry run; pass
# --apply from the scheduled unit.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

apply=false
bytes=false
include_scratch=false
include_installs=false
include_worktrees=false

max_age_days="${TEMP_CLEANUP_MAX_AGE_DAYS:-14}"
scratch_age_days="${TEMP_CLEANUP_SCRATCH_AGE_DAYS:-30}"
installs_age_days="${TEMP_CLEANUP_INSTALLS_AGE_DAYS:-30}"
tmp_age_days="${TEMP_CLEANUP_TMP_AGE_DAYS:-7}"

hermes_home="${TEMP_CLEANUP_HERMES_HOME:-${HERMES_HOME:-$HOME/.hermes}}"
repo_path="${TEMP_CLEANUP_REPO_PATH:-$(cd "$script_dir/../.." && pwd)}"
tmp_dir="${TEMP_CLEANUP_TMP_DIR:-/tmp}"
state_root="${XDG_STATE_HOME:-$HOME/.local/state}"
state_dir="${TEMP_CLEANUP_STATE_DIR:-$state_root/nixhomeserver}"
lock_path="${TEMP_CLEANUP_LOCK_PATH:-$state_dir/temp-cleanup.lock}"
hermes_bin="${TEMP_CLEANUP_HERMES_BIN:-}"

usage() {
  cat <<'EOF'
Usage: temp-cleanup.sh [--apply] [--bytes] [--max-age-days N]
                       [--scratch-age-days N] [--installs-age-days N]
                       [--tmp-age-days N] [--include-scratch] [--include-installs]
                       [--include-worktrees] [--hermes-home PATH] [--repo PATH]
                       [--tmp-dir PATH] [-h]

Reclaim Hermes and development temporary files without touching valuable data.

  --apply                Delete the classified entries; default is a dry run.
  --bytes                Include byte accounting (walks each candidate with du).
  --max-age-days N       Age for caches, logs, logs and test output (default 14).
  --scratch-age-days N   Age for Hermes profile scratch (default 30).
  --installs-age-days N  Age for Hermes project environments (default 30).
  --tmp-age-days N       Age for /tmp scratch owned by this tooling (default 7).
  --include-scratch      Also reap $HERMES_HOME/profiles/*/scratch entries.
  --include-installs     Also reap $HERMES_HOME/installs project environments.
  --include-worktrees    Also run Hermes' audited worktree prune and this repo's
                         kanban worktree reaper when they are available.
  --hermes-home PATH     Hermes home (default $HERMES_HOME or ~/.hermes).
  --repo PATH            Repository holding .tmp and generated output.
  --tmp-dir PATH         Temporary directory to scan (default /tmp).
  -h, --help             Show this help.

Entries are preserved when they are symlinks, mount points, or contain .git,
SOUL.md, *.db/*.sqlite, *.age, *.gguf, *.env, secrets, models, credentials or
archives. The default is always a dry run.
EOF
}

while (($# > 0)); do
  case "$1" in
    --apply) apply=true; shift ;;
    --dry-run) apply=false; shift ;;
    --bytes) bytes=true; shift ;;
    --include-scratch) include_scratch=true; shift ;;
    --include-installs) include_installs=true; shift ;;
    --include-worktrees) include_worktrees=true; shift ;;
    --max-age-days) [[ $# -ge 2 ]] || { echo "❌ --max-age-days needs a value" >&2; exit 2; }; max_age_days="$2"; shift 2 ;;
    --scratch-age-days) [[ $# -ge 2 ]] || { echo "❌ --scratch-age-days needs a value" >&2; exit 2; }; scratch_age_days="$2"; shift 2 ;;
    --installs-age-days) [[ $# -ge 2 ]] || { echo "❌ --installs-age-days needs a value" >&2; exit 2; }; installs_age_days="$2"; shift 2 ;;
    --tmp-age-days) [[ $# -ge 2 ]] || { echo "❌ --tmp-age-days needs a value" >&2; exit 2; }; tmp_age_days="$2"; shift 2 ;;
    --hermes-home) [[ $# -ge 2 ]] || { echo "❌ --hermes-home needs a value" >&2; exit 2; }; hermes_home="$2"; shift 2 ;;
    --repo) [[ $# -ge 2 ]] || { echo "❌ --repo needs a value" >&2; exit 2; }; repo_path="$2"; shift 2 ;;
    --tmp-dir) [[ $# -ge 2 ]] || { echo "❌ --tmp-dir needs a value" >&2; exit 2; }; tmp_dir="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "❌ Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

for value_name in max_age_days scratch_age_days installs_age_days tmp_age_days; do
  value="${!value_name}"
  if [[ ! "$value" =~ ^[1-9][0-9]*$ ]] || ((value > 3650)); then
    echo "❌ $value_name must be an integer from 1 through 3650." >&2
    exit 2
  fi
done

# One cleanup at a time. A second invocation skips instead of racing the first
# over the same cache directories.
install -d -m 0755 -- "$(dirname -- "$lock_path")"
exec 9>"$lock_path"
if ! flock -n 9; then
  echo "ℹ️  Another temp cleanup holds the lock; skipping."
  exit 0
fi

processed=0 removed=0 candidates=0 protected=0 symlinks=0 foreign=0
failed=0 removed_bytes=0 candidate_bytes=0
reports=()

human() { awk -v b="$1" 'BEGIN{printf "%.1f GiB", b/1024/1024/1024}'; }

# Print a path relative to the current user's home when possible.
display() {
  local p="$1"
  if [[ "$p" == "$HOME"/* ]]; then
    printf '%s/%s' '~' "${p#"$HOME"/}"
  else
    printf '%s' "$p"
  fi
}

protected_entry() { # <path>; returns 0 when the entry must be kept
  local p="$1" base found
  base="${p##*/}"
  case "$base" in
    *.db|*.db-wal|*.db-shm|*.sqlite|*.sqlite3|*.age|*.gguf|*.gguf.part|*.part) return 0 ;;
    *.pem|*.key|*.kdbx|*.gpg|*.asc|*.crt) return 0 ;;
    *.zip|*.tar|*.tar.gz|*.tgz|*.tar.xz|*.tar.zst|*.7z|*.rar) return 0 ;;
    .env|.env.*|*.env|secrets|id_rsa|id_ed25519) return 0 ;;
  esac
  if mountpoint -q "$p" 2>/dev/null; then
    return 0
  fi
  [[ -d "$p" ]] || return 1
  found="$(find -P "$p" -xdev -maxdepth 3 \( \
      -name .git -o -name '*.db' -o -name '*.sqlite*' -o -name '*.age' \
      -o -name SOUL.md -o -name secrets -o -name '*.kdbx' -o -name '*.gguf*' \
      -o -name '*.env' -o -name models -o -name .ssh \) -print -quit 2>/dev/null)"
  [[ -n "$found" ]]
}

# scan_root <root> <age-days> <label> [find-name-pattern]
scan_root() {
  local root="$1" age="$2" label="$3" pattern="${4:-}"
  local list entry size
  local -a find_args=()
  if [[ -n "$pattern" ]]; then
    find_args=(-name "$pattern")
  fi
  if [[ ! -d "$root" ]]; then
    return 0
  fi
  list="$(mktemp)"
  if ! find -P "$root" -mindepth 1 -maxdepth 1 -xdev -mtime "+$age" \
      "${find_args[@]}" -print0 >"$list" 2>/dev/null; then
    echo "⚠️  Could not scan $root; leaving it untouched." >&2
    rm -f -- "$list"
    failed=$((failed+1))
    return 0
  fi
  local -a entries=()
  mapfile -d '' -t entries <"$list"
  rm -f -- "$list"
  for entry in "${entries[@]}"; do
    [[ -n "$entry" ]] || continue
    processed=$((processed+1))
    if [[ -L "$entry" ]]; then
      symlinks=$((symlinks+1))
      continue
    fi
    # Never remove another user's files, even under a shared /tmp.
    if [[ "$(stat -c %u -- "$entry" 2>/dev/null || echo -1)" != "$EUID" ]]; then
      foreign=$((foreign+1))
      continue
    fi
    if protected_entry "$entry"; then
      protected=$((protected+1))
      continue
    fi
    size=0
    if [[ "$bytes" == true ]]; then
      size="$(du -sb "$entry" 2>/dev/null | cut -f1)"; size="${size:-0}"
    fi
    if [[ "$apply" == true ]]; then
      if rm -rf --one-file-system -- "$entry"; then
        removed=$((removed+1)); removed_bytes=$((removed_bytes+size))
        echo "  removed ($label): $(display "$entry")"
      else
        failed=$((failed+1))
        echo "⚠️  Could not remove: $(display "$entry")" >&2
      fi
    else
      candidates=$((candidates+1)); candidate_bytes=$((candidate_bytes+size))
      echo "  would remove ($label): $(display "$entry")"
    fi
  done
}

if [[ ! -d "$hermes_home" ]]; then
  echo "ℹ️  No Hermes home at $hermes_home; skipping Hermes caches."
else
  scan_root "$hermes_home/cache" "$max_age_days" "hermes cache"
  for profile_dir in "$hermes_home"/profiles/*/; do
    [[ -d "$profile_dir" ]] || continue
    profile_dir="${profile_dir%/}"
    scan_root "$profile_dir/cache" "$max_age_days" "profile cache"
    scan_root "$profile_dir/logs" "$max_age_days" "profile log" '*.log'
    if [[ "$include_scratch" == true ]]; then
      scan_root "$profile_dir/scratch" "$scratch_age_days" "profile scratch"
    fi
  done
  scan_root "$hermes_home/logs" "$max_age_days" "hermes log" '*.log'
  if [[ "$include_installs" == true ]]; then
    scan_root "$hermes_home/installs" "$installs_age_days" "hermes install"
  fi
  reports+=("$hermes_home/installs" "$hermes_home/tools")
fi

scan_root "$tmp_dir" "$tmp_age_days" "tmp" 'nixhomeserver-*'
scan_root "$tmp_dir" "$tmp_age_days" "tmp" 'hermes-*'

if [[ -d "$repo_path" ]]; then
  scan_root "$repo_path/.tmp" "$tmp_age_days" "repo scratch"
  scan_root "$repo_path/output" "$max_age_days" "repo output"
  scan_root "$repo_path/test-results" "$max_age_days" "test results"
  scan_root "$repo_path/playwright-report" "$max_age_days" "playwright report"
fi

if [[ "$include_worktrees" == true ]]; then
  if [[ -z "$hermes_bin" ]]; then
    hermes_bin="$(command -v hermes 2>/dev/null || true)"
  fi
  if [[ -z "$hermes_bin" && -x "$HOME/.local/bin/hermes" ]]; then
    hermes_bin="$HOME/.local/bin/hermes"
  fi
  agent_repo="$hermes_home/hermes-agent"
  if [[ -n "$hermes_bin" && -d "$agent_repo/.git" ]]; then
    if [[ "$apply" == true ]]; then
      echo "▶ Hermes worktree prune in $agent_repo"
      "$hermes_bin" worktree prune --repo "$agent_repo" --older-than "$max_age_days" \
        || { failed=$((failed+1)); echo "⚠️  hermes worktree prune failed." >&2; }
    else
      echo "▶ Hermes worktree audit in $agent_repo (dry run)"
      "$hermes_bin" worktree list --repo "$agent_repo" --older-than "$max_age_days" \
        || { failed=$((failed+1)); echo "⚠️  hermes worktree list failed." >&2; }
    fi
  fi
  kanban_reaper="$script_dir/../hermes/reap-kanban-worktrees.sh"
  if [[ -n "$hermes_bin" && -x "$kanban_reaper" ]]; then
    if [[ "$apply" == true ]]; then
      HERMES_BIN="$hermes_bin" "$kanban_reaper" --apply \
        || { failed=$((failed+1)); echo "⚠️  kanban worktree reaper failed." >&2; }
    else
      HERMES_BIN="$hermes_bin" "$kanban_reaper" \
        || { failed=$((failed+1)); echo "⚠️  kanban worktree reaper failed." >&2; }
    fi
  elif [[ -x "$kanban_reaper" ]]; then
    echo "ℹ️  hermes is not on PATH; skipping the kanban worktree reaper."
  fi
fi

if [[ "$bytes" == true ]]; then
  for report_root in "${reports[@]}"; do
    [[ -d "$report_root" ]] || continue
    echo "ℹ️  Kept (never auto-deleted): $(display "$report_root") $(du -sh "$report_root" 2>/dev/null | cut -f1)"
  done
fi

echo "Processed (older than retention): ${processed}"
if [[ "$apply" == true ]]; then
  echo "Removed:                          ${removed}$( [[ "$bytes" == true ]] && printf ' (%s)' "$(human "$removed_bytes")" )"
else
  echo "Removable:                        ${candidates}$( [[ "$bytes" == true ]] && printf ' (%s)' "$(human "$candidate_bytes")" )"
fi
echo "Preserved (protected content):    ${protected}"
echo "Skipped (symlink):                ${symlinks}"
echo "Skipped (not owned by this user): ${foreign}"

if ((failed > 0)); then
  echo "❌ ${failed} cleanup step(s) failed; inspect the warnings above." >&2
  exit 1
fi
if [[ "$apply" != true ]]; then
  noun="entries"
  if ((candidates == 1)); then
    noun="entry"
  fi
  echo "ℹ️  Dry run. Re-run with --apply to remove the ${candidates} classified ${noun}."
fi
