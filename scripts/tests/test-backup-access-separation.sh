#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"
cd "$TESTS_REPO_ROOT"
ensure_tools jq nix rg

model_json="$(nix eval --impure --json --expr '
let
  f = builtins.getFlake (builtins.getEnv "NIXHOMESERVER_FLAKE_REF_FOR_EVAL");
  derive = import ./lib/backup-access.nix { lib = f.inputs.nixpkgs.lib; };
  malformed = derive {
    identity.adminUser = "primary-admin";
    basePosixGids.files = 2001;
    backupAccess = {
      adminGroup = {};
      adminUsers = "not-a-list";
      storageGroup = [];
      storageGid = "2005";
      storageUsers = ["storage-reader" {}];
    };
  };
in {
  safeAdminGroup = malformed.adminGroup == "invalid-backup-admin-group";
  safeStorageGroup = malformed.storageGroup == "invalid-backup-storage-group";
  safeStorageGid = malformed.storageGid == 2005;
  safeAdminMembers = malformed.adminMembers == ["primary-admin"];
  filtersMalformedStorageMember = malformed.storageMembers == ["primary-admin" "storage-reader"];
  deterministicFallbackMapping = malformed.fileAccessPosixGids.invalid-backup-storage-group == 2005;
}
')"

if ! jq -e '[to_entries[] | select(.value != true)] | length == 0' \
  <<<"$model_json" >/dev/null; then
  echo "Backup access derivation is not total for malformed operator input." >&2
  jq . <<<"$model_json" >&2
  exit 1
fi

behavior_json="$(nix eval --impure --json --expr '
let
  f = builtins.getFlake (builtins.getEnv "NIXHOMESERVER_FLAKE_REF_FOR_EVAL");
  lib = f.inputs.nixpkgs.lib;
  base = import ./vars.nix { inherit lib; };
  backupAccess = base.backupAccess // {
    adminGroup = "custom-backup-admins";
    adminUsers = ["backup-admin-only"];
    storageGroup = "custom-backup-readers";
    storageGid = 23456;
    storageUsers = ["backup-reader-only"];
  };
  model = (import ./lib/backup-access.nix { inherit lib; }) {
    inherit backupAccess;
    identity = base.identity;
    basePosixGids = builtins.removeAttrs base.fileAccessPosixGids [base.backupStorageGroup];
  };
  vars = base // {
    inherit backupAccess;
    backupAccessModel = model;
    configuredBackupAdminUsers = model.configuredAdminUsers;
    configuredBackupStorageUsers = model.configuredStorageUsers;
    backupAdminUsers = model.adminUsers;
    backupStorageUsers = model.storageUsers;
    backupAdminGroup = model.adminGroup;
    backupStorageGroup = model.storageGroup;
    backupStorageGid = model.storageGid;
    kanidmBackupAdminUsers = model.adminMembers;
    kanidmBackupStorageUsers = model.storageMembers;
    kanidmBackupUsers = model.allUsers;
    fileAccessPosixGids = model.fileAccessPosixGids;
  };
  pkgs = f.inputs.nixpkgs.legacyPackages.${base.hostPlatform};
  packages = import ./flake/packages.nix { inherit lib pkgs; crane = f.inputs.crane; };
  system = import ./flake/system.nix {
    inputs = f.inputs;
    inherit lib vars pkgs;
    system = base.hostPlatform;
    appPackages = packages.appPackages;
  };
  cfg = system.nixosConfigurations.${base.hostname}.config;
  groups = cfg.services.kanidm.provision.groups;
in {
  admin = groups.${model.adminGroup};
  storage = groups.${model.storageGroup};
  storageGid = vars.fileAccessPosixGids.${model.storageGroup};
  localStorageGid = cfg.users.groups.${model.storageGroup}.gid;
  kopiaScopeGroups = builtins.attrNames cfg.services.kanidm.provision.systems.oauth2.kopia-web.scopeMaps;
  filesScopeGroups = builtins.attrNames cfg.services.kanidm.provision.systems.oauth2.filestash-web.scopeMaps;
  posixScript = cfg.systemd.services.kanidm-files-posix-groups.script;
  maintenanceLockRules = builtins.filter
    (rule: builtins.match "f /run/lock/nixhomeserver-maintenance[.]lock .*" rule != null)
    cfg.systemd.tmpfiles.rules;
  rcloneExtraGroups = cfg.users.users.rclone.extraGroups;
}
')"

if ! jq -e '
  (.admin.members | sort) == (["admindsaw", "backup-admin-only"] | sort)
  and .admin.overwriteMembers
  and (.storage.members | sort) == (["admindsaw", "backup-admin-only", "backup-reader-only"] | sort)
  and .storage.overwriteMembers
  and (.admin.members | index("backup-reader-only") == null)
  and (.storage.members | index("backup-admin-only") != null)
  and (.admin.members | index("canary-user") == null)
  and (.storage.members | index("canary-user") == null)
  and .storageGid == 23456
  and .localStorageGid == 23456
  and .kopiaScopeGroups == ["custom-backup-admins"]
  and (.filesScopeGroups | index("custom-backup-readers") != null)
  and (.posixScript | contains("reset_retired_posix_group_gid custom-backup-admins 23456"))
  and .maintenanceLockRules == ["f /run/lock/nixhomeserver-maintenance.lock 0660 root nixhomeserver-maintenance -"]
  and (.rcloneExtraGroups | index("nixhomeserver-maintenance") != null)
  and (.rcloneExtraGroups | index("custom-backup-readers") != null)
' <<<"$behavior_json" >/dev/null; then
  echo "Backup admin/storage provisioning, authorization, or GID separation regressed." >&2
  jq . <<<"$behavior_json" >&2
  exit 1
