#!/usr/bin/env bash

set -euo pipefail

# Test double for df(1) used by test-storage-capacity-check.sh. The usage table
# comes from STORAGE_CAPACITY_DF_TABLE as one "<path> <device> <total> <used>
# <available>" row per filesystem. Paths without a row fail like an unmounted
# filesystem would.

table="${STORAGE_CAPACITY_DF_TABLE:?STORAGE_CAPACITY_DF_TABLE is required}"
target="${!#}"

while read -r path device total used available; do
  [[ -n "$path" ]] || continue
  if [[ "$path" == "$target" ]]; then
    [[ "$total" =~ ^[0-9]+$ && "$used" =~ ^[0-9]+$ && "$available" =~ ^[0-9]+$ ]] || exit 1
    percent=$(( used * 100 / total ))
    printf 'Filesystem 1B-blocks Used Available Capacity Mounted on\n'
    printf '%s %s %s %s %s%% %s\n' "$device" "$total" "$used" "$available" "$percent" "$target"
    exit 0
  fi
done <<<"$table"

exit 1
