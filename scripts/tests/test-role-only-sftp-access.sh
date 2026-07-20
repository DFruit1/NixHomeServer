#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"
cd "$TESTS_REPO_ROOT"
ensure_tools jq nix rg

role_json="$(nix eval --impure --json --expr '
let
  f = builtins.getFlake (builtins.getEnv "NIXHOMESERVER_FLAKE_REF_FOR_EVAL");
  lib = f.inputs.nixpkgs.lib;
  base = import ./vars.nix { inherit lib; };
  backupAccess = base.backupAccess // {
    adminUsers = [];
    storageUsers = ["backup-storage-only"];
  };
  fileAccess = base.fileAccess // {
    usbUsers = ["usb-only"];
  };
  model = (import ./lib/backup-access.nix { inherit lib; }) {
    inherit backupAccess;
    identity = base.identity;
    basePosixGids = builtins.removeAttrs base.fileAccessPosixGids [base.backupStorageGroup];
  };
  vars = base // {
    inherit backupAccess fileAccess;
    configuredFileAccessUsbUsers = fileAccess.usbUsers;
    fileAccessUsbUsers = fileAccess.usbUsers;
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
  persons = builtins.attrNames cfg.services.kanidm.provision.persons;
  adminMembers = groups.${vars.backupAdminGroup}.members;
  storageMembers = groups.${vars.backupStorageGroup}.members;
  usbMembers = groups.${vars.fileAccess.usbAccessGroup}.members;
  webMembers = groups.${vars.fileAccess.webAccessGroup}.members;
  directSftpMembers = groups.${vars.fileAccess.sftpAccessGroup}.members;
  sharedMembers = groups.${vars.fileAccess.sharedAccessGroup}.members;
  baselineMembers = groups.users.members;
  kopiaScopeGroups = builtins.attrNames cfg.services.kanidm.provision.systems.oauth2.kopia-web.scopeMaps;
  homepageScopeGroups = builtins.attrNames cfg.services.kanidm.provision.systems.oauth2.homepage-web.scopeMaps;
  gatewayScopeGroups = builtins.attrNames cfg.services.kanidm.provision.systems.oauth2.auth-gateway-web.scopeMaps;
  homepageRouterGroups = cfg.repo.authGateway.protectedApps.homepage.allowedGroups;
  filesRouterGroups = cfg.repo.authGateway.protectedApps.files.allowedGroups;
  homepageSidecarExec = cfg.systemd.services.homepage-oauth2-proxy.serviceConfig.ExecStart;
  filesSidecarExec = cfg.systemd.services.filestash-oauth2-proxy.serviceConfig.ExecStart;
  homepageConfigDrv = cfg.systemd.services.homepage.environment.HOMEPAGE_CONFIG_FILE.drvPath;
}
')"

if ! jq -e '
  (.persons | index("backup-storage-only") != null)
  and (.persons | index("usb-only") != null)
  and (.storageMembers | index("backup-storage-only") != null)
  and (.adminMembers | index("backup-storage-only") == null)
  and (.usbMembers | index("backup-storage-only") == null)
  and (.webMembers | index("backup-storage-only") == null)
  and (.directSftpMembers | index("backup-storage-only") == null)
  and (.baselineMembers | index("backup-storage-only") == null)
  and (.usbMembers | index("usb-only") != null)
  and (.adminMembers | index("usb-only") == null)
  and (.storageMembers | index("usb-only") == null)
  and (.webMembers | index("usb-only") == null)
  and (.directSftpMembers | index("usb-only") == null)
  and (.baselineMembers | index("usb-only") == null)
  and .kopiaScopeGroups == ["backup-admin"]
  and (.homepageScopeGroups | index("usb-access") != null)
  and (.homepageScopeGroups | index("backup-storage-users") != null)
  and (.homepageScopeGroups | index("files-shared-users") != null)
  and (.gatewayScopeGroups | index("usb-access") != null)
  and (.gatewayScopeGroups | index("backup-storage-users") != null)
  and (.gatewayScopeGroups | index("files-shared-users") != null)
  and (.homepageRouterGroups | index("usb-access") != null)
  and (.homepageRouterGroups | index("backup-storage-users") != null)
  and (.homepageRouterGroups | index("files-shared-users") != null)
  and .filesRouterGroups == ["files-personal-users"]
  and (.homepageSidecarExec | contains("--allowed-group=usb-access"))
  and (.homepageSidecarExec | contains("--allowed-group=backup-storage-users"))
  and (.homepageSidecarExec | contains("--allowed-group=files-shared-users"))
  and (.filesSidecarExec | contains("--allowed-group=files-personal-users"))
  and (.filesSidecarExec | contains("--allowed-group=usb-access") | not)
  and (.filesSidecarExec | contains("--allowed-group=backup-storage-users") | not)
  and (.filesSidecarExec | contains("--allowed-group=files-shared-users") | not)
' <<<"$role_json" >/dev/null; then
  echo "Role-only identity, Homepage access, or Files web isolation regressed." >&2
  jq . <<<"$role_json" >&2
  exit 1
fi

text_derivation_payload() {
  local drv_path="$1"
  nix derivation show "$drv_path" | jq -er '
    (if has("derivations") then .derivations else . end)
    | to_entries
    | if length == 1 and (.[0].value.env.text | type) == "string" then
        .[0].value.env.text
      else
        error("expected exactly one writeText-style derivation")
      end
  '
}

sftp_member_block="$(
  sed -n '/sftp_members_json=/,/usb_members_json=/p' modules/Core_Modules/storage/fileshare-user-roots.nix
)"
for required_group_variable in webAccessGroup sftpAccessGroup sharedAccessGroup usbAccessGroup backupStorageAccessGroup; do
  if ! rg -Fq "group_members_by_name[\${lib.escapeShellArg $required_group_variable}]" <<<"$sftp_member_block"; then
    echo "SFTP chroot activation omitted members of $required_group_variable." >&2
    printf '%s\n' "$sftp_member_block" >&2
    exit 1
  fi
done

homepage_config="$(text_derivation_payload "$(jq -r .homepageConfigDrv <<<"$role_json")")"
if ! jq -e '
  (.sftp.requiredAnyGroups | index("usb-access") != null)
  and (.sftp.requiredAnyGroups | index("backup-storage-users") != null)
  and (.sftp.requiredAnyGroups | index("files-shared-users") != null)
  and ([.sftp.accessNotes[]
    | select((.requiredAnyGroups | index("files-shared-users")) != null)
    | .text
    | contains("/_Shared")] | any)
  and ([.sftp.accessNotes[]
    | select((.requiredAnyGroups | index("usb-access")) != null)
    | .text
    | contains("/_USB")] | any)
  and ([.sftp.accessNotes[]
    | select((.requiredAnyGroups | index("backup-storage-users")) != null)
    | .text
    | contains("/_Backups") and contains("read-only")] | any)
' <<<"$homepage_config" >/dev/null; then
  echo "Homepage role-only SFTP authorization or view guidance regressed." >&2
  jq .sftp <<<"$homepage_config" >&2
  exit 1
fi

echo "✅ Shared-only, USB-only, and backup-storage-only SFTP access tests passed."
