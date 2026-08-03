#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"
cd "$TESTS_REPO_ROOT"
ensure_tools jq nix rg

for vars_file in vars.nix vars.example.nix; do
  for operator_constant in \
    canaryUser \
    adminMailAddresses \
    privacyMode \
    lanDomain \
    lanHosts \
    webAccessGroup \
    sftpAccessGroup \
    localSftpAccessGroup \
    sharedAccessGroup \
    usbAccessGroup \
    sharedMountName \
    usbMountName \
    sftpChrootBase \
    adminGroup \
    storageGroup \
    storageGid \
    storageMountName \
    requestManagerGroup \
    musicFolderName \
    stateDir \
    musicFolderIdPrefix \
    youtubeFolderIdPrefix \
    otherFolderIdPrefix \
    accessGroup; do
    forbid_match \
      "$vars_file" \
      "^[[:space:]]+${operator_constant}[[:space:]]*=" \
      "${vars_file} should not expose the opinionated ${operator_constant} implementation constant."
  done

  forbid_match \
    "$vars_file" \
    '^[[:space:]]+monitoringAccess[[:space:]]*=' \
    "${vars_file} should not expose fixed monitoring access."
  forbid_match \
    "$vars_file" \
    '^[[:space:]]+advanced[[:space:]]*=' \
    "${vars_file} should not expose fixed loopback, port, or resolver settings."
  for kanidm_managed_access in fileAccess backupAccess seerrAccess; do
    forbid_match \
      "$vars_file" \
      "^[[:space:]]+${kanidm_managed_access}[[:space:]]*=" \
      "${vars_file} should leave ${kanidm_managed_access} membership to Kanidm groups."
  done
  forbid_match \
    "$vars_file" \
    '^[[:space:]]+binaryCaches[[:space:]]*=' \
    "${vars_file} should not expose the fixed official and community binary caches."
  for storage_constant in name mountPoint datasets; do
    forbid_match \
      "$vars_file" \
      "^[[:space:]]{8}${storage_constant}[[:space:]]*=" \
      "${vars_file} should not expose the fixed data-pool ${storage_constant}."
  done
  for offsite_constant in \
    remoteName \
    destination \
    randomizedDelaySec \
    transfers \
    checkers \
    warnPercent \
    criticalPercent; do
    forbid_match \
      "$vars_file" \
      "^[[:space:]]+${offsite_constant}[[:space:]]*=" \
      "${vars_file} should not expose the opinionated offsite ${offsite_constant}."
  done
  forbid_match \
    "$vars_file" \
    '^[[:space:]]+serviceSubdomains[[:space:]]*=' \
    "${vars_file} should not expose fixed service subdomains."
  require_match \
    "$vars_file" \
    'adminEmail[[:space:]]*=.*#[^\n]*(Kanidm|ACME)[^\n]*(Kanidm|ACME)' \
    "${vars_file} should explain that one admin email serves both ACME and Kanidm."
  require_match \
    "$vars_file" \
    'mode[[:space:]]*=.*#[^\n]*"split-horizon"[^\n]*"netbird-only"' \
    "${vars_file} should list every supported DNS mode inline."
  for commented_field in \
    sshPublicKey \
    lanPrefixLength \
    lanGateway \
    netbirdIp \
    netbirdCidr \
    expectedGuid \
    enable \
    email \
    syncOnCalendar \
    repositoryLimitBytes \
    users \
    shared; do
    require_match \
      "$vars_file" \
      "^[[:space:]]+${commented_field}[[:space:]]*=.*#[^\\n]+" \
      "${vars_file} should explain ${commented_field} inline."
  done
  require_match \
    "$vars_file" \
    'mirrorPairs[[:space:]]*=[[:space:]]*\[[[:space:]]*\n[[:space:]]*#[^\n]+' \
    "${vars_file} should explain the mirror-pair disk identifiers next to the list."
done

defaults_json="$(flake_eval_json '
  actual = import ./vars.nix { inherit lib; };
  example = import ./vars.example.nix { inherit lib; };
  opinionated = vars: {
    inherit (vars) backupAccess fileAccess monitoringAccess offlineMedia seerrAccess;
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
    and .fileAccess.usbAccessGroup == "usb-access"
    and .fileAccess.sharedMountName == "_Shared"
    and .fileAccess.usbMountName == "_USB"
    and .fileAccess.sftpChrootBase == "/srv/files-sftp/chroots"
    and .backupAccess.adminGroup == "backup-admin"
    and .backupAccess.storageGroup == "backup-storage-users"
    and .backupAccess.storageGid == 2005
    and .backupAccess.storageMountName == "_Backups"
    and .monitoringAccess.group == "monitoring-users"
    and .seerrAccess.requestManagerGroup == "seerr-request-managers"
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
