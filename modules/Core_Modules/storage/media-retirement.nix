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
  ];
  legacyMediaRoot = "${vars.dataRoot}/media";
  legacyPaperlessRoot = "${legacyMediaRoot}/documents";
  legacyImmichRoot = "${legacyMediaRoot}/photos";
  markerRoot = "/persist/appdata/.nixos-managed/media-root-retirement-v1";
  markerFile = "${markerRoot}/done";
in
{
  systemd.services.media-root-retirement-v1 = {
    description = "Migrate app-managed payloads out of /mnt/data/media";
    wantedBy = [ "multi-user.target" ];
    wants = [
      "data-pool-layout.service"
      "local-fs.target"
    ];
    after = [
      "data-pool-layout.service"
      "local-fs.target"
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
      pkgs.rsync
    ];
    script = ''
      set -euo pipefail

      marker_root='${markerRoot}'
      marker_file='${markerFile}'

      move_tree_contents() {
        local src="$1"
        local dest="$2"
        local verify_output=""

        if [[ ! -d "$src" ]]; then
          return 0
        fi

        install -d -m 0755 "$dest"

        rsync -aHAX --numeric-ids "$src"/ "$dest"/
        verify_output="$(rsync -nai --numeric-ids --no-times --omit-dir-times "$src"/ "$dest"/ || true)"
        if [[ -n "$verify_output" ]]; then
          echo "verification drift for $src -> $dest" >&2
          printf '%s\n' "$verify_output" >&2
          exit 1
        fi

        find "$src" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
        if find "$src" -mindepth 1 -print -quit | grep -q .; then
          echo "failed to empty legacy root: $src" >&2
          exit 1
        fi
      }

      install -d -m 0755 "$marker_root"
      if [[ -f "$marker_file" ]]; then
        exit 0
      fi

      install -d -m 0755 '${vars.paperlessRoot}' '${vars.immichRoot}'
      move_tree_contents '${legacyPaperlessRoot}' '${vars.paperlessRoot}'
      move_tree_contents '${legacyImmichRoot}' '${vars.immichRoot}'

      touch "$marker_file"
    '';
  };
}
