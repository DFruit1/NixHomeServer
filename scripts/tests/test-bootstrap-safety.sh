#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"
cd "$TESTS_REPO_ROOT"
ensure_tools bash jq nix rg
host="$(test_default_host)"
invalid_log="$(mktemp)"
snapshot_test_dir="$(mktemp -d)"
cleanup() { rm -f "$invalid_log"; rm -rf "$snapshot_test_dir"; }
trap cleanup EXIT

source scripts/helpers/kopia-managed-common.sh
source scripts/helpers/bootstrap-disk-safety-common.sh

if ! kopia_managed_requires_data_root_mount 0; then
  echo "❌ Managed Kopia mode did not retain its fail-closed data-root mount requirement."
  exit 1
fi
if kopia_managed_requires_data_root_mount 1; then
  echo "❌ Kopia disaster-recovery mode incorrectly requires the unavailable managed data-root mount."
  exit 1
fi
if kopia_managed_requires_data_root_mount invalid >/dev/null 2>&1; then
  echo "❌ Kopia mount policy accepted an invalid mode."
  exit 1
fi

same_fs_a="$snapshot_test_dir/same-fs-a"
same_fs_b="$snapshot_test_dir/same-fs-b"
: >"$same_fs_a"
: >"$same_fs_b"
if bootstrap_files_use_distinct_filesystems "$same_fs_a" "$same_fs_b"; then
  echo "❌ Two age-key paths on one filesystem were accepted as independent backups."
  exit 1
fi

disk_mock_bin="$snapshot_test_dir/disk-mock-bin"
mkdir -p "$disk_mock_bin"
cat >"$disk_mock_bin/findmnt" <<'EOF'
#!/usr/bin/env bash
printf '/dev/mock-part[/backup] ext4\n'
EOF
cat >"$disk_mock_bin/lsblk" <<'EOF'
#!/usr/bin/env bash
[[ "${NIXHOMESERVER_TEST_LSBLK_FAIL:-0}" != 1 ]] || exit 1
printf '/dev/mock-part part\n/dev/mock-disk disk\n'
EOF
cat >"$disk_mock_bin/readlink" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${*: -1}"
EOF
make_test_executable "$disk_mock_bin/findmnt" "$disk_mock_bin/lsblk" "$disk_mock_bin/readlink"
BOOTSTRAP_SAFETY_FINDMNT_BIN="$disk_mock_bin/findmnt"
BOOTSTRAP_SAFETY_LSBLK_BIN="$disk_mock_bin/lsblk"
BOOTSTRAP_SAFETY_READLINK_BIN="$disk_mock_bin/readlink"
export BOOTSTRAP_SAFETY_FINDMNT_BIN BOOTSTRAP_SAFETY_LSBLK_BIN BOOTSTRAP_SAFETY_READLINK_BIN
if ! bootstrap_backup_uses_selected_disk "$same_fs_b" /dev/mock-disk; then
  echo "❌ Age-key backup ancestry did not detect a selected whole disk beneath its partition."
  exit 1
fi
if bootstrap_backup_uses_selected_disk "$same_fs_b" /dev/other-disk; then
  echo "❌ Age-key backup ancestry falsely matched an unrelated selected disk."
  exit 1
fi
export NIXHOMESERVER_TEST_LSBLK_FAIL=1
backup_resolution_status=0
bootstrap_backup_uses_selected_disk "$same_fs_b" /dev/mock-disk \
  || backup_resolution_status=$?
unset NIXHOMESERVER_TEST_LSBLK_FAIL
if ((backup_resolution_status != 2)); then
  echo "❌ Age-key backup ancestry did not fail closed when block topology was unavailable."
  exit 1
fi
unset BOOTSTRAP_SAFETY_FINDMNT_BIN BOOTSTRAP_SAFETY_LSBLK_BIN BOOTSTRAP_SAFETY_READLINK_BIN

cat >"$disk_mock_bin/inventory-fail" <<'EOF'
#!/usr/bin/env bash
echo 'simulated inventory failure' >&2
exit 9
EOF
make_test_executable "$disk_mock_bin/inventory-fail"
export BOOTSTRAP_SAFETY_PVS_BIN="$disk_mock_bin/inventory-fail"
export BOOTSTRAP_SAFETY_LVS_BIN="$disk_mock_bin/inventory-fail"
export BOOTSTRAP_SAFETY_ZPOOL_BIN="$disk_mock_bin/inventory-fail"
lvm_query_status=0
bootstrap_query_lvm_pv_records >/dev/null 2>&1 || lvm_query_status=$?
lvm_lv_query_status=0
bootstrap_lvm_vg_is_fully_inactive fixture-vg >/dev/null 2>&1 || lvm_lv_query_status=$?
zpool_query_status=0
bootstrap_query_imported_zpool_paths >/dev/null 2>&1 || zpool_query_status=$?
unset BOOTSTRAP_SAFETY_PVS_BIN BOOTSTRAP_SAFETY_LVS_BIN BOOTSTRAP_SAFETY_ZPOOL_BIN
if ((lvm_query_status != 2 || lvm_lv_query_status != 2 || zpool_query_status != 2)); then
  echo "❌ LVM/ZFS inventory helpers did not fail closed when their tooling failed."
  exit 1
