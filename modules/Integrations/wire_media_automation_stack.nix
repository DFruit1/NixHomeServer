{ config, lib, options, pkgs, vars, ... }:

let
  storageValidation = import ../../lib/storage-validation.nix { inherit lib; };
  hasRepoModule = name: lib.hasAttrByPath [ "repo" name ] options;
  appEnabled = name:
    hasRepoModule name
    && lib.attrByPath [ "repo" name "enable" ] false config;
  chaptarrEnabled = appEnabled "chaptarr";
  sonarrEnabled = appEnabled "sonarr";
  radarrEnabled = appEnabled "radarr";
  prowlarrEnabled = appEnabled "prowlarr";
  qbittorrentEnabled = appEnabled "qbittorrent";
  jellyfinPresent = hasRepoModule "jellyfin";
  audiobookshelfPresent = hasRepoModule "audiobookshelf";
  kavitaPresent = hasRepoModule "kavita";
  # Jellyfin is enabled by importing its module; unlike the Arr modules, it
  # intentionally has no separate repo.jellyfin.enable switch.
  jellyfinEnabled = jellyfinPresent;
  enabled =
    chaptarrEnabled
    || sonarrEnabled
    || radarrEnabled
    || prowlarrEnabled
    || qbittorrentEnabled;
  videoLayoutEnabled = sonarrEnabled || radarrEnabled;
  storageLayoutEnabled = videoLayoutEnabled || qbittorrentEnabled;
  loopback = vars.networking.loopbackIPv4;
  ports = vars.networking.ports;
  qbitPathsRaw =
    if hasRepoModule "qbittorrent" then
      config.repo.qbittorrent.paths
    else
      rec {
        downloadRoot = "${vars.sharedRoot}/_Downloads/qbittorrent";
        incompleteDir = "${downloadRoot}/incomplete";
        completeDir = "${downloadRoot}/complete";
        moviesDir = "${completeDir}/movies";
        tvDir = "${completeDir}/tv";
        prowlarrDir = "${vars.sharedRoot}/_Downloads/prowlarr";
      };
  qbitPaths = qbitPathsRaw // {
    downloadRoot = lib.removeSuffix "/" qbitPathsRaw.downloadRoot;
    completeDir = lib.removeSuffix "/" qbitPathsRaw.completeDir;
  };
  sharedVideosRoot =
    if jellyfinPresent then config.repo.jellyfin.paths.sharedVideosRoot
    else "${vars.sharedRoot}/_Videos";
  moviesRoot = "${sharedVideosRoot}/_Movies";
  showsRoot = "${sharedVideosRoot}/_Shows";
  booksDownloadDir = "${qbitPaths.completeDir}/books";
  qbitDownloadRootPrefix = "${qbitPaths.downloadRoot}/";
  qbitCompleteDirWithinDownloadRoot =
    qbitPaths.completeDir != qbitPaths.downloadRoot
    && lib.hasPrefix qbitDownloadRootPrefix "${qbitPaths.completeDir}/";
  qbitCompleteRelativeDir = lib.removePrefix qbitDownloadRootPrefix qbitPaths.completeDir;
  mediaAutomationTraversalDirs =
    [ vars.sharedRoot ]
    ++ lib.optional videoLayoutEnabled sharedVideosRoot;
  automationPath = with pkgs; [
    acl
    coreutils
    curl
    findutils
    gnugrep
    gnused
    jq
  ];
  reconcileServiceConfig = {
    Type = "oneshot";
    Restart = "on-failure";
    RestartSec = "30s";
  };