fi

malformed_log="$(mktemp)"
gid_collision_log="$(mktemp)"
reserved_name_collision_log="$(mktemp)"
service_name_collision_log="$(mktemp)"
trap 'rm -f "$malformed_log" "$gid_collision_log" "$reserved_name_collision_log" "$service_name_collision_log"' EXIT
malformed_expr='
let
  f = builtins.getFlake (builtins.getEnv "NIXHOMESERVER_FLAKE_REF_FOR_EVAL");
  lib = f.inputs.nixpkgs.lib;
  base = import ./vars.nix { inherit lib; };
  testCase = builtins.getEnv "NIXHOMESERVER_BACKUP_ACCESS_CASE";
  backupAccess = base.backupAccess // (
    if testCase == "gid-collision" then {
      # nixbld is an explicit local group at GID 30000. A remote Kanidm
      # storage group must never share that identity.
      storageGid = 30000;
    } else if testCase == "reserved-name-collisions" then {
      adminGroup = "app-admin";
      storageGroup = "paperless-users";
    } else if testCase == "service-name-collision" then {
      storageGroup = "caddy";
    } else {
      adminGroup = {};
      adminUsers = ["reader" {}];
      storageGroup = [];
      storageGid = "2005";
      storageUsers = ["reader" {}];
    }
  );
  model = (import ./lib/backup-access.nix { inherit lib; }) {
    inherit backupAccess;
    identity = base.identity;
    basePosixGids = builtins.removeAttrs base.fileAccessPosixGids [base.backupStorageGroup];
  };
  vars = base // {
    inherit backupAccess;
    backupAccessModel = model;
    configuredBackupAdminUsers = model.configuredAdminUsers;
    configuredBackupStorageUsers = model.configuredStorageUsers;
    backupAdminUsers = model.adminUsers;
    backupStorageUsers = model.storageUsers;
    backupAdminGroup = model.adminGroup;
    backupStorageGroup = model.storageGroup;
    backupStorageGid = model.storageGid;
    kanidmBackupAdminUsers = model.adminMembers;
    kanidmBackupStorageUsers = model.storageMembers;
    kanidmBackupUsers = model.allUsers;
    fileAccessPosixGids = model.fileAccessPosixGids;
  };
  pkgs = f.inputs.nixpkgs.legacyPackages.${base.hostPlatform};
  packages = import ./flake/packages.nix { inherit lib pkgs; crane = f.inputs.crane; };
  system = import ./flake/system.nix {
    inputs = f.inputs;
    inherit lib vars pkgs;
    system = base.hostPlatform;
    appPackages = packages.appPackages;
  };
in system.nixosConfigurations.${base.hostname}.config.system.build.toplevel.drvPath
'
if nix eval --impure --raw --expr "$malformed_expr" >"$malformed_log" 2>&1; then
  echo "Malformed backup access configuration unexpectedly passed evaluation." >&2
  exit 1
fi
for expected_message in \
  'backupAccess.adminGroup must be a valid Kanidm group name' \
  'backupAccess.storageGroup must be a valid Kanidm group name' \
  'backupAccess.storageGid must be an integer from 1000 through 59999' \
  'backupAccess.adminUsers must be a list of valid Kanidm user names' \
  'backupAccess.storageUsers must be a list of valid Kanidm user names' \
  'backupAccess.adminUsers and backupAccess.storageUsers must not overlap'; do
  if ! rg -Fq "$expected_message" "$malformed_log"; then
    echo "Malformed backup access failed without the actionable assertion: $expected_message" >&2
    cat "$malformed_log" >&2
    exit 1
  fi
done

if NIXHOMESERVER_BACKUP_ACCESS_CASE=gid-collision \
  nix eval --impure --raw --expr "$malformed_expr" >"$gid_collision_log" 2>&1; then
  echo "Backup storage GID collision with the local nixbld group unexpectedly passed evaluation." >&2
  exit 1
fi
if ! rg -Fq \
  'backupAccess.storageGid must not reuse an explicit local system or service group GID; colliding groups: ["nixbld"]' \
  "$gid_collision_log"; then
  echo "Backup storage GID collision failed without the actionable local-group assertion." >&2
  cat "$gid_collision_log" >&2
  exit 1
fi

if NIXHOMESERVER_BACKUP_ACCESS_CASE=reserved-name-collisions \
  nix eval --impure --raw --expr "$malformed_expr" >"$reserved_name_collision_log" 2>&1; then
  echo "Backup group-name collisions with application groups unexpectedly passed evaluation." >&2
  exit 1
fi
if ! rg -Fq \
  'backupAccess adminGroup and storageGroup must not reuse file-access, local bridge, maintenance, core identity, or application group names: {"adminGroup":"app-admin","storageGroup":"paperless-users"}' \
  "$reserved_name_collision_log"; then
  echo "Backup application-group name collisions failed without the actionable field mapping." >&2
  cat "$reserved_name_collision_log" >&2
  exit 1
fi

if NIXHOMESERVER_BACKUP_ACCESS_CASE=service-name-collision \
  nix eval --impure --raw --expr "$malformed_expr" >"$service_name_collision_log" 2>&1; then
  echo "Backup storage name collision with the local caddy service group unexpectedly passed evaluation." >&2
  exit 1
fi
if ! rg -Fq \
  'backupAccess.storageGroup must not reuse a local built-in or service group: ["caddy"]' \
  "$service_name_collision_log"; then
  echo "Backup storage service-group name collision failed without the actionable assertion." >&2
  cat "$service_name_collision_log" >&2
  exit 1
fi

echo "✅ Backup administration, storage access, and POSIX GID separation tests passed."
