#!/usr/bin/env bash

set -euo pipefail

admin_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="${NIXHOMESERVER_REPO_ROOT:-}"

if [[ -z "$repo_root" ]]; then
  if git_root="$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null)"; then
    repo_root="$git_root"
  else
    repo_root="$(cd "$admin_script_dir/../.." && pwd)"
  fi
fi

cd "$repo_root"

export NIX_CONFIG="${NIX_CONFIG:-experimental-features = nix-command flakes
accept-flake-config = true}"

status_ready=0
status_warning=0
status_blocked=0

need() {
  local tool
  for tool in "$@"; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      echo "blocked: missing required tool: $tool"
      status_blocked=$((status_blocked + 1))
    fi
  done
}

ready() {
  echo "ready: $*"
  status_ready=$((status_ready + 1))
}

warn() {
  echo "warning: $*"
  status_warning=$((status_warning + 1))
}

block() {
  echo "blocked: $*"
  status_blocked=$((status_blocked + 1))
}

finish_report() {
  echo
  echo "summary: ${status_ready} ready, ${status_warning} warning, ${status_blocked} blocked"
  if ((status_blocked > 0)); then
    exit 1
  fi
}

discovered_hosts() {
  find "$repo_root/hosts" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' \
    | while IFS= read -r host; do
        if [[ -f "$repo_root/hosts/$host/default.nix" && -f "$repo_root/hosts/$host/settings.nix" ]]; then
          printf '%s\n' "$host"
        fi
      done \
    | sort
}

default_host() {
  local non_example_hosts host_count

  if [[ -n "${NIXHOMESERVER_DEFAULT_HOST:-}" ]]; then
    printf '%s\n' "$NIXHOMESERVER_DEFAULT_HOST"
    return 0
  fi

  if [[ -d "$repo_root/hosts/dsaw" ]]; then
    printf '%s\n' "dsaw"
    return 0
  fi

  non_example_hosts="$(discovered_hosts | awk '$0 != "example"')"
  host_count="$(printf '%s\n' "$non_example_hosts" | sed '/^$/d' | wc -l | tr -d ' ')"
  if [[ "$host_count" == "1" ]]; then
    printf '%s\n' "$non_example_hosts"
    return 0
  fi

  echo "blocked: pass --host; no unambiguous default host is available" >&2
  exit 1
}

nix_json_for_host() {
  local host="$1"
  local expr="$2"
  nix eval --json --impure --expr "
    let
      flake = builtins.getFlake (toString ${repo_root});
      cfg = flake.nixosConfigurations.${host}.config;
    in
      ${expr}
  "
}