fi

cat >"$disk_mock_bin/pvs" <<'EOF'
#!/usr/bin/env bash
printf ' /dev/mock-pv | fixture-vg \n /dev/orphan-pv | \n'
EOF
cat >"$disk_mock_bin/lvs" <<'EOF'
#!/usr/bin/env bash
case "${NIXHOMESERVER_TEST_LV_STATE:-inactive}" in
  active) printf ' fixture-vg | active \n' ;;
  inactive) printf ' fixture-vg | inactive \n fixture-vg | inactive \n' ;;
  empty) ;;
  ambiguous) printf ' fixture-vg | unknown \n' ;;
  wrong-vg) printf ' other-vg | inactive \n' ;;
  fail) exit 9 ;;
esac
EOF
make_test_executable "$disk_mock_bin/pvs" "$disk_mock_bin/lvs"
export BOOTSTRAP_SAFETY_PVS_BIN="$disk_mock_bin/pvs"
export BOOTSTRAP_SAFETY_LVS_BIN="$disk_mock_bin/lvs"
if [[ "$(bootstrap_query_lvm_pv_records)" != $'/dev/mock-pv|fixture-vg\n/dev/orphan-pv|' ]]; then
  echo "❌ LVM PV inventory did not preserve volume-group ownership safely."
  exit 1
fi
for inactive_state in inactive empty; do
  export NIXHOMESERVER_TEST_LV_STATE="$inactive_state"
  if ! bootstrap_lvm_vg_is_fully_inactive fixture-vg; then
    echo "❌ LVM helper rejected a fully inactive test volume group (${inactive_state})."
    exit 1
  fi
done
export NIXHOMESERVER_TEST_LV_STATE=active
active_lvm_status=0
bootstrap_lvm_vg_is_fully_inactive fixture-vg || active_lvm_status=$?
if ((active_lvm_status != 1)); then
  echo "❌ LVM helper did not distinguish an active logical volume from an inventory failure."
  exit 1
fi
for invalid_state in ambiguous wrong-vg fail; do
  export NIXHOMESERVER_TEST_LV_STATE="$invalid_state"
  invalid_lvm_status=0
  bootstrap_lvm_vg_is_fully_inactive fixture-vg >/dev/null 2>&1 || invalid_lvm_status=$?
  if ((invalid_lvm_status != 2)); then
    echo "❌ LVM helper did not fail closed for ${invalid_state} logical-volume inventory."
    exit 1
  fi
done
unset BOOTSTRAP_SAFETY_PVS_BIN BOOTSTRAP_SAFETY_LVS_BIN NIXHOMESERVER_TEST_LV_STATE

bootstrap_json="$(nix eval --json --impure --expr "
  let
    f = builtins.getFlake (builtins.getEnv \"NIXHOMESERVER_FLAKE_REF_FOR_EVAL\");
    cfg = f.nixosConfigurations.${host}-bootstrap.config;
    devices = cfg.disko.devices;
  in {
    systemDevice = devices.disk.system.device;
    bootFormat = devices.disk.system.content.partitions.boot.content.format;
    rootSize = devices.disk.system.content.partitions.root.size;
    hostId = cfg.networking.hostId;
    forceImportRoot = cfg.boot.zfs.forceImportRoot;
    grubEnabled = cfg.boot.loader.grub.enable;
    removableEfi = cfg.boot.loader.grub.efiInstallAsRemovable;
  }
")"
jq -e '
  (.systemDevice | startswith("/dev/disk/by-id/"))
  and (.bootFormat == "vfat")
  and (.rootSize == "100%")
  and (.hostId | test("^[0-9a-fA-F]{8}$"))
  and (.forceImportRoot == false)
  and (.grubEnabled == true)
  and (.removableEfi == true)
' <<<"$bootstrap_json" >/dev/null || {
  echo "❌ Pinned bootstrap configuration is missing guarded disk or boot settings."
  jq . <<<"$bootstrap_json"
  exit 1
}

recovery_json="$(nix eval --json --impure --expr "
  let
    f = builtins.getFlake (builtins.getEnv \"NIXHOMESERVER_FLAKE_REF_FOR_EVAL\");
    cfg = f.nixosConfigurations.${host}-system-recovery.config;
  in {
    diskNames = builtins.attrNames cfg.disko.devices.disk;
    systemDevice = cfg.disko.devices.disk.system.device;
  }
")"
jq -e '
  .diskNames == ["system"]
  and (.systemDevice | startswith("/dev/disk/by-id/"))
' <<<"$recovery_json" >/dev/null || {
  echo "❌ System-disk recovery output includes a data-pool disk or an unsafe system device."
  jq . <<<"$recovery_json"
  exit 1
}

