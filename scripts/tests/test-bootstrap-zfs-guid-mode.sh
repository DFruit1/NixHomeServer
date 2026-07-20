#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"
cd "$TESTS_REPO_ROOT"
ensure_tools bash cut head rg

source scripts/helpers/bootstrap-disk-safety-common.sh

test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT
guard_log="$test_dir/guard.log"

if bootstrap_validate_zfs_guid_for_disko_mode \
  zfs-mirror 0 1 12345678901234567890 >"$guard_log" 2>&1; then
  echo "❌ Full blank-disk ZFS bootstrap accepted an existing pool GUID pin."
  exit 1
fi
if ! rg -Fq 'Disko creates a new pool GUID' "$guard_log" \
  || ! rg -Fq 'storage.dataPool.expectedGuid = null' "$guard_log" \
  || ! rg -Fq 'commit that bootstrap revision' "$guard_log"; then
  echo "❌ Full blank-disk GUID refusal did not explain the required null, committed bootstrap revision."
  cat "$guard_log"
  exit 1
fi
if ! bootstrap_validate_zfs_guid_for_disko_mode zfs-mirror 0 0 ""; then
  echo "❌ Full blank-disk ZFS bootstrap rejected an intentionally unpinned new pool."
  exit 1
fi

if ! bootstrap_validate_zfs_guid_for_disko_mode \
  zfs-mirror 1 1 12345678901234567890; then
  echo "❌ System-disk-only recovery rejected the pinned GUID of its preserved pool."
  exit 1
fi
if bootstrap_validate_zfs_guid_for_disko_mode \
  zfs-mirror 1 0 "" >"$guard_log" 2>&1; then
  echo "❌ System-disk-only recovery accepted an unpinned preserved pool."
  exit 1
fi
if ! rg -Fq -- '--system-disk-only requires a committed non-null storage.dataPool.expectedGuid' \
  "$guard_log"; then
  echo "❌ Unpinned system-disk recovery failed without actionable GUID guidance."
  cat "$guard_log"
  exit 1
fi
for malformed_case in '1 not-a-guid' '2 12345'; do
  read -r guid_state guid_value <<<"$malformed_case"
  if bootstrap_validate_zfs_guid_for_disko_mode \
    zfs-mirror 1 "$guid_state" "$guid_value" >"$guard_log" 2>&1; then
    echo "❌ System-disk-only recovery accepted malformed expectedGuid state ${malformed_case}."
    exit 1
  fi
done
if ! bootstrap_validate_zfs_guid_for_disko_mode single-disk-ext4 0 0 ""; then
  echo "❌ ZFS-specific GUID policy incorrectly rejected the ext4 bootstrap profile."
  exit 1
fi

require_fixed bootstrap/apply-disko.sh 'bootstrap_validate_zfs_guid_for_disko_mode' \
  "Disk bootstrap must enforce the new-pool versus preserved-pool GUID transition."
require_fixed bootstrap/apply-disko.sh 'preserved data pool: ${data_pool_name} (pinned GUID ${expected_data_pool_guid})' \
  "System-SSD recovery must display the pinned identity of the pool it preserves."

guid_guard_call_line="$(
  rg -n -F 'if ! bootstrap_validate_zfs_guid_for_disko_mode' bootstrap/apply-disko.sh \
    | head -n 1 \
    | cut -d: -f1
)"
target_build_line="$(
  rg -n -F 'target_system="$(build_pinned_target_system "$host")"' bootstrap/apply-disko.sh \
    | head -n 1 \
    | cut -d: -f1
)"
disko_exec_line="$(
  rg -n -F 'exec "$disko_script"' bootstrap/apply-disko.sh \
    | head -n 1 \
    | cut -d: -f1
)"
if [[ -z "$guid_guard_call_line" || -z "$target_build_line" || -z "$disko_exec_line" ]] \
  || ((guid_guard_call_line >= target_build_line || guid_guard_call_line >= disko_exec_line)); then
  echo "❌ ZFS expected-GUID mode guard does not run before every build and destructive Disko execution."
  exit 1
fi

require_fixed documentation/quickstart.md 'exact committed bootstrap' \
  "Fresh-host guidance must use the committed bootstrap revision for the pool-identity transition."
require_fixed documentation/quickstart.md '`storage.dataPool.expectedGuid = null`' \
  "Fresh-host guidance must explain the committed null GUID transition before creating a pool."
require_fixed documentation/restore-and-recovery.md 'must contain a non-null numeric' \
  "System-disk recovery guidance must require the preserved pool's pinned GUID."

for guidance_file in documentation/quickstart.md README.md; do
  if [[ "$guidance_file" == documentation/quickstart.md ]]; then
    require_fixed "$guidance_file" 'Run this first check without `--expected-guid`' \
      "${guidance_file} must describe topology-only verification for the newly created pool."
  else
    require_fixed "$guidance_file" 'Run the identity helper without `--expected-guid`' \
      "${guidance_file} must describe topology-only verification for the newly created pool."
  fi
  require_fixed "$guidance_file" 'new_pool_guid="$(sudo zpool get -H -o value guid' \
    "${guidance_file} must capture the GUID only after pool topology verification."
  require_fixed "$guidance_file" 'git commit -m "Pin newly created ZFS pool identity"' \
    "${guidance_file} must commit the post-Disko GUID pin before installation."
  require_fixed "$guidance_file" 'safe.directory=/mnt/persist/etc/nixos' \
    "${guidance_file} must make root-side Git verification safe for the installer-owned checkout."
  require_fixed "$guidance_file" '-C /mnt/persist/etc/nixos rev-parse HEAD)" = "$install_revision"' \
    "${guidance_file} must prove the seeded installation uses the selected post-Disko revision."

  verifier_line="$(
    rg -n -F 'sudo scripts/helpers/verify-zfs-pool-identity.sh' "$guidance_file" \
      | head -n 1 \
      | cut -d: -f1
  )"
  pin_commit_line="$(
    rg -n -F 'git commit -m "Pin newly created ZFS pool identity"' "$guidance_file" \
      | head -n 1 \
      | cut -d: -f1
  )"
  seed_line="$(
    rg -n -F 'scripts/admin/seed-install-repository.sh --target /mnt/persist/etc/nixos' "$guidance_file" \
      | head -n 1 \
      | cut -d: -f1
  )"
  install_line="$(
    rg -n -F 'nixos-install --flake /mnt/etc/nixos#<vars.hostname>' "$guidance_file" \
      | head -n 1 \
      | cut -d: -f1
  )"
  if [[ -z "$verifier_line" || -z "$pin_commit_line" || -z "$seed_line" || -z "$install_line" ]] \
    || ((verifier_line >= pin_commit_line \
      || pin_commit_line >= seed_line \
      || seed_line >= install_line)); then
    echo "❌ ${guidance_file} does not verify, pin, seed, and install the new ZFS identity in that order."
    exit 1
  fi
done

echo "✅ Blank-pool creation and pinned-pool system recovery GUID modes are guarded."
