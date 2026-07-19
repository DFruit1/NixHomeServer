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
require_fixed scripts/helpers/bootstrap-source-snapshot.sh 'nixosConfigurations.${host}-bootstrap.config.system.build.diskoScript' \
  "Destructive bootstrap must build the pinned disko plan before execution."
require_fixed bootstrap/apply-disko.sh 'pin_bootstrap_source_snapshot "$NIXHOMESERVER_FLAKE_REF_FOR_EVAL"' \
  "Destructive bootstrap must snapshot its source before evaluating host and disk settings."
require_fixed bootstrap/apply-disko.sh 'echo "  source:     $pinned_source_path"' \
  "Destructive bootstrap must show the exact immutable source used for its plan."
require_fixed scripts/helpers/bootstrap-source-snapshot.sh '"${NIXHOMESERVER_PINNED_FLAKE_REF}#nixosConfigurations.${host}-bootstrap.config.system.build.diskoScript"' \
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
require_fixed flake/system.nix '[ "generated" "existing-server" ]' \
  "Generated target hardware configuration must be a supported hardware profile."
require_fixed vars.example.nix 'hardwareProfile = "generated"' \
  "Fresh-host defaults must select the generated target hardware configuration."
require_fixed documentation/quickstart.md 'nixos-generate-config --root /mnt --no-filesystems --show-hardware-config' \
  "Fresh-host hardware generation must not duplicate repository-owned filesystems."
require_fixed modules/Core_Modules/validation/default.nix 'conflictingDataFileSystems == [ ]' \
  "Host evaluation must reject generated filesystems beneath the managed data root."
require_fixed scripts/admin/validate-config-readiness.sh 'config.system.build.toplevel.drvPath' \
  "Readiness validation must force the complete NixOS closure and its assertions."
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
