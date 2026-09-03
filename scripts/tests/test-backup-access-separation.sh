#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"
cd "$TESTS_REPO_ROOT"
ensure_tools jq nix rg

require_fixed modules/Core_Modules/auth-gateway/default.nix \
  'handle @denied_${matcher} {' \
  "The internal auth router must make the per-app group denial a terminal handle before catch-all proxy handles"

model_json="$(flake_eval_json '
  derive = import ./lib/backup-access.nix;
  malformed = derive {
    basePosixGids.files = 2001;
    backupAccess = {
      adminGroup = {};
      storageGroup = [];
      storageGid = "2005";
    };
  };
in {
  safeAdminGroup = malformed.adminGroup == "invalid-backup-admin-group";
  safeStorageGroup = malformed.storageGroup == "invalid-backup-storage-group";
  safeStorageGid = malformed.storageGid == 2005;
  deterministicFallbackMapping = malformed.fileAccessPosixGids.invalid-backup-storage-group == 2005;
}
')"

if ! jq -e '[to_entries[] | select(.value != true)] | length == 0' \
  <<<"$model_json" >/dev/null; then
  echo "Backup access derivation is not total for malformed operator input." >&2
  jq . <<<"$model_json" >&2
  exit 1
fi

behavior_json="$(flake_eval_json '
  base = import ./vars.nix { inherit lib; };
  backupAccess = base.backupAccess // {
    adminGroup = "custom-backup-admins";
    storageGroup = "custom-backup-readers";
    storageGid = 23456;
  };
  model = import ./lib/backup-access.nix {
    inherit backupAccess;
    basePosixGids = builtins.removeAttrs base.fileAccessPosixGids [base.backupStorageGroup];
  };
  vars = base // {
    inherit backupAccess;
    backupAccessModel = model;
    backupAdminGroup = model.adminGroup;
    backupStorageGroup = model.storageGroup;
    backupStorageGid = model.storageGid;
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
  .admin.members == []
  and (.admin.overwriteMembers | not)
  and .storage.members == []
  and (.storage.overwriteMembers | not)
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

malformed_body='
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
      storageGroup = [];
      storageGid = "2005";
    }
  );
  model = import ./lib/backup-access.nix {
    inherit backupAccess;
    basePosixGids = builtins.removeAttrs base.fileAccessPosixGids [base.backupStorageGroup];
  };
  vars = base // {
    inherit backupAccess;
    backupAccessModel = model;
    backupAdminGroup = model.adminGroup;
    backupStorageGroup = model.storageGroup;
    backupStorageGid = model.storageGid;
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

malformed_log="$(capture_eval_failure "$malformed_body")"
for expected_message in \
  'backupAccess.adminGroup must be a valid Kanidm group name' \
  'backupAccess.storageGroup must be a valid Kanidm group name' \
  'backupAccess.storageGid must be an integer from 1000 through 59999'; do
  if ! rg -Fq "$expected_message" <<<"$malformed_log"; then
    echo "Malformed backup access failed without the actionable assertion: $expected_message" >&2
    printf '%s\n' "$malformed_log" >&2
    exit 1
  fi
done

NIXHOMESERVER_BACKUP_ACCESS_CASE=gid-collision eval_fails_with \
  'backupAccess.storageGid must not reuse an explicit local system or service group GID; colliding groups: ["nixbld"]' \
  "$malformed_body"

NIXHOMESERVER_BACKUP_ACCESS_CASE=reserved-name-collisions eval_fails_with \
  'backupAccess adminGroup and storageGroup must not reuse file-access, local bridge, maintenance, core identity, or application group names: {"adminGroup":"app-admin","storageGroup":"paperless-users"}' \
  "$malformed_body"

NIXHOMESERVER_BACKUP_ACCESS_CASE=service-name-collision eval_fails_with \
  'backupAccess.storageGroup must not reuse a local built-in or service group: ["caddy"]' \
  "$malformed_body"

echo "✅ Backup administration, storage access, and POSIX GID separation tests passed."
