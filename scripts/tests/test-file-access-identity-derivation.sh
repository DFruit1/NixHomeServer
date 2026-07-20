#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"
cd "$TESTS_REPO_ROOT"
ensure_tools jq nix rg

derivation_json="$(nix eval --impure --json --expr '
  let
    f = builtins.getFlake (builtins.getEnv "NIXHOMESERVER_FLAKE_REF_FOR_EVAL");
    lib = f.inputs.nixpkgs.lib;
    deriveGids = fileAccess: import ./lib/file-access-gids.nix { inherit fileAccess; };
    custom = deriveGids {
      webAccessGroup = "custom-web-users";
      sftpAccessGroup = "custom-sftp-users";
      sharedAccessGroup = "custom-shared-users";
      usbAccessGroup = "custom-usb-users";
    };
    collision = deriveGids {
      webAccessGroup = "same-group";
      sftpAccessGroup = "same-group";
      sharedAccessGroup = "other-shared-group";
      usbAccessGroup = "other-usb-group";
    };
    malformed = deriveGids {
      webAccessGroup = {};
      sftpAccessGroup = [];
      sharedAccessGroup = null;
      usbAccessGroup = 42;
    };
    identity = (import ./lib/identity-access.nix { inherit lib; }) {
      identity = {
        adminUser = "identity-admin";
        canaryUser = "canary-user";
        appUsers = ["ordinary-user"];
        appAdminUsers = ["app-admin-only" "ordinary-user"];
      };
    };
  in {
    customStableGids = custom.posixGids == {
      custom-web-users = 2001;
      custom-sftp-users = 2002;
      custom-shared-users = 2003;
      custom-usb-users = 2004;
    };
    collisionIsTotal =
      builtins.hasAttr "same-group" collision.posixGids
      && builtins.length (builtins.attrNames collision.posixGids) == 3;
    malformedIsTotal = malformed.renderableGroupNames == {
      webAccessGroup = "invalid-file-access-web-group";
      sftpAccessGroup = "invalid-file-access-sftp-group";
      sharedAccessGroup = "invalid-file-access-shared-group";
      usbAccessGroup = "invalid-file-access-usb-group";
    };
    appAdminInNormalAccess = builtins.elem "app-admin-only" identity.appUsers;
    appAdminInAdminAccess = builtins.elem "app-admin-only" identity.appAdminUsers;
    ordinaryUserDeduplicated =
      builtins.length (builtins.filter (user: user == "ordinary-user") identity.appUsers) == 1;
    canaryHasNormalAccess = builtins.elem "canary-user" identity.appUsers;
    canaryIsNotAdmin = !(builtins.elem "canary-user" identity.appAdminUsers);
  }
')"

if ! jq -e '[to_entries[] | select(.value != true)] | length == 0' <<<"$derivation_json" >/dev/null; then
  echo "❌ File-access GID or identity-access derivation regressed." >&2
  jq . <<<"$derivation_json" >&2
  exit 1
fi

