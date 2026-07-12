#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"

cd "$TESTS_REPO_ROOT"

ensure_tools bash jq nix rg

current_profile_json="$(nix eval --impure --json --expr '
let
  f = builtins.getFlake (toString ./.);
  lib = f.inputs.nixpkgs.lib;
  cfg = f.nixosConfigurations.server.config;
  vars = f.lib.nixhomeserverSettings.server;
in {
  inherit (vars) hostPlatform storageProfile enableZfsDataPool dataRootIsMountPoint;
  rootFsType = cfg.fileSystems."/".fsType;
  hasNixFs = builtins.hasAttr "/nix" cfg.fileSystems;
  hasPersistFs = builtins.hasAttr "/persist" cfg.fileSystems;
  smartdWants = cfg.systemd.services.smartd.wants or [];
  beszelExtraFilesystems = cfg.systemd.services.beszel-agent.environment.EXTRA_FILESYSTEMS;
}')"

jq -e '
  (.hostPlatform == "x86_64-linux")
  and (.storageProfile == "zfs-mirror")
  and (.rootFsType == "btrfs")
  and (.hasNixFs == true)
  and (.hasPersistFs == true)
  and (.enableZfsDataPool == true)
  and (.dataRootIsMountPoint == true)
  and (.smartdWants | index("zfs.target") != null)
  and (.beszelExtraFilesystems | contains("/mnt/data__DataPool"))
' <<<"$current_profile_json" >/dev/null || {
  echo "❌ Current x86/ZFS profile changed unexpectedly."
  jq . <<<"$current_profile_json"
  exit 1
}

synthetic_profile_expr='
let
  f = builtins.getFlake (toString ./.);
  nixpkgs = f.inputs.nixpkgs;
  lib = nixpkgs.lib;
  baseVars = import ./vars.nix { inherit lib; };
  vars = baseVars // {
    system = baseVars.system // {
      hostPlatform = "aarch64-linux";
      hardwareProfile = "generic-uefi";
    };
    storage = baseVars.storage // {
      profile = "single-disk-ext4";
      dataPool = baseVars.storage.dataPool // {
        mirrorPairs = [];
      };
    };
    hostPlatform = "aarch64-linux";
    hardwareProfile = "generic-uefi";
    hostId = "00000000";
    storageProfile = "single-disk-ext4";
    enableZfsDataPool = false;
    dataRootIsMountPoint = false;
    zfsDataPool = baseVars.zfsDataPool // {
      mirrorPairs = [];
    };
    zfsDataPoolDiskIds = [];
  };
  pkgs = nixpkgs.legacyPackages.aarch64-linux;
  appPackages = {
    homepage = pkgs.writeTextDir "share/homepage/client/index.html" "";
    mail-archive-ui = pkgs.writeShellScriptBin "mail-archive-ui" "exit 0";
    groundwater-logger = pkgs.writeShellScriptBin "groundwater-logger" "exit 0";
  };
  host = import ./flake/system.nix {
    inputs = f.inputs;
    inherit lib vars pkgs appPackages;
    system = "aarch64-linux";
  };
in host.nixosConfigurations.server.config
'

synthetic_homepage_profile_expr='
let
  f = builtins.getFlake (toString ./.);
  nixpkgs = f.inputs.nixpkgs;
  lib = nixpkgs.lib;
  baseVars = import ./vars.nix { inherit lib; };
  vars = baseVars // {
    system = baseVars.system // {
      hostPlatform = "x86_64-linux";
      hardwareProfile = "generic-uefi";
    };
    storage = baseVars.storage // {
      profile = "single-disk-ext4";
      dataPool = baseVars.storage.dataPool // {
        mirrorPairs = [];
      };
    };
    hostPlatform = "x86_64-linux";
    hardwareProfile = "generic-uefi";
    hostId = "00000000";
    storageProfile = "single-disk-ext4";
    enableZfsDataPool = false;
    dataRootIsMountPoint = false;
    zfsDataPool = baseVars.zfsDataPool // {
      mirrorPairs = [];
    };
    zfsDataPoolDiskIds = [];
  };
  pkgs = nixpkgs.legacyPackages.x86_64-linux;
  appPackages = {
    homepage = pkgs.writeTextDir "share/homepage/client/index.html" "";
    mail-archive-ui = pkgs.writeShellScriptBin "mail-archive-ui" "exit 0";
    groundwater-logger = pkgs.writeShellScriptBin "groundwater-logger" "exit 0";
  };
  host = import ./flake/system.nix {
    inputs = f.inputs;
    inherit lib vars pkgs appPackages;
    system = "x86_64-linux";
  };