# Exercise the source-pin boundary without touching a disk. Use an accessible,
# immutable store directory as the mocked source result. A nested Nix evaluator
# may return a logical /nix/store path from its private chroot store, which is
# intentionally not accessible in the outer build namespace.
reviewed_plan="$(readlink -f "$(type -P nix)")"
snapshot_path="${reviewed_plan%/bin/nix}"
if [[ "$snapshot_path" != /nix/store/* || ! -d "$snapshot_path" ]]; then
  echo "❌ Source snapshot regression could not locate an immutable test directory."
  exit 1
fi
malicious_plan="$snapshot_test_dir/unreviewed-plan"
reviewed_marker="$snapshot_test_dir/reviewed-executed"
malicious_marker="$snapshot_test_dir/unreviewed-executed"
live_checkout_sentinel="$snapshot_test_dir/live-checkout"
mock_command_log="$snapshot_test_dir/mock-commands.log"
mock_bin="$snapshot_test_dir/bin"
mkdir -p "$mock_bin"
printf 'original\n' >"$live_checkout_sentinel"
cat >"$malicious_plan" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
: >"$NIXHOMESERVER_TEST_MALICIOUS_MARKER"
EOF
make_test_executable "$malicious_plan"
if [[ "$reviewed_plan" != /nix/store/* || ! -x "$reviewed_plan" ]]; then
  echo "❌ Source snapshot regression could not locate an immutable test executable."
  exit 1
fi

cat >"$mock_bin/nix" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-} ${2:-}" in
  "eval --impure")
    printf 'pin|%s\n' "$NIXHOMESERVER_BOOTSTRAP_SOURCE_REF" \
      >>"$NIXHOMESERVER_TEST_COMMAND_LOG"
    printf '%s' "$NIXHOMESERVER_TEST_SNAPSHOT_PATH"
    ;;
  "eval --json")
    printf 'eval|%s|%s\n' \
      "$NIXHOMESERVER_FLAKE_REF_FOR_EVAL" \
      "$NIXHOMESERVER_REPO_ROOT_FOR_EVAL" \
      >>"$NIXHOMESERVER_TEST_COMMAND_LOG"
    printf 'mutated-after-snapshot\n' >"$NIXHOMESERVER_TEST_LIVE_SENTINEL"
    printf '{"hostname":"fixture","storageProfile":"single-disk","mainDisk":"fixture-disk"}\n'
    ;;
  "build --no-link")
    target="${*: -1}"
    printf 'build|%s\n' "$target" >>"$NIXHOMESERVER_TEST_COMMAND_LOG"
    if [[ "$target" == "$NIXHOMESERVER_TEST_EXPECTED_TARGET" ]]; then
      printf '%s\n' "$NIXHOMESERVER_TEST_REVIEWED_PLAN"
    else
      printf '%s\n' "$NIXHOMESERVER_TEST_MALICIOUS_PLAN"
    fi
    ;;
  *)
    echo "unexpected mocked nix invocation: $*" >&2
    exit 1
    ;;
esac
EOF
make_test_executable "$mock_bin/nix"

original_path="$PATH"
original_eval_ref="$NIXHOMESERVER_FLAKE_REF_FOR_EVAL"
original_eval_root="$NIXHOMESERVER_REPO_ROOT_FOR_EVAL"
export PATH="$mock_bin:$PATH"
export NIXHOMESERVER_TEST_COMMAND_LOG="$mock_command_log"
export NIXHOMESERVER_TEST_SNAPSHOT_PATH="$snapshot_path"
export NIXHOMESERVER_TEST_LIVE_SENTINEL="$live_checkout_sentinel"
export NIXHOMESERVER_TEST_REVIEWED_PLAN="$reviewed_plan"
export NIXHOMESERVER_TEST_MALICIOUS_PLAN="$malicious_plan"
export NIXHOMESERVER_TEST_EXPECTED_TARGET="path:${snapshot_path}#nixosConfigurations.fixture-bootstrap.config.system.build.diskoScript"
source scripts/helpers/bootstrap-source-snapshot.sh
pin_bootstrap_source_snapshot "git+file://$snapshot_test_dir/live-checkout"
settings_probe="$(nix eval --json --impure --expr 'builtins.abort "mock only"')"
jq -e '.hostname == "fixture" and .mainDisk == "fixture-disk"' \
  <<<"$settings_probe" >/dev/null
if [[ "$(<"$live_checkout_sentinel")" != "mutated-after-snapshot" ]]; then
  echo "❌ Source snapshot regression did not mutate the live checkout between evaluation and build."
  exit 1
fi
if NIXHOMESERVER_FLAKE_REF_FOR_EVAL="git+file://$snapshot_test_dir/live-checkout" \
  build_pinned_disko_plan fixture >/dev/null 2>&1; then
  echo "❌ Disk bootstrap did not refuse a changed evaluation source after pinning."
  exit 1
fi
disko_plan_probe="$(build_pinned_disko_plan fixture)"
validate_pinned_disko_plan "$disko_plan_probe"
export NIXHOMESERVER_TEST_MALICIOUS_MARKER="$malicious_marker"
"$disko_plan_probe" --version >/dev/null
: >"$reviewed_marker"
if validate_pinned_disko_plan "$malicious_plan" >/dev/null 2>&1; then
  echo "❌ Disk bootstrap accepted an executable outside its immutable store snapshot."
  exit 1
fi
export PATH="$original_path"
export NIXHOMESERVER_FLAKE_REF_FOR_EVAL="$original_eval_ref"
export NIXHOMESERVER_REPO_ROOT_FOR_EVAL="$original_eval_root"
unset NIXHOMESERVER_PINNED_SOURCE_PATH NIXHOMESERVER_PINNED_FLAKE_REF

if [[ ! -e "$reviewed_marker" || -e "$malicious_marker" ]]; then
  echo "❌ Source mutation caused an unreviewed Disko executable to run."
  exit 1
fi
if ! rg -Fxq "eval|path:${snapshot_path}|${snapshot_path}" "$mock_command_log" \
  || ! rg -Fxq "build|$NIXHOMESERVER_TEST_EXPECTED_TARGET" "$mock_command_log" \
  || rg -Fq "build|git+file://" "$mock_command_log"; then
  echo "❌ Settings and Disko build did not consume the same pinned source snapshot."
  cat "$mock_command_log"
  exit 1
fi

rollback_host_json="$(nix eval --impure --json --expr '
  let
    f = builtins.getFlake (builtins.getEnv "NIXHOMESERVER_FLAKE_REF_FOR_EVAL");
    lib = f.inputs.nixpkgs.lib;
    base = import ./vars.nix { inherit lib; };
    vars = base // {
      storage = base.storage // { enableRootRollback = true; };
      enableRootRollback = true;
    };
    pkgs = f.inputs.nixpkgs.legacyPackages.${base.hostPlatform};
    packages = import ./flake/packages.nix {
      inherit lib pkgs;
      crane = f.inputs.crane;
    };
    system = import ./flake/system.nix {
      inputs = f.inputs;
      inherit lib vars pkgs;
      system = base.hostPlatform;
      appPackages = packages.appPackages;
    };
    host = system.nixosConfigurations.${base.hostname};
    bootstrap = system.bootstrapConfigurations."${base.hostname}-bootstrap";
  in {
    hostDrv = host.config.system.build.toplevel.drvPath;
    diskoDrv = bootstrap.config.system.build.diskoScript.drvPath;
    rollbackBefore = host.config.boot.initrd.systemd.services.nixhomeserver-root-rollback.before;
    legacyPostResumeEmpty = host.config.boot.initrd.postResumeCommands == "";
  }
')"
jq -e '
  (.hostDrv | type == "string" and length > 0)
  and (.diskoDrv | type == "string" and length > 0)
  and (.rollbackBefore | index("sysroot.mount") != null)
  and (.legacyPostResumeEmpty == true)
' <<<"$rollback_host_json" >/dev/null || {
  echo "❌ A full rollback-enabled host and Disko configuration did not evaluate safely."
  jq . <<<"$rollback_host_json"
  exit 1
}

invalid_rollback_name_expr='let
  f = builtins.getFlake (builtins.getEnv "NIXHOMESERVER_FLAKE_REF_FOR_EVAL");
  hostName = builtins.getEnv "NIXHOMESERVER_TEST_HOST";
  host = (builtins.getAttr hostName f.nixosConfigurations).extendModules {
    modules = [{ repo.impermanence.rootSubvolume = "different-root"; }];
  };
in host.config.system.build.toplevel.drvPath'
if NIXHOMESERVER_TEST_HOST="$host" nix eval --impure --raw --expr "$invalid_rollback_name_expr" >"$invalid_log" 2>&1; then
  echo "❌ Runtime rollback accepted a subvolume name that Disko never creates."
  exit 1
fi
if ! rg -q 'rootSubvolume.*read-only|read-only.*rootSubvolume' "$invalid_log"; then
  echo "❌ Invalid rollback subvolume override failed without the expected read-only option error."
  cat "$invalid_log"
  exit 1
fi
nix eval --raw ".#nixosConfigurations.${host}-bootstrap.config.system.build.toplevel.drvPath" >/dev/null
if [[ "${NIXHOMESERVER_SKIP_NESTED_BUILDS:-0}" != "1" ]]; then
  nix build --no-link ".#nixosConfigurations.${host}-bootstrap.config.system.build.diskoScript"
fi

invalid_topology_expr='let
  f = builtins.getFlake (builtins.getEnv "NIXHOMESERVER_FLAKE_REF_FOR_EVAL");
  lib = f.inputs.nixpkgs.lib;
  base = import ./vars.nix { inherit lib; };
  vars = base // {
    mainDisk = "duplicate-disk";
    enableZfsDataPool = true;
    zfsDataPool = base.zfsDataPool // {
      mirrorPairs = [[ "duplicate-disk" "second-disk" ]];
    };
    zfsDataPoolDiskIds = [ "duplicate-disk" "second-disk" ];
  };
  cfg = lib.nixosSystem {
    modules = [
      { nixpkgs.hostPlatform = base.hostPlatform; }
      f.inputs.disko.nixosModules.disko
      ./bootstrap/disko-system.nix
      ./bootstrap/disko-data.nix
    ];
    specialArgs = { inherit vars; };
  };
in cfg.config.system.build.diskoScript.drvPath'

if nix eval --impure --raw --expr "$invalid_topology_expr" >"$invalid_log" 2>&1; then
  echo "❌ Disk bootstrap accepted the same disk as system and ZFS data storage."
  exit 1
fi
if ! rg -Fq 'storage.systemDisk must not also appear' "$invalid_log"; then
  echo "❌ Invalid topology failed without the expected safety assertion."
  cat "$invalid_log"
  exit 1
fi

invalid_data_layout_expr='let
  f = builtins.getFlake (builtins.getEnv "NIXHOMESERVER_FLAKE_REF_FOR_EVAL");
  lib = f.inputs.nixpkgs.lib;
  base = import ./vars.nix { inherit lib; };
  vars = base // {
    enableZfsDataPool = true;
    zfsDataPool = base.zfsDataPool // {
      mountPoint = "/persist";
      datasets = [ "users" "shared" "extra" ];
    };
  };
  cfg = lib.nixosSystem {
    modules = [
      { nixpkgs.hostPlatform = base.hostPlatform; }
      f.inputs.disko.nixosModules.disko
      ./bootstrap/disko-system.nix
      ./bootstrap/disko-data.nix
    ];
    specialArgs = { inherit vars; };
  };
in cfg.config.system.build.diskoScript.drvPath'

if nix eval --impure --raw --expr "$invalid_data_layout_expr" >"$invalid_log" 2>&1; then
  echo "❌ Disk bootstrap accepted a non-canonical data mount and dataset set."
  exit 1
fi
if ! rg -q 'storage[.]dataPool[.](mountPoint|datasets)' "$invalid_log"; then
  echo "❌ Invalid data layout failed without the expected safety assertion."
  cat "$invalid_log"
  exit 1
fi

rollback_layout_json="$(nix eval --impure --json --expr '
  let
    f = builtins.getFlake (builtins.getEnv "NIXHOMESERVER_FLAKE_REF_FOR_EVAL");
    lib = f.inputs.nixpkgs.lib;
    base = import ./vars.nix { inherit lib; };
    vars = base // { enableRootRollback = true; };
    module = import ./bootstrap/disko-system.nix { inherit lib vars; };
    root = module.disko.devices.disk.system.content.partitions.root.content;
  in {
    rootMountpoint = root.subvolumes."/root".mountpoint;
    blankExists = builtins.hasAttr "/root-blank" root.subvolumes;
    protectsBlank = lib.hasInfix "btrfs property set -ts" root.postCreateHook;
  }
')"
jq -e '
  .rootMountpoint == "/"
  and .blankExists == true
  and .protectsBlank == true
' <<<"$rollback_layout_json" >/dev/null || {
  echo "❌ Root rollback bootstrap does not create a writable root and read-only blank template."
  jq . <<<"$rollback_layout_json"
  exit 1
}

ext4_layout_json="$(nix eval --impure --json --expr '
  let
    f = builtins.getFlake (builtins.getEnv "NIXHOMESERVER_FLAKE_REF_FOR_EVAL");
    lib = f.inputs.nixpkgs.lib;
    base = import ./vars.nix { inherit lib; };
    vars = base // {
      storageProfile = "single-disk-ext4";
      enableRootRollback = false;
    };
    module = import ./bootstrap/disko-system.nix { inherit lib vars; };
    root = module.disko.devices.disk.system.content.partitions.root.content;
  in {
    inherit (root) format mountpoint postCreateHook;
  }
')"
jq -e '
  .format == "ext4"
  and .mountpoint == "/"
  and (.postCreateHook | contains("mount \"$device\" \"$root_mount\""))
  and (.postCreateHook | contains("\"$root_mount/persist\" \"$root_mount/nix\""))
  and (.postCreateHook | contains("umount \"$root_mount\""))
' <<<"$ext4_layout_json" >/dev/null || {
  echo "❌ The ext4 bootstrap does not provision /persist and /nix on the new root filesystem."
  jq . <<<"$ext4_layout_json"
  exit 1
}

require_fixed bootstrap/apply-disko.sh '--confirm-host' \
  "Destructive bootstrap must require an exact hostname confirmation."
require_fixed bootstrap/apply-disko.sh '--confirm-disk' \
  "Destructive bootstrap must confirm every selected disk individually."
require_fixed bootstrap/apply-disko.sh 'lsblk -nrpo MOUNTPOINTS' \
  "Destructive bootstrap must reject mounted disks and their mounted partitions."
require_fixed bootstrap/apply-disko.sh 'canonical_disks[$canonical]' \
  "Destructive bootstrap must reject multiple by-id aliases for one physical disk."
require_fixed scripts/helpers/bootstrap-source-snapshot.sh 'nixosConfigurations.${host}${configuration_suffix}.config.system.build.diskoScript' \
  "Destructive bootstrap must build the pinned disko plan before execution."
require_fixed bootstrap/apply-disko.sh 'pin_bootstrap_source_snapshot "$NIXHOMESERVER_FLAKE_REF_FOR_EVAL"' \
  "Destructive bootstrap must snapshot its source before evaluating host and disk settings."
require_fixed bootstrap/apply-disko.sh 'echo "  source:     $pinned_source_path"' \
  "Destructive bootstrap must show the exact immutable source used for its plan."
require_fixed scripts/helpers/bootstrap-source-snapshot.sh '"${NIXHOMESERVER_PINNED_FLAKE_REF}#nixosConfigurations.${host}${configuration_suffix}.config.system.build.diskoScript"' \
  "Destructive bootstrap must build from the exact source used for settings evaluation."
forbid_match bootstrap/apply-disko.sh '"\.#nixosConfigurations' \
  "Destructive bootstrap must not build from a mutable current-directory flake."
require_fixed bootstrap/apply-disko.sh 'exec "$disko_script"' \
  "Destructive bootstrap must execute the exact immutable Disko plan that was reviewed and built."
forbid_match bootstrap/apply-disko.sh 'disko --mode disko --flake' \
  "Destructive bootstrap must not re-evaluate a mutable flake after disk confirmation."
require_fixed bootstrap/apply-disko.sh 'configured_canonical_by_id[$disk_id]' \
  "Destructive bootstrap must recheck confirmed disk identity after building the plan."
require_fixed bootstrap/apply-disko.sh 'lsblk -dn -o MAJ:MIN,SIZE,MODEL,SERIAL,WWN' \
  "Destructive bootstrap must show stable physical-disk identity fields before confirmation."
require_fixed bootstrap/apply-disko.sh 'configured_identity_by_id[$disk_id]' \
  "Destructive bootstrap must recheck the full confirmed hardware fingerprint after building its plan."
require_fixed scripts/helpers/bootstrap-source-snapshot.sh 'config.system.build.toplevel' \
  "Destructive bootstrap must realize the full pinned target closure before Disko."
require_fixed bootstrap/apply-disko.sh 'validate_pinned_target_system "$target_system"' \
  "Destructive bootstrap must validate the realized immutable target closure before erasing disks."
require_fixed bootstrap/apply-disko.sh '--age-key-backup' \
  "Destructive bootstrap must require a verified second copy of the private age identity."
require_fixed scripts/helpers/bootstrap-disk-safety-common.sh '"$stat_bin" -c %d' \
  "Age-key copies must use distinct filesystem device IDs, not merely distinct mount paths."
require_fixed bootstrap/apply-disko.sh 'bootstrap_backup_uses_selected_disk "$age_key_backup"' \
  "Age-key backup media must be proven disjoint from every disk selected for erasure."
require_fixed bootstrap/apply-disko.sh 'verify_age_recovery_copies "pre-build validation"' \
  "Age-key recovery copies must be validated before long pre-wipe builds."
require_fixed bootstrap/apply-disko.sh 'verify_age_recovery_copies "post-build recheck"' \
  "Age-key recovery copies must be fully revalidated immediately before Disko execution."
require_fixed bootstrap/apply-disko.sh 'swapon --noheadings --raw --show=NAME' \
  "Destructive bootstrap must reject selected disks that provide active swap."
forbid_match bootstrap/apply-disko.sh 'swapon.*\|\| true' \
  "Destructive bootstrap must not turn a failed active-swap query into an empty result."
require_fixed bootstrap/apply-disko.sh '/holders' \
  "Destructive bootstrap must reject active device-mapper, LVM, and MD holders."
require_fixed scripts/helpers/bootstrap-disk-safety-common.sh 'status -P "$pool"' \
  "Destructive bootstrap must reject members of an imported ZFS pool."
require_fixed scripts/helpers/bootstrap-disk-safety-common.sh '"$pvs_bin" --readonly' \
  "Destructive bootstrap must inventory disks registered as LVM physical volumes."
require_fixed bootstrap/apply-disko.sh '--allow-inactive-lvm-pv' \
  "Reusing an inactive LVM PV must require an explicit exact-disk override rather than an unguarded manual wipe."
require_fixed bootstrap/apply-disko.sh 'need age-keygen arping awk blockdev find findmnt grep ip jq lsblk lvs mktemp nix pvs' \
  "Destructive bootstrap must fail closed when LVM inspection tooling is unavailable."
require_fixed bootstrap/apply-disko.sh 'bootstrap_lvm_vg_is_fully_inactive "$pv_vg"' \
  "An LVM PV override must prove every LV in the selected PV volume group is inactive."
require_fixed scripts/helpers/bootstrap-disk-safety-common.sh '-o vg_name,lv_active' \
  "LVM override safety must inspect logical-volume activation state, including other PVs in the same group."
require_fixed bootstrap/apply-disko.sh 'wipefs zpool' \
  "Destructive bootstrap must fail closed when ZFS inspection tooling is unavailable."
forbid_match bootstrap/apply-disko.sh '(pvs|zpool status).*\|\| true' \
  "Destructive bootstrap must not turn a failed LVM/ZFS inventory query into an empty result."
require_fixed bootstrap/apply-disko.sh 'arping -D' \
  "Destructive bootstrap must perform a final duplicate-LAN-address probe before wiping disks."
require_fixed bootstrap/apply-disko.sh 'Probe even when the installer already owns the configured address' \
  "Duplicate-address detection must not be skipped merely because the installer already owns the configured IP."
require_fixed bootstrap/apply-disko.sh 'arping -q -c 2' \
  "Destructive bootstrap must prove the configured LAN gateway is link-layer reachable."
require_fixed bootstrap/apply-disko.sh '--system-disk-only' \
  "System-SSD recovery must be an explicit guarded mode."
require_fixed bootstrap/apply-disko.sh 'disko_configuration_suffix="-system-recovery"' \
  "System-SSD recovery must use the Disko output that excludes all data-pool devices."
require_fixed bootstrap/apply-disko.sh 'Cannot prove preserved-pool disk identity because this configured member is absent' \
  "System-SSD recovery must fail when any preserved pool member cannot be resolved locally."
require_fixed bootstrap/apply-disko.sh 'aliases preserved data-pool member' \
  "System-SSD recovery must reject a system by-id alias that resolves to a preserved pool member."
require_fixed bootstrap/apply-disko.sh 'preserved_canonical_by_id[$disk_id]' \
  "System-SSD recovery must retain and recheck each preserved member's canonical device identity."
require_fixed bootstrap/apply-disko.sh 'preserved_identity_by_id[$disk_id]' \
  "System-SSD recovery must retain and recheck each preserved member's hardware fingerprint."
require_fixed bootstrap/apply-disko.sh 'verify_installer_network "initial pre-build validation"' \
  "Destructive bootstrap must validate the configured LAN before long builds."
require_fixed bootstrap/apply-disko.sh 'verify_installer_network "post-build final validation"' \
  "Destructive bootstrap must repeat gateway and duplicate-address checks after long builds."
final_network_line="$(
  rg -n -F 'verify_installer_network "post-build final validation"' bootstrap/apply-disko.sh \
    | head -n 1 | cut -d: -f1
)"
final_disk_line="$(
  rg -n -F 'Confirmed disk disappeared while building the Disko plan' bootstrap/apply-disko.sh \
    | head -n 1 | cut -d: -f1
)"
final_age_line="$(
  rg -n -F 'verify_age_recovery_copies "post-build recheck"' bootstrap/apply-disko.sh \
    | head -n 1 | cut -d: -f1
)"
final_exec_line="$(
  rg -n -F 'exec "$disko_script"' bootstrap/apply-disko.sh \
    | head -n 1 | cut -d: -f1
)"
if [[ -z "$final_network_line" || -z "$final_disk_line" \
  || -z "$final_age_line" || -z "$final_exec_line" ]] \
  || ((final_network_line >= final_disk_line \
    || final_disk_line >= final_age_line \
    || final_age_line >= final_exec_line)); then
  echo "❌ Final network, disk, key, and immutable Disko checks are not ordered immediately after the builds."
  exit 1
fi
require_fixed scripts/admin/validate-config-readiness.sh 'installer/target architecture' \
  "Target-hardware readiness must compare the actual and configured architectures."
require_fixed scripts/admin/validate-config-readiness.sh '--allow-host-platform-mismatch' \
  "Architecture mismatch bypass must be an explicit expert override."
require_fixed flake/system.nix '[ "generated" "existing-server" ]' \
  "Generated target hardware configuration must be a supported hardware profile."
require_fixed vars.example.nix 'hardwareProfile = "generated"' \
  "Fresh-host defaults must select the generated target hardware configuration."
require_fixed documentation/quickstart.md 'nixos-generate-config --no-filesystems --show-hardware-config' \
  "Fresh-host hardware generation must happen before wipe without duplicating repository-owned filesystems."
require_fixed modules/Core_Modules/validation/default.nix 'conflictingDataFileSystems == [ ]' \
  "Host evaluation must reject generated filesystems beneath the managed data root."
require_fixed scripts/admin/validate-config-readiness.sh 'config.system.build.toplevel.drvPath' \
  "Readiness validation must force the complete NixOS closure and its assertions."
require_fixed scripts/admin/validate-config-readiness.sh 'git config --local --get user.name' \
  "Fresh-target readiness must verify repository-local Git author configuration."
require_fixed scripts/admin/validate-config-readiness.sh 'repository-local Git author identity is incomplete' \
  "Missing installer Git identity must fail with an actionable diagnostic."
require_fixed scripts/admin/validate-config-readiness.sh 'git status --porcelain=v1 --untracked-files=all' \
  "Fresh-target readiness must inventory staged, unstaged, and untracked source changes."
require_fixed scripts/admin/validate-config-readiness.sh 'repository worktree is not clean' \
  "Fresh-target readiness must block destructive bootstrap from an uncommitted source tree."
require_fixed documentation/restore-and-recovery.md 'git config --local user.name "$(jq -er' \
  "System-SSD recovery must establish repository-local Git author identity before committing the replacement disk."
require_fixed documentation/restore-and-recovery.md 'test -z "$(git status --short)"' \
  "System-SSD recovery must prove its source checkout is clean around the recovery commit."
require_fixed documentation/restore-and-recovery.md 'pool_name="$(jq -er' \
  "Recovery guidance must derive the configured pool name from evaluated settings."
require_fixed documentation/restore-and-recovery.md 'data_root="$(jq -er' \
  "Recovery guidance must derive the configured data root from evaluated settings."
require_fixed documentation/restore-and-recovery.md 'backup_root="$(jq -er' \
  "Recovery guidance must derive the configured backup root from evaluated settings."
forbid_match documentation/restore-and-recovery.md 'zpool (status|replace|scrub).* data([[:space:]]|$)' \
  "Recovery commands must not hard-code the default ZFS pool name."
for guidance_file in README.md documentation/quickstart.md; do
  local_name_guidance_count="$(rg -Fc 'git config --local user.name' "$guidance_file" || true)"
  local_email_guidance_count="$(rg -Fc 'git config --local user.email' "$guidance_file" || true)"
  if (( ${local_name_guidance_count:-0} < 2 )) \
    || (( ${local_email_guidance_count:-0} < 2 )); then
    echo "❌ $guidance_file must configure repository-local Git identity on both the workstation and fresh installer."
    exit 1
  fi
done
require_fixed scripts/admin/validate-config-readiness.sh 'plaintext_staging_is_empty "$repo_root/secrets/unencrypted"' \
  "Readiness validation must block copying a repository with staged plaintext secrets."
require_fixed modules/Core_Modules/impermanence/default.nix "rotation_second=\"''\${rotation_name%%.*}\"" \
  "Root rollback retention must use the generated rotation timestamp rather than an old live-root mtime."
require_fixed modules/Core_Modules/impermanence/default.nix '/bin/mount -t btrfs' \
  "Root rollback must use the mount binary already included in the systemd initrd."
rollback_script_source="$(
  sed -n "/^  rollbackScript = ''\$/,/^  '';\$/p" \
    modules/Core_Modules/impermanence/default.nix
)"
if rg -q 'pkgs[.](util-linux|findutils).*/bin/(mount|umount|find)' <<<"$rollback_script_source"; then
  echo "❌ Root rollback must not reference package paths omitted from the initrd closure."
  exit 1
fi

for portable_test in \
  scripts/tests/test-runtime-reliability.sh \
  scripts/tests/test-platform-storage-profiles.sh \
  scripts/tests/module-removal-matrix.nix; do
  if rg -q 'nixosConfigurations[.]server|nixhomeserverSettings[.]server|sydneybasiniot[.]org' "$portable_test"; then
    echo "❌ ${portable_test} contains deployment-specific host or domain assumptions."
    exit 1
  fi
done

echo "✅ Pinned disk layout, destructive guard, topology assertion, hardware profile, and portability tests passed."