behavior_json="$(nix eval --impure --json --expr '
  let
    f = builtins.getFlake (builtins.getEnv "NIXHOMESERVER_FLAKE_REF_FOR_EVAL");
    lib = f.inputs.nixpkgs.lib;
    base = import ./vars.nix { inherit lib; };
    pkgs = f.inputs.nixpkgs.legacyPackages.${base.hostPlatform};
    packages = import ./flake/packages.nix {
      inherit lib pkgs;
      crane = f.inputs.crane;
    };
    mkConfig = vars: (import ./flake/system.nix {
      inputs = f.inputs;
      inherit lib vars pkgs;
      system = base.hostPlatform;
      appPackages = packages.appPackages;
    }).nixosConfigurations.${base.hostname}.config;

    fileAccess = base.fileAccess // {
      webAccessGroup = "custom-web-users";
      sftpAccessGroup = "custom-sftp-users";
      sharedAccessGroup = "custom-shared-users";
      usbAccessGroup = "custom-usb-users";
    };
    fileAccessGidModel = import ./lib/file-access-gids.nix { inherit fileAccess; };
    backupAccessModel = (import ./lib/backup-access.nix { inherit lib; }) {
      inherit (base) backupAccess identity;
      basePosixGids = fileAccessGidModel.posixGids;
    };
    customVars = base // {
      inherit fileAccess fileAccessGidModel backupAccessModel;
      configuredBackupAdminUsers = backupAccessModel.configuredAdminUsers;
      configuredBackupStorageUsers = backupAccessModel.configuredStorageUsers;
      backupAdminUsers = backupAccessModel.adminUsers;
      backupStorageUsers = backupAccessModel.storageUsers;
      backupAdminGroup = backupAccessModel.adminGroup;
      backupStorageGroup = backupAccessModel.storageGroup;
      backupStorageGid = backupAccessModel.storageGid;
      kanidmBackupAdminUsers = backupAccessModel.adminMembers;
      kanidmBackupStorageUsers = backupAccessModel.storageMembers;
      kanidmBackupUsers = backupAccessModel.allUsers;
      fileAccessPosixGids = backupAccessModel.fileAccessPosixGids;
    };
    customCfg = mkConfig customVars;

    identity = base.identity // {
      appUsers = [];
      appAdminUsers = ["app-admin-only"];
    };
    identityAccessModel = (import ./lib/identity-access.nix { inherit lib; }) {
      inherit identity;
      inherit (base) fileAccess monitoringAccess seerrAccess;
    };
    identityVars = base // {
      inherit identity identityAccessModel;
      configuredIdentityAppUsers = identityAccessModel.configuredAppUsers;
      configuredIdentityAppAdminUsers = identityAccessModel.configuredAppAdminUsers;
      kanidmAppUsers = identityAccessModel.appUsers;
      kanidmAppAdminUsers = identityAccessModel.appAdminUsers;
      filesSftpUsers = identityAccessModel.appUsers;
      jellyfinAdminUsers = identityAccessModel.appAdminUsers;
    };
    identityCfg = mkConfig identityVars;
    identityGroups = identityCfg.services.kanidm.provision.groups;
    normalAppGroups = [
      "users"
      identityVars.fileAccess.webAccessGroup
      identityVars.fileAccess.sftpAccessGroup
      "audiobookshelf-users"
      "downloads-users"
      "immich-users"
      "jellyfin-users"
      "kavita-users"
      "kiwix-users"
      "mail-archive-users"
      "media-automation-users"
      "paperless-users"
    ];
  in {
    customToplevel = customCfg.system.build.toplevel.drvPath;
    customGids = customVars.fileAccessPosixGids;
    customGroupsProvisioned = builtins.all
      (group: builtins.hasAttr group customCfg.services.kanidm.provision.groups)
      (builtins.attrValues fileAccessGidModel.renderableGroupNames);
    customLocalGids = {
      web = customCfg.users.groups.custom-web-users.gid;
      sftp = customCfg.users.groups.custom-sftp-users.gid;
      shared = customCfg.users.groups.custom-shared-users.gid;
      usb = customCfg.users.groups.custom-usb-users.gid;
    };
    identityToplevel = identityCfg.system.build.toplevel.drvPath;
    appAdminHasEveryNormalAppGroup = builtins.all
      (group: builtins.elem "app-admin-only" (identityGroups.${group}.members or []))
      normalAppGroups;
    appAdminHasAdminGroup = builtins.elem "app-admin-only" identityGroups.app-admin.members;
    canaryHasNoAdminGroup = !(builtins.elem identity.canaryUser identityGroups.app-admin.members);
  }
')"

if ! jq -e '
  .customGids == {
    "custom-web-users": 2001,
    "custom-sftp-users": 2002,
    "custom-shared-users": 2003,
    "custom-usb-users": 2004,
    "backup-storage-users": 2005
  }
  and .customGroupsProvisioned
  and .customLocalGids == {"web": 2001, "sftp": 2002, "shared": 2003, "usb": 2004}
  and .appAdminHasEveryNormalAppGroup
  and .appAdminHasAdminGroup
  and .canaryHasNoAdminGroup
' <<<"$behavior_json" >/dev/null; then
  echo "❌ Custom file-access names or app-admin access inheritance failed full host evaluation." >&2
  jq . <<<"$behavior_json" >&2
  exit 1
fi

invalid_log="$(mktemp)"
collision_log="$(mktemp)"
local_invalid_log="$(mktemp)"
local_reserved_log="$(mktemp)"
local_service_log="$(mktemp)"
file_service_log="$(mktemp)"
local_gid_log="$(mktemp)"
cleanup() {
  rm -f \
    "$invalid_log" \
    "$collision_log" \
    "$local_invalid_log" \
    "$local_reserved_log" \
    "$local_service_log" \
    "$file_service_log" \
    "$local_gid_log"
}
trap cleanup EXIT

