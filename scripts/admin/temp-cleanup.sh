#!/usr/bin/env bash
# Reclaim aged development scratch and generated output.
# Default is a dry run. Only allowlisted roots are scanned, and protected data,
# symlinks, mounts, repositories and worktrees are preserved. No orchestration
# tool or worktree-pruning helper is discovered or invoked.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

apply=false
bytes=false

max_age_days="${TEMP_CLEANUP_MAX_AGE_DAYS:-14}"
tmp_age_days="${TEMP_CLEANUP_TMP_AGE_DAYS:-7}"

repo_path="${TEMP_CLEANUP_REPO_PATH:-$(cd "$script_dir/../.." && pwd)}"
tmp_dir="${TEMP_CLEANUP_TMP_DIR:-/tmp}"
state_root="${XDG_STATE_HOME:-$HOME/.local/state}"
state_dir="${TEMP_CLEANUP_STATE_DIR:-$state_root/nixhomeserver}"
lock_path="${TEMP_CLEANUP_LOCK_PATH:-$state_dir/temp-cleanup.lock}"

usage() {
  cat <<'EOF'
Usage: temp-cleanup.sh [--apply] [--bytes] [--max-age-days N]
                       [--tmp-age-days N] [--repo PATH] [--tmp-dir PATH] [-h]

Reclaim development temporary files without touching valuable data.

  --apply                Delete classified entries; default is a dry run.
  --bytes                Include byte accounting (walks each candidate with du).
  --max-age-days N        Age for generated output (default 14).
  --tmp-age-days N        Age for task scratch (default 7).
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
    --max-age-days) [[ $# -ge 2 ]] || { echo "❌ --max-age-days needs a value" >&2; exit 2; }; max_age_days="$2"; shift 2 ;;
    --tmp-age-days) [[ $# -ge 2 ]] || { echo "❌ --tmp-age-days needs a value" >&2; exit 2; }; tmp_age_days="$2"; shift 2 ;;
    --repo) [[ $# -ge 2 ]] || { echo "❌ --repo needs a value" >&2; exit 2; }; repo_path="$2"; shift 2 ;;
    --tmp-dir) [[ $# -ge 2 ]] || { echo "❌ --tmp-dir needs a value" >&2; exit 2; }; tmp_dir="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "❌ Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

for value_name in max_age_days tmp_age_days; do
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

task_tmp="$(mktemp -d /tmp/nixhomeserver-temp-cleanup.XXXXXXXX)"
trap 'rm -rf -- "$task_tmp"' EXIT

processed=0 removed=0 candidates=0 protected=0 symlinks=0 foreign=0
failed=0 removed_bytes=0 candidate_bytes=0

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
  list="$(mktemp "$task_tmp/scan.XXXXXXXX")"
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

scan_root "$tmp_dir" "$tmp_age_days" "tmp" 'nixhomeserver-*'

if [[ -d "$repo_path" ]]; then
  scan_root "$repo_path/.tmp" "$tmp_age_days" "repo scratch"
  scan_root "$repo_path/output" "$max_age_days" "repo output"
  scan_root "$repo_path/test-results" "$max_age_days" "test results"
  scan_root "$repo_path/playwright-report" "$max_age_days" "playwright report"
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
