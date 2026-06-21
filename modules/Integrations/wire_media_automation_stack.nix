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
  seerrManagedDir = "/var/lib/seerr/.nixos-managed";
  seerrJellyfinBootstrapUser = "seerr-bootstrap";
  seerrJellyfinBootstrapEmail = "seerr-bootstrap@${vars.domain}";
  seerrLibraryNamesJson = builtins.toJSON (
    map (library: "Shared ${library.label}") config.repo.jellyfin.libraries.shared
  );
  mediaAutomationTraversalDirs = [
    vars.sharedRoot
    config.repo.jellyfin.paths.sharedVideosRoot
  ];
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
        "prowlarr.service"
        "seerr.service"
        "qbittorrent.service"
        "media-automation-bootstrap-qbittorrent.service"
        "media-automation-bootstrap-sonarr.service"
        "media-automation-bootstrap-radarr.service"
        "media-automation-bootstrap-prowlarr.service"
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
        for path in ${lib.escapeShellArgs mediaAutomationTraversalDirs}; do
          setfacl -m g:media-automation:--x "$path"
        done
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

    systemd.services.media-automation-bootstrap-sonarr = lib.mkIf (config.repo.sonarr.enable && config.repo.qbittorrent.enable) {
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
        [[ -f "$config_xml" ]] || exit 0
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
        api "$base_url/api/v3/system/status" >/dev/null || exit 0

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
        [[ -f "$config_xml" ]] || exit 0
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
        api "$base_url/api/v3/system/status" >/dev/null || exit 0

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
        "media-automation-storage-layout-v1.service"
      ];
      after = [
        "prowlarr.service"
        "sonarr.service"
        "radarr.service"
        "media-automation-storage-layout-v1.service"
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
          [[ -f "$1" ]] || return 0
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
        papi "$prowlarr_url/api/v1/system/status" >/dev/null || exit 0

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

    systemd.services.media-automation-bootstrap-seerr = lib.mkIf config.repo.seerr.enable {
      description = "Bootstrap Seerr with Jellyfin, Sonarr, and Radarr";
      wantedBy = [ "multi-user.target" ];
      wants = [
        "seerr.service"
        "jellyfin.service"
        "jellyfin-library-bootstrap-v1.service"
        "media-automation-storage-layout-v1.service"
      ]
      ++ lib.optionals config.repo.sonarr.enable [
        "sonarr.service"
        "media-automation-bootstrap-sonarr.service"
      ]
      ++ lib.optionals config.repo.radarr.enable [
        "radarr.service"
        "media-automation-bootstrap-radarr.service"
      ];
      after = [
        "seerr.service"
        "jellyfin.service"
        "jellyfin-library-bootstrap-v1.service"
        "media-automation-storage-layout-v1.service"
      ]
      ++ lib.optionals config.repo.sonarr.enable [
        "sonarr.service"
        "media-automation-bootstrap-sonarr.service"
      ]
      ++ lib.optionals config.repo.radarr.enable [
        "radarr.service"
        "media-automation-bootstrap-radarr.service"
      ];
      path = automationPath ++ [ pkgs.openssl ];
      serviceConfig = {
        Type = "oneshot";
        Restart = "on-failure";
        RestartSec = "10s";
      };
      script = ''
        set -euo pipefail

        seerr_url="http://${loopback}:${toString ports.seerr}"
        jellyfin_url="http://${loopback}:${toString ports.jellyfin}"
        jellyfin_api_key_file="/var/lib/jellyfin/data/library-sync.api-key"
        managed_dir=${lib.escapeShellArg seerrManagedDir}
        jellyfin_bootstrap_user=${lib.escapeShellArg seerrJellyfinBootstrapUser}
        jellyfin_bootstrap_email=${lib.escapeShellArg seerrJellyfinBootstrapEmail}
        jellyfin_bootstrap_password_file="$managed_dir/jellyfin-bootstrap-password"
        cookie_file="$managed_dir/setup.cookies"
        desired_libraries_json=${lib.escapeShellArg seerrLibraryNamesJson}

        install -d -m 0750 -o seerr -g seerr "$managed_dir"

        for _ in $(seq 1 120); do
          if curl --silent --show-error --fail --max-time 5 "$seerr_url/api/v1/settings/public" >/dev/null; then
            break
          fi
          sleep 1
        done
        curl --silent --show-error --fail --max-time 5 "$seerr_url/api/v1/settings/public" >/dev/null || {
          echo "Seerr HTTP endpoint is not ready; retrying bootstrap after restart." >&2
          exit 1
        }

        for _ in $(seq 1 120); do
          [[ -s "$jellyfin_api_key_file" ]] && break
          sleep 1
        done
        [[ -s "$jellyfin_api_key_file" ]] || {
          echo "Jellyfin bootstrap API key is not available; retrying bootstrap after restart." >&2
          exit 1
        }
        jellyfin_api_key="$(< "$jellyfin_api_key_file")"

        jellyfin_api() {
          curl \
            --silent \
            --show-error \
            --fail \
            --max-time 60 \
            -H "X-Emby-Token: $jellyfin_api_key" \
            "$@"
        }

        if [[ ! -s "$jellyfin_bootstrap_password_file" ]]; then
          umask 0077
          openssl rand -base64 48 >"$jellyfin_bootstrap_password_file"
          chown seerr:seerr "$jellyfin_bootstrap_password_file"
        fi
        jellyfin_bootstrap_password="$(< "$jellyfin_bootstrap_password_file")"

        jellyfin_users="$(jellyfin_api "$jellyfin_url/Users")"
        jellyfin_user_id="$(
          jq -r --arg name "$jellyfin_bootstrap_user" '.[] | select(.Name == $name) | .Id // empty' <<<"$jellyfin_users" | head -n1
        )"

        if [[ -z "$jellyfin_user_id" ]]; then
          echo "Creating managed Jellyfin user for Seerr setup"
          created_user="$(
            jq -n \
              --arg name "$jellyfin_bootstrap_user" \
              --arg password "$jellyfin_bootstrap_password" \
              '{Name: $name, Password: $password}' \
              | jellyfin_api \
                  -X POST \
                  -H "Content-Type: application/json" \
                  --data-binary @- \
                  "$jellyfin_url/Users/New"
          )"
          jellyfin_user_id="$(jq -r '.Id // empty' <<<"$created_user")"
          [[ -n "$jellyfin_user_id" ]] || {
            echo "Jellyfin did not return an Id for the Seerr bootstrap user" >&2
            exit 1
          }
        fi

        current_policy="$(
          jellyfin_api "$jellyfin_url/Users/$jellyfin_user_id" \
            | jq -c '.Policy // {}'
        )"
        desired_policy="$(
          jq -c '
            .IsAdministrator = true
            | .IsHidden = true
            | .IsDisabled = false
            | .EnableAllFolders = true
            | .EnableMediaPlayback = true
          ' <<<"$current_policy"
        )"
        if [[ "$current_policy" != "$desired_policy" ]]; then
          echo "Updating managed Jellyfin policy for Seerr setup"
          jellyfin_api \
            -X POST \
            -H "Content-Type: application/json" \
            --data-binary "$desired_policy" \
            "$jellyfin_url/Users/$jellyfin_user_id/Policy" \
            >/dev/null
        fi

        seerr_public="$(curl --silent --show-error --fail "$seerr_url/api/v1/settings/public")"
        seerr_initialized="$(jq -r '.initialized // false' <<<"$seerr_public")"
        if [[ "$seerr_initialized" != "true" ]]; then
          echo "Initializing Seerr with Jellyfin"
          rm -f "$cookie_file"
          if [[ "$(jq -r '.jellyfin.ip // ""' /var/lib/seerr/settings.json 2>/dev/null || true)" == "" ]]; then
            seerr_auth_payload="$(
              jq -n \
                --arg username "$jellyfin_bootstrap_user" \
                --arg password "$jellyfin_bootstrap_password" \
                --arg hostname "${loopback}" \
                --argjson port ${toString ports.jellyfin} \
                --arg email "$jellyfin_bootstrap_email" \
                '{
                  username: $username,
                  password: $password,
                  hostname: $hostname,
                  port: $port,
                  useSsl: false,
                  urlBase: "",
                  email: $email,
                  serverType: 2
                }'
            )"
          else
            seerr_auth_payload="$(
              jq -n \
                --arg username "$jellyfin_bootstrap_user" \
                --arg password "$jellyfin_bootstrap_password" \
                --arg email "$jellyfin_bootstrap_email" \
                '{username: $username, password: $password, email: $email}'
            )"
          fi
          printf '%s' "$seerr_auth_payload" \
            | curl \
                --silent \
                --show-error \
                --fail \
                --max-time 60 \
                -c "$cookie_file" \
                -b "$cookie_file" \
                -X POST \
                -H "Content-Type: application/json" \
                --data-binary @- \
                "$seerr_url/api/v1/auth/jellyfin" \
                >/dev/null

          seerr_libraries="$(
            curl \
              --silent \
              --show-error \
              --fail \
              --max-time 120 \
              -c "$cookie_file" \
              -b "$cookie_file" \
              "$seerr_url/api/v1/settings/jellyfin/library?sync=true"
          )"
          enable_ids="$(
            jq -r \
              --argjson desired "$desired_libraries_json" \
              '[.[] | select(.name as $name | $desired | index($name) != null) | .id] as $matched
              | (if ($matched | length) > 0 then $matched else [.[] | .id] end)
              | join(",")' \
              <<<"$seerr_libraries"
          )"
          if [[ -n "$enable_ids" ]]; then
            curl \
              --silent \
              --show-error \
              --fail \
              --max-time 60 \
              -c "$cookie_file" \
              -b "$cookie_file" \
              "$seerr_url/api/v1/settings/jellyfin/library?enable=$enable_ids" \
              >/dev/null
          fi
          curl \
            --silent \
            --show-error \
            --fail \
            --max-time 60 \
            -c "$cookie_file" \
            -b "$cookie_file" \
            -X POST \
            "$seerr_url/api/v1/settings/initialize" \
            >/dev/null
        fi

        seerr_api_key="$(
          jq -r '.apiKey // .main?.apiKey // empty' /var/lib/seerr/settings.json 2>/dev/null || true
        )"
        [[ -n "$seerr_api_key" && "$seerr_api_key" != "null" ]] || {
          echo "Seerr API key is not available; skipping Arr service linking" >&2
          exit 0
        }

        seerr_api() {
          curl \
            --silent \
            --show-error \
            --fail \
            --max-time 60 \
            -H "X-Api-Key: $seerr_api_key" \
            "$@"
        }

        read_arr_api_key() {
          local config_xml="$1"
          [[ -f "$config_xml" ]] || return 0
          sed -n 's:.*<ApiKey>\(.*\)</ApiKey>.*:\1:p' "$config_xml" | head -n1
        }

        first_quality_profile() {
          local base_url="$1"
          local api_key="$2"
          curl \
            --silent \
            --show-error \
            --fail \
            --max-time 30 \
            -H "X-Api-Key: $api_key" \
            "$base_url/api/v3/qualityprofile" \
            | jq -c 'sort_by(.id)[0] // empty'
        }

        upsert_seerr_service() {
          local kind="$1"
          local name="$2"
          local payload="$3"
          local existing_id

          [[ -n "$payload" && "$payload" != "null" ]] || return 0
          existing_id="$(
            seerr_api "$seerr_url/api/v1/settings/$kind" \
              | jq -r --arg name "$name" '.[] | select(.name == $name) | .id // empty' \
              | head -n1
          )"

          if [[ -n "$existing_id" ]]; then
            seerr_api \
              -X PUT \
              -H "Content-Type: application/json" \
              --data-binary "$payload" \
              "$seerr_url/api/v1/settings/$kind/$existing_id" \
              >/dev/null
          else
            seerr_api \
              -X POST \
              -H "Content-Type: application/json" \
              --data-binary "$payload" \
              "$seerr_url/api/v1/settings/$kind" \
              >/dev/null
          fi
        }

        sonarr_key="$(read_arr_api_key /var/lib/sonarr/.config/NzbDrone/config.xml)"
        if [[ -n "$sonarr_key" ]]; then
          sonarr_url="http://${loopback}:${toString ports.sonarr}"
          sonarr_quality="$(first_quality_profile "$sonarr_url" "$sonarr_key" || true)"
          if [[ -n "$sonarr_quality" && "$sonarr_quality" != "null" ]]; then
            sonarr_payload="$(
              jq -n \
                --arg name "Sonarr" \
                --arg hostname "${loopback}" \
                --argjson port ${toString ports.sonarr} \
                --arg apiKey "$sonarr_key" \
                --arg rootFolder ${lib.escapeShellArg showsRoot} \
                --arg externalUrl "https://sonarr.${vars.domain}" \
                --argjson quality "$sonarr_quality" \
                '{
                  name: $name,
                  isDefault: true,
                  is4k: false,
                  hostname: $hostname,
                  port: $port,
                  useSsl: false,
                  apiKey: $apiKey,
                  baseUrl: "",
                  externalUrl: $externalUrl,
                  syncEnabled: true,
                  preventSearch: false,
                  activeDirectory: $rootFolder,
                  activeProfileId: $quality.id,
                  activeProfileName: $quality.name,
                  activeLanguageProfileId: 1,
                  activeAnimeDirectory: "",
                  activeAnimeProfileId: $quality.id,
                  activeAnimeProfileName: $quality.name,
                  activeAnimeLanguageProfileId: 1,
                  tags: [],
                  animeTags: [],
                  enableSeasonFolders: true
                }'
            )"
            upsert_seerr_service sonarr Sonarr "$sonarr_payload"
          fi
        fi

        radarr_key="$(read_arr_api_key /var/lib/radarr/.config/Radarr/config.xml)"
        if [[ -n "$radarr_key" ]]; then
          radarr_url="http://${loopback}:${toString ports.radarr}"
          radarr_quality="$(first_quality_profile "$radarr_url" "$radarr_key" || true)"
          if [[ -n "$radarr_quality" && "$radarr_quality" != "null" ]]; then
            radarr_payload="$(
              jq -n \
                --arg name "Radarr" \
                --arg hostname "${loopback}" \
                --argjson port ${toString ports.radarr} \
                --arg apiKey "$radarr_key" \
                --arg rootFolder ${lib.escapeShellArg moviesRoot} \
                --arg externalUrl "https://radarr.${vars.domain}" \
                --argjson quality "$radarr_quality" \
                '{
                  name: $name,
                  isDefault: true,
                  is4k: false,
                  hostname: $hostname,
                  port: $port,
                  useSsl: false,
                  apiKey: $apiKey,
                  baseUrl: "",
                  externalUrl: $externalUrl,
                  syncEnabled: true,
                  preventSearch: false,
                  activeDirectory: $rootFolder,
                  activeProfileId: $quality.id,
                  activeProfileName: $quality.name,
                  minimumAvailability: "released",
                  tags: []
                }'
            )"
            upsert_seerr_service radarr Radarr "$radarr_payload"
          fi
        fi
      '';
    };
  };
}
