{ config, lib, pkgs, vars, ... }:

let
  enabled =
    (config.repo.seerr.enable or false)
    || (config.repo.sonarr.enable or false)
    || (config.repo.radarr.enable or false)
    || (config.repo.prowlarr.enable or false)
    || (config.repo.qbittorrent.enable or false);
  loopback = vars.networking.loopbackIPv4;
  ports = vars.networking.ports;
  qbitPaths = config.repo.qbittorrent.paths;
  moviesRoot = "${config.repo.jellyfin.paths.sharedVideosRoot}/_Movies";
  showsRoot = "${config.repo.jellyfin.paths.sharedVideosRoot}/_Shows";
  automationPath = with pkgs; [
    acl
    coreutils
    curl
    findutils
    gnugrep
    gnused
    jq
  ];
in
{
  config = lib.mkIf enabled {
    assertions = [
      {
        assertion = config.repo.jellyfin or null != null;
        message = "The media automation stack expects the regular Jellyfin module to be imported.";
      }
    ];

    repo.storage.sharedRoots.contentSubdirs = [
      "_Downloads"
    ];

    systemd.services.media-automation-storage-layout-v1 = {
      description = "Provision shared storage for media automation";
      wantedBy = [ "multi-user.target" ];
      wants = [
        "data-pool-layout.service"
        "jellyfin-storage-layout-v1.service"
        "local-fs.target"
      ];
      after = [
        "data-pool-layout.service"
        "jellyfin-storage-layout-v1.service"
        "local-fs.target"
      ];
      before = [
        "sonarr.service"
        "radarr.service"
        "qbittorrent.service"
      ];
      unitConfig.ConditionPathIsMountPoint = vars.dataRoot;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      path = automationPath;
      script = ''
        set -euo pipefail

        install -d -m 1770 -o root -g media-automation ${lib.escapeShellArg "${vars.sharedRoot}/_Downloads"}
        for path in ${lib.escapeShellArgs [
          qbitPaths.downloadRoot
          qbitPaths.incompleteDir
          qbitPaths.completeDir
          qbitPaths.moviesDir
          qbitPaths.tvDir
          moviesRoot
          showsRoot
        ]}; do
          install -d -m 1770 -o root -g media-automation "$path"
          setfacl -m g:media-automation:rwX,d:g:media-automation:rwx "$path"
          setfacl -m g:jellyfin-media:rwX,d:g:jellyfin-media:rwx "$path"
        done
      '';
    };

    systemd.services.media-automation-bootstrap-qbittorrent = lib.mkIf config.repo.qbittorrent.enable {
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
      serviceConfig.Type = "oneshot";
      script = ''
        set -euo pipefail

        qbit_url="http://${loopback}:${toString ports.qbittorrentWeb}"

        for _ in $(seq 1 60); do
          if curl --silent --show-error --fail "$qbit_url/api/v2/app/version" >/dev/null; then
            break
          fi
          sleep 1
        done

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
            "$qbit_url/api/v2/torrents/editCategory" >/dev/null || true
        }

        create_category movies ${lib.escapeShellArg qbitPaths.moviesDir}
        create_category tv ${lib.escapeShellArg qbitPaths.tvDir}
      '';
    };

    systemd.services.media-automation-bootstrap-sonarr = lib.mkIf (config.repo.sonarr.enable && config.repo.qbittorrent.enable) {
      description = "Bootstrap Sonarr media automation settings";
      wantedBy = [ "multi-user.target" ];
      wants = [
        "sonarr.service"
        "qbittorrent.service"
        "media-automation-bootstrap-qbittorrent.service"
      ];
      after = [
        "sonarr.service"
        "qbittorrent.service"
        "media-automation-bootstrap-qbittorrent.service"
      ];
      path = automationPath;
      serviceConfig.Type = "oneshot";
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
        api_key="$(sed -n 's:.*<ApiKey>\(.*\)</ApiKey>.*:\1:p' "$config_xml" | head -n1)"
        [[ -n "$api_key" ]] || exit 0

        api() {
          curl --silent --show-error --fail -H "X-Api-Key: $api_key" "$@"
        }

        for _ in $(seq 1 60); do
          if api "$base_url/api/v3/system/status" >/dev/null; then
            break
          fi
          sleep 1
        done

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

        if [[ -n "$payload" && "$payload" != "null" ]]; then
          if [[ -n "$existing_id" && "$existing_id" != "null" ]]; then
            jq --argjson id "$existing_id" '.id = $id' <<<"$payload" \
              | api -X PUT -H 'Content-Type: application/json' --data-binary @- "$base_url/api/v3/downloadclient/$existing_id" >/dev/null
          else
            api -X POST -H 'Content-Type: application/json' --data-binary "$payload" "$base_url/api/v3/downloadclient" >/dev/null
          fi
        fi
      '';
    };

    systemd.services.media-automation-bootstrap-radarr = lib.mkIf (config.repo.radarr.enable && config.repo.qbittorrent.enable) {
      description = "Bootstrap Radarr media automation settings";
      wantedBy = [ "multi-user.target" ];
      wants = [
        "radarr.service"
        "qbittorrent.service"
        "media-automation-bootstrap-qbittorrent.service"
      ];
      after = [
        "radarr.service"
        "qbittorrent.service"
        "media-automation-bootstrap-qbittorrent.service"
      ];
      path = automationPath;
      serviceConfig.Type = "oneshot";
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
        api_key="$(sed -n 's:.*<ApiKey>\(.*\)</ApiKey>.*:\1:p' "$config_xml" | head -n1)"
        [[ -n "$api_key" ]] || exit 0

        api() {
          curl --silent --show-error --fail -H "X-Api-Key: $api_key" "$@"
        }

        for _ in $(seq 1 60); do
          if api "$base_url/api/v3/system/status" >/dev/null; then
            break
          fi
          sleep 1
        done

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

        if [[ -n "$payload" && "$payload" != "null" ]]; then
          if [[ -n "$existing_id" && "$existing_id" != "null" ]]; then
            jq --argjson id "$existing_id" '.id = $id' <<<"$payload" \
              | api -X PUT -H 'Content-Type: application/json' --data-binary @- "$base_url/api/v3/downloadclient/$existing_id" >/dev/null
          else
            api -X POST -H 'Content-Type: application/json' --data-binary "$payload" "$base_url/api/v3/downloadclient" >/dev/null
          fi
        fi
      '';
    };

    systemd.services.media-automation-bootstrap-prowlarr = lib.mkIf (config.repo.prowlarr.enable && config.repo.sonarr.enable && config.repo.radarr.enable) {
      description = "Bootstrap Prowlarr application links to Sonarr and Radarr";
      wantedBy = [ "multi-user.target" ];
      wants = [
        "prowlarr.service"
        "sonarr.service"
        "radarr.service"
      ];
      after = [
        "prowlarr.service"
        "sonarr.service"
        "radarr.service"
      ];
      path = automationPath;
      serviceConfig.Type = "oneshot";
      script = ''
        set -euo pipefail

        prowlarr_config=/var/lib/prowlarr/config.xml
        sonarr_config=/var/lib/sonarr/.config/NzbDrone/config.xml
        radarr_config=/var/lib/radarr/.config/Radarr/config.xml
        prowlarr_url="http://${loopback}:${toString ports.prowlarr}"

        read_api_key() {
          sed -n 's:.*<ApiKey>\(.*\)</ApiKey>.*:\1:p' "$1" | head -n1
        }

        for _ in $(seq 1 120); do
          [[ -f "$prowlarr_config" && -f "$sonarr_config" && -f "$radarr_config" ]] \
            && grep -q '<ApiKey>' "$prowlarr_config" \
            && grep -q '<ApiKey>' "$sonarr_config" \
            && grep -q '<ApiKey>' "$radarr_config" \
            && break
          sleep 1
        done

        prowlarr_key="$(read_api_key "$prowlarr_config")"
        sonarr_key="$(read_api_key "$sonarr_config")"
        radarr_key="$(read_api_key "$radarr_config")"
        [[ -n "$prowlarr_key" && -n "$sonarr_key" && -n "$radarr_key" ]] || exit 0

        papi() {
          curl --silent --show-error --fail -H "X-Api-Key: $prowlarr_key" "$@"
        }

        for _ in $(seq 1 60); do
          if papi "$prowlarr_url/api/v1/system/status" >/dev/null; then
            break
          fi
          sleep 1
        done

        upsert_app() {
          local name="$1"
          local implementation="$2"
          local base_url="$3"
          local api_key="$4"
          local sync_categories="$5"
          local existing_id
          local payload

          existing_id="$(papi "$prowlarr_url/api/v1/applications" | jq -r --arg name "$name" '.[] | select(.name == $name) | .id' | head -n1)"
          payload="$(
            papi "$prowlarr_url/api/v1/applications/schema" \
              | jq -c \
                --arg implementation "$implementation" \
                --arg name "$name" \
                --arg baseUrl "$base_url" \
                --arg prowlarrUrl "$prowlarr_url" \
                --arg apiKey "$api_key" \
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

          [[ -n "$payload" && "$payload" != "null" ]] || return 0
          if [[ -n "$existing_id" && "$existing_id" != "null" ]]; then
            jq --argjson id "$existing_id" '.id = $id' <<<"$payload" \
              | papi -X PUT -H 'Content-Type: application/json' --data-binary @- "$prowlarr_url/api/v1/applications/$existing_id" >/dev/null
          else
            papi -X POST -H 'Content-Type: application/json' --data-binary "$payload" "$prowlarr_url/api/v1/applications" >/dev/null
          fi
        }

        upsert_app Sonarr Sonarr "http://${loopback}:${toString ports.sonarr}" "$sonarr_key" '[5000,5010,5020,5030,5040,5045,5050,5070,5080]'
        upsert_app Radarr Radarr "http://${loopback}:${toString ports.radarr}" "$radarr_key" '[2000,2010,2020,2030,2040,2045,2050,2060,2070,2080]'
      '';
    };
  };
}
