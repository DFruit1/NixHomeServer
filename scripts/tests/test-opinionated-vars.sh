#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"
cd "$TESTS_REPO_ROOT"
ensure_tools jq nix

defaults_json="$(flake_eval_json '
  actual = import ./vars.nix { inherit lib; };
  example = import ./vars.example.nix { inherit lib; };
  opinionated = vars: {
    inherit (vars) backupAccess fileAccess monitoringAccess offlineMedia;
    canaryUser = vars.identity.canaryUser;
    adminMailAddresses = vars.identity.adminMailAddresses;
    adminEmail = vars.identity.adminEmail;
    inherit (vars) domain;
    dns = vars.networking.dns;
    inherit (vars) kopiaDomain rcloneMega zfsDataPool;
    ports = vars.networking.ports;
  };
in {
  actual = opinionated actual;
  example = opinionated example;
}
')"

if ! jq -e '
  def stable:
    .canaryUser == "canary-user"
    and .adminMailAddresses == [.adminEmail]
    and .dns.privacyMode == "encrypted-only"
    and .dns.lanDomain == "internal"
    and .fileAccess.webAccessGroup == "files-personal-users"
    and .fileAccess.sftpAccessGroup == "files-sftp-users"
    and .fileAccess.localSftpAccessGroup == "files-local-sftp-users"
    and .fileAccess.sharedAccessGroup == "files-shared-users"
    and .fileAccess.deleteSharedAccessGroup == "delete_shared_files"
    and .fileAccess.usbAccessGroup == "usb-access"
    and .fileAccess.sharedMountName == "_Shared"
    and .fileAccess.usbMountName == "_USB"
    and .fileAccess.sftpChrootBase == "/srv/files-sftp/chroots"
    and .backupAccess.adminGroup == "backup-admin"
    and .backupAccess.storageGroup == "backup-storage-users"
    and .backupAccess.storageGid == 2005
    and .backupAccess.storageMountName == "_Backups"
    and .monitoringAccess.group == "monitoring-users"
    and .offlineMedia.musicFolderName == "_Music"
    and .offlineMedia.stateDir == "/persist/appdata/offline-media"
    and .offlineMedia.musicFolderIdPrefix == "nixhomeserver-music"
    and .offlineMedia.youtubeFolderIdPrefix == "nixhomeserver-youtube-videos"
    and .offlineMedia.otherFolderIdPrefix == "nixhomeserver-other-videos"
    and .offlineMedia.accessGroup == "users"
    and .zfsDataPool.name == "data"
    and .zfsDataPool.mountPoint == "/mnt/data"
    and .zfsDataPool.datasets == ["users", "shared", "backups"]
    and .ports.http == 80
    and .ports.https == 443
    and .ports.filesSftp == 2222
    and .rcloneMega.remoteName == "mega"
    and .rcloneMega.destination == "mega:NixHomeServer/kopia"
    and .rcloneMega.syncOnCalendar == "*-*-* 04,16:30:00"
    and .rcloneMega.repositoryLimitBytes == 20401094656
    and .kopiaDomain == ("kopia." + .domain);

  (.actual | stable)
  and (.example | stable)
  and .actual.monitoringAccess.users == ["admindsaw", "canary-user"]
  and .example.monitoringAccess.users == ["kanidm-admin", "canary-user"]
' <<<"$defaults_json" >/dev/null; then
  echo "❌ Opinionated vars defaults or operator-specific access policy regressed." >&2
  jq . <<<"$defaults_json" >&2
  exit 1
fi

echo "✅ Opinionated vars defaults and focused operator settings tests passed."