evaluate_invalid_file_access() {
  local mode="$1"
  local output_file="$2"
  NIXHOMESERVER_FILE_ACCESS_CASE="$mode" nix eval --impure --raw --expr '
    let
      f = builtins.getFlake (builtins.getEnv "NIXHOMESERVER_FLAKE_REF_FOR_EVAL");
      lib = f.inputs.nixpkgs.lib;
      base = import ./vars.nix { inherit lib; };
      mode = builtins.getEnv "NIXHOMESERVER_FILE_ACCESS_CASE";
      fileAccess = base.fileAccess // (
        if mode == "invalid" then {
          webAccessGroup = "Invalid Group";
        } else if mode == "collision" then {
          sftpAccessGroup = base.fileAccess.webAccessGroup;
        } else if mode == "local-invalid" then {
          localSftpAccessGroup = "Invalid Group";
        } else if mode == "local-reserved" then {
          localSftpAccessGroup = "wheel";
        } else if mode == "local-service" then {
          localSftpAccessGroup = "caddy";
        } else if mode == "file-service" then {
          webAccessGroup = "caddy";
        } else if mode == "local-gid" then {
        } else
          throw "unsupported file-access validation test case"
      );
      fileAccessGidModel = import ./lib/file-access-gids.nix { inherit fileAccess; };
      backupAccessModel = (import ./lib/backup-access.nix { inherit lib; }) {
        inherit (base) backupAccess identity;
        basePosixGids = fileAccessGidModel.posixGids;
      };
      vars = base // {
        inherit fileAccess fileAccessGidModel backupAccessModel;
        configuredBackupAdminUsers = backupAccessModel.configuredAdminUsers;
        configuredBackupStorageUsers = backupAccessModel.configuredStorageUsers;
        backupAdminUsers = backupAccessModel.adminUsers;
        backupStorageUsers = backupAccessModel.storageUsers;
        backupAdminGroup = backupAccessModel.adminGroup;
        backupStorageGroup = backupAccessModel.storageGroup;
        backupStorageGid = backupAccessModel.storageGid;
        kanidmBackupAdminUsers = backupAccessModel.adminMembers;
        kanidmBackupStorageUsers = backupAccessModel.storageMembers;
        kanidmBackupUsers = backupAccessModel.allUsers;
        fileAccessPosixGids = backupAccessModel.fileAccessPosixGids;
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
      evaluatedHost =
        if mode == "local-gid" then
          host.extendModules {
            modules = [
              { users.groups."injected-file-gid".gid = 2001; }
            ];
          }
        else
          host;
    in evaluatedHost.config.system.build.toplevel.drvPath
  ' >"$output_file" 2>&1
}

if evaluate_invalid_file_access invalid "$invalid_log"; then
  echo "❌ Invalid fileAccess group name unexpectedly passed host evaluation." >&2
  exit 1
fi
if ! rg -Fq 'fileAccess webAccessGroup, sftpAccessGroup, sharedAccessGroup, and usbAccessGroup must be valid Kanidm group names; invalid fields: ["webAccessGroup"]' "$invalid_log"; then
  echo "❌ Invalid fileAccess group name failed without its actionable field-specific assertion." >&2
  cat "$invalid_log" >&2
  exit 1
fi

if evaluate_invalid_file_access collision "$collision_log"; then
  echo "❌ Colliding fileAccess group names unexpectedly passed host evaluation." >&2
  exit 1
fi
if ! rg -Fq 'backup admin/storage and file-access group names must all be distinct; duplicates: ["files-personal-users"]' "$collision_log"; then
  echo "❌ Colliding fileAccess group names failed without the actionable duplicate-name assertion." >&2
  cat "$collision_log" >&2
  exit 1
fi

if evaluate_invalid_file_access local-invalid "$local_invalid_log"; then
  echo "❌ Invalid local SFTP bridge group name unexpectedly passed host evaluation." >&2
  exit 1
fi
if ! rg -Fq \
  'fileAccess.localSftpAccessGroup must be a lowercase local Unix group name of at most 31 characters' \
  "$local_invalid_log"; then
  echo "❌ Invalid local SFTP bridge group failed without its actionable syntax assertion." >&2
  cat "$local_invalid_log" >&2
  exit 1
fi

for collision_case in local-reserved local-service; do
  if [[ "$collision_case" == "local-reserved" ]]; then
    collision_group=wheel
    collision_output="$local_reserved_log"
  else
    collision_group=caddy
    collision_output="$local_service_log"
  fi
  if evaluate_invalid_file_access "$collision_case" "$collision_output"; then
    echo "❌ Local SFTP bridge group collision with ${collision_group} unexpectedly passed host evaluation." >&2
    exit 1
  fi
  if ! rg -Fq \
    "fileAccess.localSftpAccessGroup must be a dedicated local bridge group and must not reuse a file-access, backup, identity, application, maintenance, built-in, or service group: [\"${collision_group}\"]" \
    "$collision_output"; then
    echo "❌ Local SFTP bridge collision with ${collision_group} failed without its actionable assertion." >&2
    cat "$collision_output" >&2
    exit 1
  fi
done

if evaluate_invalid_file_access file-service "$file_service_log"; then
  echo "❌ File-access group collision with the local caddy service group unexpectedly passed host evaluation." >&2
  exit 1
fi
if ! rg -Fq \
  'fileAccess groups must not reuse local built-in or service group names; colliding fields: {"webAccessGroup":"caddy"}' \
  "$file_service_log"; then
  echo "❌ File-access service-group collision failed without its actionable field mapping." >&2
  cat "$file_service_log" >&2
  exit 1
fi

if evaluate_invalid_file_access local-gid "$local_gid_log"; then
  echo "❌ File-access GID collision with an explicit local group unexpectedly passed host evaluation." >&2
  exit 1
fi
if ! rg -Fq \
  'fileAccess POSIX GIDs 2001 through 2004 must not reuse explicit local system or service group GIDs; colliding fields and groups: {"webAccessGroup":["injected-file-gid"]}' \
  "$local_gid_log"; then
  echo "❌ File-access local GID collision failed without its actionable field/group mapping." >&2
  cat "$local_gid_log" >&2
  exit 1
fi

echo "✅ Configurable file-access GIDs and app-admin access inheritance tests passed."
