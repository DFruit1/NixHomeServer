#!/usr/bin/env bash

# Reads the dashboard-selected Nix build mode from the target server.
#
# The Homepage dashboard stores the operator's build-allocation choice at
# /var/lib/deploy-settings/build-mode.json. Deploys consult it as the default
# (CLI --build-mode, --build-locally, and --build-host still win). Any absent,
# unreadable, or malformed answer yields no output so the caller can fall back
# to vars.system.buildMode.

dashboard_build_mode_state_file="/var/lib/deploy-settings/build-mode.json"

read_dashboard_build_mode() {
  local target="$1"
  local payload mode

  if ! payload="$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$target" \
    "cat ${dashboard_build_mode_state_file}" 2>/dev/null)"; then
    return 1
  fi

  mode="$(jq -er '.buildMode // empty' <<<"$payload" 2>/dev/null)" || return 1

  case "$mode" in
    local|remote|balanced|maximum-effort)
      printf '%s\n' "$mode"
      ;;
    *)
      return 1
      ;;
  esac
}
