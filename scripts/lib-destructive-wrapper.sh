#!/usr/bin/env bash

fail() {
  echo "❌ $1" >&2
  exit 1
}

join_by_space() {
  local first=1
  local item

  for item in "$@"; do
    if (( first )); then
      printf '%s' "$item"
      first=0
    else
      printf ' %s' "$item"
    fi
  done
}

join_command() {
  local rendered
  printf -v rendered '%q ' "$@"
  printf '%s\n' "${rendered% }"
}

print_device_paths() {
  local disk_id
  for disk_id in "$@"; do
    echo "  - /dev/disk/by-id/${disk_id}"
  done
}

print_device_resolutions() {
  local disk_id
  local device
  local resolved

  for disk_id in "$@"; do
    device="/dev/disk/by-id/${disk_id}"
    if [[ -e "$device" ]]; then
      resolved="$(readlink -f -- "$device" 2>/dev/null || true)"
      if [[ -n "$resolved" ]]; then
        echo "  - ${device} -> ${resolved}"
      else
        echo "  - ${device} -> present but resolution failed"
      fi
    else
      echo "  - ${device} -> missing"
    fi
  done
}

ensure_target_devices_exist() {
  local disk_id
  local device
  local missing=0

  for disk_id in "$@"; do
    device="/dev/disk/by-id/${disk_id}"
    if [[ ! -e "$device" ]]; then
      echo "❌ Target device path is missing: ${device}" >&2
      missing=1
    fi
  done

  if (( missing )); then
    exit 1
  fi
}

confirm_exact() {
  local prompt="$1"
  local expected="$2"
  local actual

  if [[ ! -e /dev/tty ]]; then
    fail "Interactive confirmation requires /dev/tty. Use --print-only for a non-destructive preview."
  fi

  if ! read -r -p "${prompt}" actual < /dev/tty; then
    fail "Failed to read confirmation."
  fi

  if [[ "$actual" != "$expected" ]]; then
    echo "❌ Confirmation mismatch." >&2
    echo "   Expected: ${expected}" >&2
    echo "   Actual:   ${actual}" >&2
    exit 1
  fi
}