in host.nixosConfigurations.server.config
'

synthetic_profile_json="$(nix eval --impure --json --expr "
let
  cfg = ${synthetic_profile_expr};
in {
  rootFsType = cfg.fileSystems.\"/\".fsType;
  hasNixFs = builtins.hasAttr \"/nix\" cfg.fileSystems;
  hasPersistFs = builtins.hasAttr \"/persist\" cfg.fileSystems;
  smartdWants = cfg.systemd.services.smartd.wants or [];
  beszelExtraFilesystems = cfg.systemd.services.beszel-agent.environment.EXTRA_FILESYSTEMS;
  vars = {
    hostPlatform = \"aarch64-linux\";
    storageProfile = \"single-disk-ext4\";
    enableZfsDataPool = false;
    dataRootIsMountPoint = false;
  };
}")"

jq -e '
  (.vars.hostPlatform == "aarch64-linux")
  and (.vars.storageProfile == "single-disk-ext4")
  and (.rootFsType == "ext4")
  and (.hasNixFs == false)
  and (.hasPersistFs == false)
  and (.vars.enableZfsDataPool == false)
  and (.vars.dataRootIsMountPoint == false)
  and (.smartdWants | index("zfs.target") == null)
  and (.beszelExtraFilesystems | contains("/__Root"))
  and (.beszelExtraFilesystems | contains("/mnt/data__DataRoot"))
  and (.beszelExtraFilesystems | contains("__DataPool") | not)
' <<<"$synthetic_profile_json" >/dev/null || {
  echo "❌ Synthetic ARM/single-disk profile is not profile-clean."
  jq . <<<"$synthetic_profile_json"
  exit 1
}

require_fixed \
  modules/Core_Modules/storage/layout.nix \
  "script = if vars.enableZfsDataPool then zfsLayoutScript else directoryLayoutScript;" \
  "data-pool-layout.service should select the directory-only script when ZFS is disabled."

require_fixed \
  system-resources.nix \
  "++ lib.optionals vars.enableZfsDataPool [" \
  "ZFS and Btrfs suspend blocker units should only be included when the ZFS data pool is enabled."

directory_layout_block="$(
  awk '
    /directoryLayoutScript = '\'''\''/ { in_block = 1 }
    in_block { print }
    in_block && /^  '\'''\'';/ { exit }
  ' modules/Core_Modules/storage/layout.nix
)"

if rg -q "zpool|zfsBin|zpoolBin|zfsDatasetCommands" <<<"$directory_layout_block"; then
  echo "❌ directoryLayoutScript must remain free of ZFS commands."
  echo "$directory_layout_block"
  exit 1
fi

current_homepage_config="$(
  nix build --impure --no-link --print-out-paths --expr '
    let
      f = builtins.getFlake (toString ./.);
    in f.nixosConfigurations.server.config.systemd.services.homepage.environment.HOMEPAGE_CONFIG_FILE
  '
)"
current_homepage_commands="$(jq -r ".adminGuide[].command" "$current_homepage_config")"

if ! rg -Fq "zpool status -v" <<<"$current_homepage_commands"; then
  echo "❌ Current ZFS profile should expose ZFS status commands in Homepage."
  exit 1
fi

if ! rg -Fq "btrfs filesystem usage /persist" <<<"$current_homepage_commands"; then
  echo "❌ Current ZFS profile should expose Btrfs persistent-state commands in Homepage."
  exit 1
fi

synthetic_homepage_config="$(
  nix build --impure --no-link --print-out-paths --expr "
    let
      cfg = ${synthetic_homepage_profile_expr};
    in cfg.systemd.services.homepage.environment.HOMEPAGE_CONFIG_FILE
  "
)"
synthetic_homepage_commands="$(jq -r ".adminGuide[].command" "$synthetic_homepage_config")"

if rg -q "zpool|btrfs" <<<"$synthetic_homepage_commands"; then
  echo "❌ Single-disk Homepage admin commands must not include ZFS or Btrfs commands."
  echo "$synthetic_homepage_commands"
  exit 1
fi

for expected_command in \
  "df -hT / /mnt/data /persist" \
  "findmnt -no SOURCE,FSTYPE,OPTIONS /" \
  "sudo journalctl -u data-pool-layout.service -n 100 --no-pager"; do
  if ! rg -Fq "$expected_command" <<<"$synthetic_homepage_commands"; then
    echo "❌ Single-disk Homepage commands should include: $expected_command"
    echo "$synthetic_homepage_commands"
    exit 1
  fi
done

echo "✅ Platform and storage profile regression tests passed."
