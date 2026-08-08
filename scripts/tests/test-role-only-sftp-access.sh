#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"
cd "$TESTS_REPO_ROOT"
ensure_tools jq nix rg

role_json="$(flake_eval_json '
  base = import ./vars.nix { inherit lib; };
  vars = base;
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
  sharedViewExec = cfg.systemd.services."files-shared-bindfs@".serviceConfig.ExecStart;
  sharedDeleteViewExec = cfg.systemd.services."files-shared-delete-bindfs@".serviceConfig.ExecStart;
  homepageConfigDrv = cfg.systemd.services.homepage.environment.HOMEPAGE_CONFIG_FILE.drvPath;
}
')"

if ! jq -e '
  .adminMembers == []
  and .storageMembers == []
  and .usbMembers == []
  and .webMembers == []
  and .directSftpMembers == []
  and .sharedMembers == []
  and .kopiaScopeGroups == ["backup-admin"]
  and (.homepageScopeGroups | index("usb-access") != null)
  and (.homepageScopeGroups | index("backup-storage-users") != null)
  and (.homepageScopeGroups | index("files-shared-users") != null)
  and (.homepageScopeGroups | index("delete_shared_files") != null)
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
  and (.sharedViewExec | contains("--delete-deny"))
  and (.sharedViewExec | contains("a-t") | not)
  and (.sharedDeleteViewExec | contains("--delete-deny") | not)
  and (.sharedDeleteViewExec | contains("--perms=g+rwX,o-rwx,a-t"))
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
  sed -n '/sftp_members_json=/,/backup_storage_members_json=/p' modules/Core_Modules/storage/fileshare-user-roots.nix
)"
for required_group_variable in webAccessGroup sftpAccessGroup sharedAccessGroup usbAccessGroup backupStorageAccessGroup; do
  if ! rg -Fq "group_members_by_name[\${lib.escapeShellArg $required_group_variable}]" <<<"$sftp_member_block"; then
    echo "SFTP chroot activation omitted members of $required_group_variable." >&2
    printf '%s\n' "$sftp_member_block" >&2
    exit 1
  fi
done

delete_shared_block="$(
  sed -n '/delete_shared_members_json=/,/^    sftp_members_json=/p' modules/Core_Modules/storage/fileshare-user-roots.nix
)"
if ! rg -Fq "group_members_by_name[\${lib.escapeShellArg deleteSharedAccessGroup}]" <<<"$delete_shared_block"; then
  echo "Shared delete-capable view activation omitted deleteSharedAccessGroup members." >&2
  printf '%s\n' "$delete_shared_block" >&2
  exit 1
fi

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
    | select((.requiredAnyGroups | index("delete_shared_files")) != null)
    | .text
    | contains("delete")] | any)
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
