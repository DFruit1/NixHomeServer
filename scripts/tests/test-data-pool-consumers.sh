#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"
cd "$TESTS_REPO_ROOT"
ensure_tools jq nix

consumer_json="$(nix eval --json '.#nixosConfigurations.server.config' --apply 'cfg:
let
  names = [
    "paperless-storage-layout-v1" "paperless-consumer" "paperless-scheduler"
    "paperless-task-queue" "paperless-web" "paperless-exporter"
    "immich-storage-layout-v1" "immich-server"
    "kavita-storage-layout-v1" "kavita" "kavita-stale-reference-cleanup"
    "kiwix-library-root-layout-v1" "kiwix-library-sync" "kiwix-library-watch" "kiwix-serve"
    "mail-archive-ui-storage-layout-v1" "mail-archive-ui" "mail-archive-sync" "mail-archive-paperless-tasks"
    "media-automation-storage-layout-v1" "qbittorrent" "sonarr" "radarr"
    "offline-media-reconcile"
    "audiobookshelf-storage-layout-v1" "audiobookshelf"
    "media-folder-layout-v2" "jellyfin-storage-layout-v1" "jellyfin"
    "youtube-downloader" "filestash" "files-archives-sync" "files-archives-watch"
  ];
in {
  dataRoot = "/mnt/data";
  guarded = cfg.repo.storage.dataPool.guardedServices;
  layout = {
    restart = cfg.systemd.services.data-pool-layout.serviceConfig.Restart;
    restartSec = cfg.systemd.services.data-pool-layout.serviceConfig.RestartSec;
    startLimitInterval = cfg.systemd.services.data-pool-layout.unitConfig.StartLimitIntervalSec;
    startLimitBurst = cfg.systemd.services.data-pool-layout.unitConfig.StartLimitBurst;
  };
  services = map (name: {
    inherit name;
    requires = cfg.systemd.services.${name}.requires or [];
    after = cfg.systemd.services.${name}.after or [];
    condition = cfg.systemd.services.${name}.unitConfig.ConditionPathIsMountPoint or null;
  }) names;
}')"

jq -e '
  (.guarded | length == (unique | length))
  and (.layout == {
    restart: "on-failure",
    restartSec: "15s",
    startLimitInterval: "5min",
    startLimitBurst: 6
  })
  and (.services | all(
    (.requires | index("data-pool-layout.service") != null)
    and (.after | index("data-pool-layout.service") != null)
    and (.condition == $root)
  ))
' --arg root "$(jq -r .dataRoot <<<"$consumer_json")" \
  <<<"$consumer_json" >/dev/null || {
  echo "A data-pool consumer can start without a required layout and mountpoint guard." >&2
  jq '.services[] | select(
    (.requires | index("data-pool-layout.service") == null)
    or (.after | index("data-pool-layout.service") == null)
    or (.condition != "/mnt/data")
  )' <<<"$consumer_json"
  exit 1
}

echo "✅ Data-pool consumers fail closed when the pool layout is unavailable."
