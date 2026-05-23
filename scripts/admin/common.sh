#!/usr/bin/env bash

set -euo pipefail

admin_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$admin_script_dir/../helpers/repo-common.sh"
init_repo_root NIXHOMESERVER_REPO_ROOT
cd_repo_root
ensure_default_nix_config

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

default_host() {
  if [[ -n "${NIXHOMESERVER_DEFAULT_HOST:-}" ]]; then
    printf '%s\n' "$NIXHOMESERVER_DEFAULT_HOST"
    return 0
  fi

  if ! command -v nix >/dev/null 2>&1; then
    echo "blocked: missing required tool: nix" >&2
    exit 1
  fi

  nix eval --raw --impure --expr "
    let
      flake = builtins.getFlake (toString ${repo_root});
      lib = flake.inputs.nixpkgs.lib;
      vars = import ${repo_root}/vars.nix { inherit lib; };
    in
      vars.hostname
  "
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