in
{
  config = lib.mkIf enabled {
    assertions = lib.optionals (chaptarrEnabled && qbittorrentEnabled) [
      {
        assertion =
          storageValidation.validAbsolutePath qbitPaths.downloadRoot
          && storageValidation.validAbsolutePath qbitPaths.completeDir;
        message = "qBittorrent download paths used by Chaptarr must be normalized absolute paths without traversal components.";
      }
      {
        assertion = lib.removeSuffix "/" config.repo.chaptarr.paths.downloadRoot == qbitPaths.downloadRoot;
        message = "Chaptarr and qBittorrent must use the same host download root for remote-path translation.";
      }
      {
        assertion = qbitCompleteDirWithinDownloadRoot;
        message = "qBittorrent's completed-download directory must be below its download root so Chaptarr can translate it into /downloads.";
      }
    ];

    repo = {
      storage.sharedRoots.contentSubdirs = lib.mkIf storageLayoutEnabled (
        lib.optional qbittorrentEnabled "_Downloads"
          ++ lib.optional videoLayoutEnabled "_Videos"
      );

      storage.dataPool.guardedServices =
        lib.optional storageLayoutEnabled "media-automation-storage-layout-v1"
          ++ lib.optional qbittorrentEnabled "qbittorrent"
          ++ lib.optional sonarrEnabled "sonarr"
          ++ lib.optional radarrEnabled "radarr"
          ++ lib.optional qbittorrentEnabled "media-automation-bootstrap-qbittorrent"
          ++ lib.optional (prowlarrEnabled && qbittorrentEnabled) "media-automation-bootstrap-prowlarr-qbittorrent"
          ++ lib.optional (sonarrEnabled && qbittorrentEnabled) "media-automation-bootstrap-sonarr"
          ++ lib.optional (radarrEnabled && qbittorrentEnabled) "media-automation-bootstrap-radarr"
          ++ lib.optional (chaptarrEnabled && qbittorrentEnabled) "media-automation-bootstrap-chaptarr"
          ++ lib.optional (prowlarrEnabled && (sonarrEnabled || radarrEnabled || chaptarrEnabled)) "media-automation-bootstrap-prowlarr";
    } // lib.optionalAttrs (hasRepoModule "chaptarr") {
      chaptarr.paths = lib.mkIf chaptarrEnabled (lib.mkMerge [
        (lib.optionalAttrs audiobookshelfPresent {
          audiobookRoot = lib.mkDefault config.repo.audiobookshelf.paths.sharedAudiobooksRoot;
        })
        (lib.optionalAttrs kavitaPresent {
          ebookRoot = lib.mkDefault "${config.repo.kavita.paths.sharedBooksRoot}/_Ebooks";
        })
      ]);
    };

    systemd.services.chaptarr-storage-layout-v1 = lib.mkIf chaptarrEnabled {
      wants =
        lib.optional audiobookshelfPresent "audiobookshelf-storage-layout-v1.service"
        ++ lib.optional kavitaPresent "kavita-storage-layout-v1.service";
      after =
        lib.optional audiobookshelfPresent "audiobookshelf-storage-layout-v1.service"
        ++ lib.optional kavitaPresent "kavita-storage-layout-v1.service";
    };

    systemd.services.media-automation-storage-layout-v1 = lib.mkIf storageLayoutEnabled {
      description = "Provision shared storage for media automation";
      wantedBy = [ "multi-user.target" ];
      wants = [
        "data-pool-layout.service"
        "local-fs.target"
      ] ++ lib.optional jellyfinEnabled "jellyfin-storage-layout-v1.service";
      after = [
        "data-pool-layout.service"
        "local-fs.target"
      ] ++ lib.optional jellyfinEnabled "jellyfin-storage-layout-v1.service";
      before = [
        "sonarr.service"
        "radarr.service"
        "prowlarr.service"
        "qbittorrent.service"
        "media-automation-bootstrap-qbittorrent.service"
        "media-automation-bootstrap-sonarr.service"
        "media-automation-bootstrap-radarr.service"
        "media-automation-bootstrap-chaptarr.service"
        "media-automation-bootstrap-prowlarr.service"
        "media-automation-bootstrap-prowlarr-qbittorrent.service"
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      path = automationPath;
      script = ''
        set -euo pipefail

        ${lib.optionalString qbittorrentEnabled ''
          install -d -m 1770 -o root -g media-automation ${lib.escapeShellArg "${vars.sharedRoot}/_Downloads"}
        ''}
        for path in ${lib.escapeShellArgs mediaAutomationTraversalDirs}; do
          setfacl -m g:media-automation:--x "$path"
        done
        for path in ${lib.escapeShellArgs (
          lib.optionals qbittorrentEnabled [
            qbitPaths.downloadRoot
            qbitPaths.incompleteDir
            qbitPaths.completeDir
            qbitPaths.moviesDir
            qbitPaths.tvDir
            qbitPaths.prowlarrDir
          ]
          ++ lib.optional (chaptarrEnabled && qbittorrentEnabled) booksDownloadDir
          ++ lib.optional radarrEnabled moviesRoot
          ++ lib.optional sonarrEnabled showsRoot
        )}; do
          install -d -m 1770 -o root -g media-automation "$path"
          setfacl -m g:media-automation:rwX,d:g:media-automation:rwx "$path"
          ${lib.optionalString jellyfinEnabled ''
            setfacl -m g:jellyfin-media:rwX,d:g:jellyfin-media:rwx "$path"
          ''}
        done
        ${lib.optionalString (chaptarrEnabled && qbittorrentEnabled) ''
          setfacl -m g:chaptarr:r-X ${lib.escapeShellArgs [ qbitPaths.downloadRoot qbitPaths.completeDir ]}
          setfacl -m g:chaptarr:rwx,d:g:chaptarr:rwx ${lib.escapeShellArg booksDownloadDir}
          setfacl -P -R -m g:chaptarr:rwX ${lib.escapeShellArg booksDownloadDir}
          find ${lib.escapeShellArg booksDownloadDir} -type d -exec setfacl -m d:g:chaptarr:rwx '{}' +
        ''}
      '';
    };

    systemd.services.media-automation-bootstrap-qbittorrent = lib.mkIf qbittorrentEnabled {
      description = "Bootstrap qBittorrent media automation categories";
      wantedBy = [ "multi-user.target" ];
      wants = [
        "qbittorrent.service"
        "media-automation-storage-layout-v1.service"
      ];
      after = [
        "qbittorrent.service"
        "media-automation-storage-layout-v1.service"
      ];
      path = automationPath;
      serviceConfig = reconcileServiceConfig;
      script = ''
        set -euo pipefail

        qbit_url="http://${loopback}:${toString ports.qbittorrentWeb}"

        for _ in $(seq 1 60); do
          if curl --silent --show-error --fail "$qbit_url/api/v2/app/version" >/dev/null; then
            break
          fi
          sleep 1
        done
        curl --silent --show-error --fail "$qbit_url/api/v2/app/version" >/dev/null || {
          echo "qBittorrent HTTP endpoint is not ready; retrying media bootstrap." >&2
          exit 1
        }

        create_category() {
          local name="$1"
          local save_path="$2"
          curl --silent --show-error --fail \
            -X POST \
            -F "category=$name" \
            -F "savePath=$save_path" \
            "$qbit_url/api/v2/torrents/createCategory" >/dev/null || true
          curl --silent --show-error --fail \
            -X POST \
            -F "category=$name" \
            -F "savePath=$save_path" \
            "$qbit_url/api/v2/torrents/editCategory" >/dev/null
        }

        create_category movies ${lib.escapeShellArg qbitPaths.moviesDir}
        create_category tv ${lib.escapeShellArg qbitPaths.tvDir}
        create_category prowlarr ${lib.escapeShellArg qbitPaths.prowlarrDir}
        ${lib.optionalString chaptarrEnabled ''
          create_category books ${lib.escapeShellArg booksDownloadDir}
        ''}

        remove_empty_legacy_category() {
          local name="$1"
          local torrent_count

          torrent_count="$(
            curl --silent --show-error --fail --get \
              --data-urlencode "category=$name" \
              "$qbit_url/api/v2/torrents/info" \
              | jq 'length'
          )"

          if [[ "$torrent_count" == "0" ]]; then
            curl --silent --show-error --fail \
              -X POST \
              --data-urlencode "categories=$name" \
              "$qbit_url/api/v2/torrents/removeCategories" >/dev/null || true
          fi
        }

        remove_empty_legacy_category radarr
        remove_empty_legacy_category tv-sonarr
      '';
    };

    systemd.services.media-automation-bootstrap-prowlarr-qbittorrent = lib.mkIf (prowlarrEnabled && qbittorrentEnabled) {
      description = "Bootstrap Prowlarr direct qBittorrent download client";
      wantedBy = [ "multi-user.target" ];
      wants = [
        "prowlarr.service"
        "qbittorrent.service"
        "media-automation-storage-layout-v1.service"
        "media-automation-bootstrap-qbittorrent.service"
      ];
      after = [
        "prowlarr.service"
        "qbittorrent.service"
        "media-automation-storage-layout-v1.service"
        "media-automation-bootstrap-qbittorrent.service"
      ];
      path = automationPath;
      serviceConfig = reconcileServiceConfig;
      script = ''
        set -euo pipefail

        prowlarr_config=/var/lib/prowlarr/config.xml
        prowlarr_url="http://${loopback}:${toString ports.prowlarr}"
        qbit_host=${lib.escapeShellArg loopback}
        qbit_port=${toString ports.qbittorrentWeb}

        for _ in $(seq 1 120); do
          [[ -f "$prowlarr_config" ]] && grep -q '<ApiKey>' "$prowlarr_config" && break
          sleep 1
        done
        [[ -f "$prowlarr_config" ]] || {
          echo "Prowlarr configuration is not ready; retrying media bootstrap." >&2
          exit 1
        }
        prowlarr_key="$(sed -n 's:.*<ApiKey>\(.*\)</ApiKey>.*:\1:p' "$prowlarr_config" | head -n1)"
        [[ -n "$prowlarr_key" ]] || {
          echo "Prowlarr API key is not ready; retrying media bootstrap." >&2
          exit 1
        }

        papi() {
          curl --silent --show-error --fail -H "X-Api-Key: $prowlarr_key" "$@"
        }

        for _ in $(seq 1 60); do
          if papi "$prowlarr_url/api/v1/system/status" >/dev/null; then
            break
          fi
          sleep 1
        done
        papi "$prowlarr_url/api/v1/system/status" >/dev/null || {
          echo "Prowlarr HTTP endpoint is not ready; retrying media bootstrap." >&2
          exit 1
        }

        existing_id="$(papi "$prowlarr_url/api/v1/downloadclient" | jq -r '.[] | select(.name == "qBittorrent") | .id' | head -n1)"
        payload="$(
          papi "$prowlarr_url/api/v1/downloadclient/schema" \
            | jq -c \
              --arg host "$qbit_host" \
              --arg port "$qbit_port" \
              '
              map(select(.implementation == "QBittorrent"))[0]
              | .name = "qBittorrent"
              | .enable = true
              | if has("protocol") then .protocol = "torrent" else . end
              | if has("priority") then .priority = 1 else . end
              | .fields = (.fields | map(
                  if .name == "host" then .value = $host
                  elif .name == "port" then .value = ($port | tonumber)
                  elif .name == "useSsl" then .value = false
                  elif .name == "urlBase" then .value = ""
                  elif .name == "apiKey" then .value = ""
                  elif .name == "username" then .value = ""
                  elif .name == "password" then .value = ""
                  elif .name == "category" then .value = "prowlarr"
                  elif .name == "priority" then .value = 0
                  elif .name == "initialState" then .value = 0
                  elif .name == "sequentialOrder" then .value = false
                  elif .name == "firstAndLast" then .value = false
                  elif .name == "contentLayout" then .value = 0
                  else .
                  end
                ))'
        )"

        [[ -n "$payload" && "$payload" != "null" ]] || {
          echo "Prowlarr did not expose a qBittorrent client schema; retrying media bootstrap." >&2
          exit 1
        }
        if [[ -n "$existing_id" && "$existing_id" != "null" ]]; then
          jq --argjson id "$existing_id" '.id = $id' <<<"$payload" \
            | papi -X PUT -H 'Content-Type: application/json' --data-binary @- "$prowlarr_url/api/v1/downloadclient/$existing_id" >/dev/null
        else
          papi -X POST -H 'Content-Type: application/json' --data-binary "$payload" "$prowlarr_url/api/v1/downloadclient" >/dev/null
        fi
      '';
    };

    systemd.services.media-automation-bootstrap-sonarr = lib.mkIf (sonarrEnabled && qbittorrentEnabled) {
      description = "Bootstrap Sonarr media automation settings";
      wantedBy = [ "multi-user.target" ];
      wants = [
        "sonarr.service"
        "qbittorrent.service"
        "media-automation-storage-layout-v1.service"
        "media-automation-bootstrap-qbittorrent.service"
      ];
      after = [
        "sonarr.service"
        "qbittorrent.service"
        "media-automation-storage-layout-v1.service"
        "media-automation-bootstrap-qbittorrent.service"
      ];
      path = automationPath;
      serviceConfig = reconcileServiceConfig;
      script = ''
        set -euo pipefail

        config_xml=/var/lib/sonarr/.config/NzbDrone/config.xml
        base_url="http://${loopback}:${toString ports.sonarr}"
        qbit_host=${lib.escapeShellArg loopback}
        qbit_port=${toString ports.qbittorrentWeb}
        root_path=${lib.escapeShellArg showsRoot}

        for _ in $(seq 1 120); do
          [[ -f "$config_xml" ]] && grep -q '<ApiKey>' "$config_xml" && break
          sleep 1
        done
        [[ -f "$config_xml" ]] || {
          echo "Sonarr configuration is not ready; retrying media bootstrap." >&2
          exit 1
        }
        api_key="$(sed -n 's:.*<ApiKey>\(.*\)</ApiKey>.*:\1:p' "$config_xml" | head -n1)"
        [[ -n "$api_key" ]] || {
          echo "Sonarr API key is not ready; retrying media bootstrap." >&2
          exit 1
        }

        api() {
          curl --silent --show-error --fail -H "X-Api-Key: $api_key" "$@"
        }

        for _ in $(seq 1 60); do
          if api "$base_url/api/v3/system/status" >/dev/null; then
            break
          fi
          sleep 1
        done
        api "$base_url/api/v3/system/status" >/dev/null || {
          echo "Sonarr HTTP endpoint is not ready; retrying media bootstrap." >&2
          exit 1
        }

        if ! api "$base_url/api/v3/rootfolder" | jq -e --arg path "$root_path" '.[] | select(.path == $path)' >/dev/null; then
          jq -n --arg path "$root_path" '{path: $path}' \
            | api -X POST -H 'Content-Type: application/json' --data-binary @- "$base_url/api/v3/rootfolder" >/dev/null
        fi

        existing_id="$(api "$base_url/api/v3/downloadclient" | jq -r '.[] | select(.name == "qBittorrent") | .id' | head -n1)"
        payload="$(
          api "$base_url/api/v3/downloadclient/schema" \
            | jq -c \
              --arg host "$qbit_host" \
              --arg port "$qbit_port" \
              '
              map(select(.implementation == "QBittorrent"))[0]
              | .name = "qBittorrent"
              | .enable = true
              | .protocol = "torrent"
              | .priority = 1
              | .removeCompletedDownloads = false
              | .removeFailedDownloads = true
              | .fields = (.fields | map(
                  if .name == "host" then .value = $host
                  elif .name == "port" then .value = ($port | tonumber)
                  elif .name == "useSsl" then .value = false
                  elif .name == "urlBase" then .value = ""
                  elif .name == "username" then .value = ""
                  elif .name == "password" then .value = ""
                  elif .name == "category" then .value = "tv"
                  elif .name == "recentPriority" then .value = 0
                  elif .name == "olderPriority" then .value = 0
                  elif .name == "initialState" then .value = 0
                  else .
                  end
                ))'
        )"

        [[ -n "$payload" && "$payload" != "null" ]] || {
          echo "Sonarr did not expose a qBittorrent client schema; retrying media bootstrap." >&2
          exit 1
        }
        if [[ -n "$existing_id" && "$existing_id" != "null" ]]; then
          jq --argjson id "$existing_id" '.id = $id' <<<"$payload" \
            | api -X PUT -H 'Content-Type: application/json' --data-binary @- "$base_url/api/v3/downloadclient/$existing_id" >/dev/null
        else
          api -X POST -H 'Content-Type: application/json' --data-binary "$payload" "$base_url/api/v3/downloadclient" >/dev/null
        fi
      '';
    };

    systemd.services.media-automation-bootstrap-radarr = lib.mkIf (radarrEnabled && qbittorrentEnabled) {
      description = "Bootstrap Radarr media automation settings";
      wantedBy = [ "multi-user.target" ];
      wants = [
        "radarr.service"
        "qbittorrent.service"
        "media-automation-storage-layout-v1.service"
        "media-automation-bootstrap-qbittorrent.service"
      ];
      after = [
        "radarr.service"
        "qbittorrent.service"
        "media-automation-storage-layout-v1.service"
        "media-automation-bootstrap-qbittorrent.service"
      ];
      path = automationPath;
      serviceConfig = reconcileServiceConfig;
      script = ''
        set -euo pipefail

        config_xml=/var/lib/radarr/.config/Radarr/config.xml
        base_url="http://${loopback}:${toString ports.radarr}"
        qbit_host=${lib.escapeShellArg loopback}
        qbit_port=${toString ports.qbittorrentWeb}
        root_path=${lib.escapeShellArg moviesRoot}

        for _ in $(seq 1 120); do
          [[ -f "$config_xml" ]] && grep -q '<ApiKey>' "$config_xml" && break
          sleep 1
        done
        [[ -f "$config_xml" ]] || {
          echo "Radarr configuration is not ready; retrying media bootstrap." >&2
          exit 1
        }
        api_key="$(sed -n 's:.*<ApiKey>\(.*\)</ApiKey>.*:\1:p' "$config_xml" | head -n1)"
        [[ -n "$api_key" ]] || {
          echo "Radarr API key is not ready; retrying media bootstrap." >&2
          exit 1
        }

        api() {
          curl --silent --show-error --fail -H "X-Api-Key: $api_key" "$@"
        }

        for _ in $(seq 1 60); do
          if api "$base_url/api/v3/system/status" >/dev/null; then
            break
          fi
          sleep 1
        done
        api "$base_url/api/v3/system/status" >/dev/null || {
          echo "Radarr HTTP endpoint is not ready; retrying media bootstrap." >&2
          exit 1
        }

        if ! api "$base_url/api/v3/rootfolder" | jq -e --arg path "$root_path" '.[] | select(.path == $path)' >/dev/null; then
          jq -n --arg path "$root_path" '{path: $path}' \
            | api -X POST -H 'Content-Type: application/json' --data-binary @- "$base_url/api/v3/rootfolder" >/dev/null
        fi

        existing_id="$(api "$base_url/api/v3/downloadclient" | jq -r '.[] | select(.name == "qBittorrent") | .id' | head -n1)"
        payload="$(
          api "$base_url/api/v3/downloadclient/schema" \
            | jq -c \
              --arg host "$qbit_host" \
              --arg port "$qbit_port" \
              '
              map(select(.implementation == "QBittorrent"))[0]
              | .name = "qBittorrent"
              | .enable = true
              | .protocol = "torrent"
              | .priority = 1
              | .removeCompletedDownloads = false
              | .removeFailedDownloads = true
              | .fields = (.fields | map(
                  if .name == "host" then .value = $host
                  elif .name == "port" then .value = ($port | tonumber)
                  elif .name == "useSsl" then .value = false
                  elif .name == "urlBase" then .value = ""
                  elif .name == "username" then .value = ""
                  elif .name == "password" then .value = ""
                  elif .name == "category" then .value = "movies"
                  elif .name == "recentPriority" then .value = 0
                  elif .name == "olderPriority" then .value = 0
                  elif .name == "initialState" then .value = 0
                  else .
                  end
                ))'
        )"

        [[ -n "$payload" && "$payload" != "null" ]] || {
          echo "Radarr did not expose a qBittorrent client schema; retrying media bootstrap." >&2
          exit 1
        }
        if [[ -n "$existing_id" && "$existing_id" != "null" ]]; then
          jq --argjson id "$existing_id" '.id = $id' <<<"$payload" \
            | api -X PUT -H 'Content-Type: application/json' --data-binary @- "$base_url/api/v3/downloadclient/$existing_id" >/dev/null
        else
          api -X POST -H 'Content-Type: application/json' --data-binary "$payload" "$base_url/api/v3/downloadclient" >/dev/null
        fi
      '';
    };

    systemd.services.media-automation-bootstrap-chaptarr = lib.mkIf (chaptarrEnabled && qbittorrentEnabled)
      (import ./helpers/chaptarr-qbittorrent-bootstrap.nix {
        inherit
          config
          lib
          automationPath
          reconcileServiceConfig
          loopback
          ports
          ;
        hostCompleteDir = qbitPaths.completeDir;
        containerCompleteDir = "/downloads/${qbitCompleteRelativeDir}";
      });

    systemd.services.media-automation-bootstrap-prowlarr = lib.mkIf (prowlarrEnabled && (sonarrEnabled || radarrEnabled || chaptarrEnabled)) {
      description = "Bootstrap Prowlarr application links";
      wantedBy = [ "multi-user.target" ];
      wants = [
        "prowlarr.service"
      ]
      ++ lib.optional sonarrEnabled "sonarr.service"
      ++ lib.optional radarrEnabled "radarr.service"
      ++ lib.optional chaptarrEnabled "chaptarr.service"
      ++ lib.optional storageLayoutEnabled "media-automation-storage-layout-v1.service";
      after = [
        "prowlarr.service"
      ]
      ++ lib.optional sonarrEnabled "sonarr.service"
      ++ lib.optional radarrEnabled "radarr.service"
      ++ lib.optional chaptarrEnabled "chaptarr.service"
      ++ lib.optional storageLayoutEnabled "media-automation-storage-layout-v1.service";
      path = automationPath;
      serviceConfig = reconcileServiceConfig // {
        RuntimeDirectory = "media-automation-bootstrap-prowlarr";
        RuntimeDirectoryMode = "0700";
      };
      script = ''
        set -euo pipefail

        prowlarr_config=/var/lib/prowlarr/config.xml
        prowlarr_url="http://${loopback}:${toString ports.prowlarr}"
        required_configs=("$prowlarr_config")
        ${lib.optionalString sonarrEnabled ''
          sonarr_config=/var/lib/sonarr/.config/NzbDrone/config.xml
          required_configs+=("$sonarr_config")
        ''}
        ${lib.optionalString radarrEnabled ''
          radarr_config=/var/lib/radarr/.config/Radarr/config.xml
          required_configs+=("$radarr_config")
        ''}
        ${lib.optionalString chaptarrEnabled ''
          chaptarr_config=${lib.escapeShellArg "${config.repo.chaptarr.paths.stateDir}/config.xml"}
          required_configs+=("$chaptarr_config")
        ''}

        read_api_key() {
          [[ -f "$1" ]] || return 0
          sed -n 's:.*<ApiKey>\(.*\)</ApiKey>.*:\1:p' "$1" | head -n1
        }

        all_api_keys_ready() {
          local config_file
          for config_file in "''${required_configs[@]}"; do
            [[ -f "$config_file" ]] && grep -q '<ApiKey>' "$config_file" || return 1
          done
        }

        for _ in $(seq 1 120); do
          all_api_keys_ready && break
          sleep 1
        done

        prowlarr_key="$(read_api_key "$prowlarr_config")"
        [[ -n "$prowlarr_key" ]] || {
          echo "Prowlarr API key is not ready; retrying media bootstrap." >&2
          exit 1
        }
        ${lib.optionalString sonarrEnabled ''
          sonarr_key="$(read_api_key "$sonarr_config")"
          [[ -n "$sonarr_key" ]] || {
            echo "Sonarr API key is not ready; retrying media bootstrap." >&2
            exit 1
          }
        ''}
        ${lib.optionalString radarrEnabled ''
          radarr_key="$(read_api_key "$radarr_config")"
          [[ -n "$radarr_key" ]] || {
            echo "Radarr API key is not ready; retrying media bootstrap." >&2
            exit 1
          }
        ''}
        ${lib.optionalString chaptarrEnabled ''
          chaptarr_key="$(read_api_key "$chaptarr_config")"
          [[ -n "$chaptarr_key" ]] || {
            echo "Chaptarr API key is not ready; retrying media bootstrap." >&2
            exit 1
          }
        ''}

        umask 077
        runtime_dir=/run/media-automation-bootstrap-prowlarr
        papi_header="$runtime_dir/api-header"
        install -m 0600 /dev/null "$papi_header"
        api_key_files=()
        trap 'rm -f "$papi_header" "''${api_key_files[@]}"' EXIT
        printf 'X-Api-Key: %s\n' "$prowlarr_key" > "$papi_header"

        papi() {
          curl --silent --show-error --fail -H "@$papi_header" "$@"
        }

        for _ in $(seq 1 60); do
          if papi "$prowlarr_url/api/v1/system/status" >/dev/null; then
            break
          fi
          sleep 1
        done
        papi "$prowlarr_url/api/v1/system/status" >/dev/null || {
          echo "Prowlarr HTTP endpoint is not ready; retrying media bootstrap." >&2
          exit 1
        }

        upsert_app() {
          local name="$1"
          local implementation="$2"
          local base_url="$3"
          local api_key="$4"
          local sync_categories="$5"
          local existing_id
          local payload
          local api_key_file

          api_key_file="$(mktemp "$runtime_dir/api-key.XXXXXX")"
          api_key_files+=("$api_key_file")
          printf '%s' "$api_key" > "$api_key_file"

          existing_id="$(papi "$prowlarr_url/api/v1/applications" | jq -r --arg name "$name" '.[] | select(.name == $name) | .id' | head -n1)"
          payload="$(
            papi "$prowlarr_url/api/v1/applications/schema" \
              | jq -c \
                --arg implementation "$implementation" \
                --arg name "$name" \
                --arg baseUrl "$base_url" \
                --arg prowlarrUrl "$prowlarr_url" \
                --rawfile apiKey "$api_key_file" \
                --argjson syncCategories "$sync_categories" \
                '
                map(select(.implementation == $implementation))[0]
                | .name = $name
                | .enable = true
                | .syncLevel = "fullSync"
                | .fields = (.fields | map(
                    if .name == "baseUrl" then .value = $baseUrl
                    elif .name == "prowlarrUrl" then .value = $prowlarrUrl
                    elif .name == "apiKey" then .value = $apiKey
                    elif .name == "syncCategories" then .value = $syncCategories
                    else .
                    end
                  ))'
          )"
          rm -f "$api_key_file"

          [[ -n "$payload" && "$payload" != "null" ]] || {
            echo "Prowlarr did not expose the $implementation application schema; retrying media bootstrap." >&2
            return 1
          }
          if [[ -n "$existing_id" && "$existing_id" != "null" ]]; then
            jq --argjson id "$existing_id" '.id = $id' <<<"$payload" \
              | papi -X PUT -H 'Content-Type: application/json' --data-binary @- "$prowlarr_url/api/v1/applications/$existing_id" >/dev/null
          else
            printf '%s' "$payload" \
              | papi -X POST -H 'Content-Type: application/json' --data-binary @- "$prowlarr_url/api/v1/applications" >/dev/null
          fi
        }

        ${lib.optionalString sonarrEnabled ''
          upsert_app Sonarr Sonarr "http://${loopback}:${toString ports.sonarr}" "$sonarr_key" '[5000,5010,5020,5030,5040,5045,5050,5070,5080]'
        ''}
        ${lib.optionalString radarrEnabled ''
          upsert_app Radarr Radarr "http://${loopback}:${toString ports.radarr}" "$radarr_key" '[2000,2010,2020,2030,2040,2045,2050,2060,2070,2080]'
        ''}
        ${lib.optionalString chaptarrEnabled ''
          # Chaptarr exposes the Readarr-compatible API expected by Prowlarr.
          upsert_app Chaptarr Readarr "http://${loopback}:${toString ports.chaptarr}" "$chaptarr_key" '[3030,7000,7020]'
        ''}
      '';
    };

  };
}
