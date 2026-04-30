{ lib, pkgs, vars, ... }:

let
  managedUnits = [
    "copyparty.service"
    "immich-machine-learning.service"
    "immich-server.service"
    "mail-archive-sync.service"
    "mail-archive-ui.service"
    "paperless-consumer.service"
    "paperless-scheduler.service"
    "paperless-task-queue.service"
    "paperless-web.service"
    "samba-smbd.service"
  ];
  retiredMediaRoot = "${vars.dataRoot}/media";
  retiredRoots = [
    "${vars.sharedRoot}/documents"
    "${vars.sharedRoot}/photos"
  ];
  retiredMediaDataset = "${vars.zfsDataPool.name}/media";
  markerRoot = "/persist/appdata/.nixos-managed/retired-content-roots-cleanup-v1";
  markerFile = "${markerRoot}/done";
in
{
  systemd.services.retired-content-roots-cleanup-v1 = {
    description = "Remove empty retired content roots from the live data pool";
    wantedBy = [ "multi-user.target" ];
    wants = [
      "data-pool-layout.service"
      "local-fs.target"
      "media-root-retirement-v1.service"
    ];
    after = [
      "data-pool-layout.service"
      "local-fs.target"
      "media-root-retirement-v1.service"
    ];
    before = managedUnits;
    unitConfig.ConditionPathIsMountPoint = vars.dataRoot;
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    path = [
      pkgs.coreutils
      pkgs.findutils
      pkgs.gnugrep
      pkgs.zfs
    ];
    script = ''
      set -euo pipefail

      marker_root='${markerRoot}'
      marker_file='${markerFile}'
      retired_media_root='${retiredMediaRoot}'
      retired_media_dataset='${retiredMediaDataset}'

      ensure_absent_or_empty_dir() {
        local path="$1"

        if [[ ! -e "$path" ]]; then
          return 0
        fi

        [[ -d "$path" ]] || {
          echo "retired root is not a directory: $path" >&2
          exit 1
        }

        if find "$path" -mindepth 1 -print -quit | grep -q .; then
          echo "retired root is not empty: $path" >&2
          exit 1
        fi

        rmdir "$path"
      }

      verify_retired_absent() {
        local path="$1"

        if [[ -e "$path" ]]; then
          echo "retired root reappeared after cleanup marker: $path" >&2
          exit 1
        fi
      }

      install -d -m 0755 "$marker_root"

      if [[ -f "$marker_file" ]]; then
        verify_retired_absent "$retired_media_root"
        ${lib.concatMapStringsSep "\n        " (retiredRoot: ''
          verify_retired_absent ${lib.escapeShellArg retiredRoot}
        '') retiredRoots}
        exit 0
      fi

      ${lib.concatMapStringsSep "\n      " (retiredRoot: ''
        ensure_absent_or_empty_dir ${lib.escapeShellArg retiredRoot}
      '') retiredRoots}

      if [[ -d "$retired_media_root" ]]; then
        if find "$retired_media_root" -mindepth 1 -print -quit | grep -q .; then
          echo "retired root is not empty: $retired_media_root" >&2
          exit 1
        fi

        if zfs list -H -o name "$retired_media_dataset" >/dev/null 2>&1; then
          zfs destroy "$retired_media_dataset"
        else
          rmdir "$retired_media_root"
        fi
      fi

      touch "$marker_file"
    '';
  };
}
