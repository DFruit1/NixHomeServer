#!/usr/bin/env bash

set -euo pipefail

export NIX_CONFIG="${NIX_CONFIG:-experimental-features = nix-command flakes
accept-flake-config = true}"

: "${TARGET_HOST:?missing TARGET_HOST}"
: "${BUILD_HOST:?missing BUILD_HOST}"
: "${ACTION:?missing ACTION}"
: "${HOSTNAME_ARG:?missing HOSTNAME_ARG}"
: "${DEBUG_MODE:=false}"
: "${BUILD_LOCALLY:=false}"

min_build_host_free_bytes=$((10 * 1024 * 1024 * 1024))
min_tmp_free_bytes=$((1 * 1024 * 1024 * 1024))

human_bytes() {
  local bytes="$1"
  awk -v bytes="$bytes" 'BEGIN { printf "%.2f GiB", bytes / 1073741824 }'
}

check_free_space() {
  local sandbox_build_dir build_backing_path build_available_bytes tmp_available_bytes

  sandbox_build_dir="$(nix config show 2>/dev/null | sed -n 's/^sandbox-build-dir = //p' | head -n 1)"
  if [[ -z "$sandbox_build_dir" ]]; then
    sandbox_build_dir="/build"
  fi

  build_backing_path="$sandbox_build_dir"
  while [[ ! -e "$build_backing_path" && "$build_backing_path" != "/" ]]; do
    build_backing_path="$(dirname "$build_backing_path")"
  done

  build_available_bytes="$(df -B1 --output=avail "$build_backing_path" | awk 'NR==2 { print $1 }')"
  tmp_available_bytes="$(df -B1 --output=avail /tmp | awk 'NR==2 { print $1 }')"

  echo "build space: ${build_backing_path} $(human_bytes "$build_available_bytes"), /tmp $(human_bytes "$tmp_available_bytes")"

  if (( build_available_bytes < min_build_host_free_bytes )); then
    echo "blocked: build host has insufficient Nix build space" >&2
    exit 1
  fi

  if (( tmp_available_bytes < min_tmp_free_bytes )); then
    echo "blocked: build host has insufficient /tmp space" >&2
    exit 1
  fi
}

target_is_local() {
  [[ "$BUILD_LOCALLY" != "true" && "$TARGET_HOST" == "$BUILD_HOST" ]]
}

check_failed_units() {
  local failed_units failed_unit failed_unit_quoted

  if target_is_local; then
    sudo systemctl --failed --no-pager
    failed_units="$(sudo systemctl --failed --no-legend --plain | awk '{ print $1 }' || true)"
  else
    ssh "$TARGET_HOST" "sudo systemctl --failed --no-pager"
    failed_units="$(ssh "$TARGET_HOST" "sudo systemctl --failed --no-legend --plain | awk '{ print \$1 }'" || true)"
  fi

  if [[ -n "$failed_units" ]]; then
    if [[ "$DEBUG_MODE" == "true" ]]; then
      if target_is_local; then
        while IFS= read -r failed_unit; do
          [[ -n "$failed_unit" ]] || continue
          sudo systemctl status --no-pager "$failed_unit" || true
        done <<< "$failed_units"
        sudo journalctl -p warning..alert -n 200 --no-pager || true
      else
        while IFS= read -r failed_unit; do
          [[ -n "$failed_unit" ]] || continue
          failed_unit_quoted="$(printf '%q' "$failed_unit")"
          ssh -n "$TARGET_HOST" "sudo systemctl status --no-pager $failed_unit_quoted || true"
        done <<< "$failed_units"
        ssh "$TARGET_HOST" "sudo journalctl -p warning..alert -n 200 --no-pager || true"
      fi
    fi
    echo "blocked: failed systemd units detected" >&2
    exit 1
  fi
}

make_rebuild_command() {
  local -n out_cmd="$1"
  local rebuild_action="$ACTION"

  if [[ "$ACTION" == "switch" ]]; then
    rebuild_action="boot"
  fi

  out_cmd=(nix run --inputs-from . nixpkgs#nixos-rebuild -- "$rebuild_action" --flake ".#${HOSTNAME_ARG}" --sudo)

  if [[ "$BUILD_LOCALLY" == "true" ]]; then
    out_cmd+=(--target-host "$TARGET_HOST")
  elif [[ "$TARGET_HOST" != "$BUILD_HOST" ]]; then
    out_cmd+=(--target-host "$TARGET_HOST")
  fi
}

target_command() {
  local command="$1"

  if target_is_local; then
    bash -c "$command"
  else
    ssh "$TARGET_HOST" "$command"
  fi
}

run_detached_switch() {
  local unit state result status start_command

  unit="nixos-detached-switch-$(date +%s)"
  start_command="sudo systemd-run --unit=$(printf '%q' "$unit") --description='Detached NixOS switch activation' --service-type=exec /nix/var/nix/profiles/system/bin/switch-to-configuration switch"

  echo "starting detached switch activation as ${unit}"
  target_command "$start_command"

  for ((attempt = 1; attempt <= 300; attempt++)); do
    state="$(target_command "systemctl show -P ActiveState $(printf '%q' "$unit") 2>/dev/null || true")"
    case "$state" in
      active|activating|reloading)
        sleep 2
        ;;
      *)
        break
        ;;
    esac
  done

  if [[ "$state" == "active" || "$state" == "activating" || "$state" == "reloading" ]]; then
    echo "blocked: detached switch activation timed out" >&2
    exit 1
  fi

  result="$(target_command "systemctl show -P Result $(printf '%q' "$unit") 2>/dev/null || true")"
  status="$(target_command "systemctl show -P ExecMainStatus $(printf '%q' "$unit") 2>/dev/null || true")"

  if [[ "$result" != "success" || "$status" != "0" ]]; then
    target_command "sudo systemctl status --no-pager $(printf '%q' "$unit") || true"
    echo "blocked: detached switch activation failed" >&2
    exit 1
  fi

  target_command "sudo systemctl reset-failed $(printf '%q' "$unit") >/dev/null 2>&1 || true"
}

check_free_space

echo "evaluating host ${HOSTNAME_ARG}"
nix eval --raw ".#nixosConfigurations.${HOSTNAME_ARG}.config.system.build.toplevel.drvPath" >/dev/null

if [[ "$DEBUG_MODE" == "true" ]]; then
  echo "running debug validation"
  ./scripts/validate-repo.sh --full
fi

cmd=()
make_rebuild_command cmd

if [[ "$ACTION" == "switch" ]]; then
  echo "running nixos-rebuild boot before detached switch"
else
  echo "running nixos-rebuild ${ACTION}"
fi
"${cmd[@]}"

if [[ "$ACTION" == "switch" ]]; then
  run_detached_switch
fi

echo "checking failed units"
check_failed_units
