{ config
, lib
, automationPath
, reconcileServiceConfig
, loopback
, ports
, hostCompleteDir
, containerCompleteDir
,
}:

{
  description = "Bootstrap Chaptarr qBittorrent download client";
  wantedBy = [ "multi-user.target" ];
  wants = [
    "chaptarr.service"
    "qbittorrent.service"
    "chaptarr-storage-layout-v1.service"
    "media-automation-storage-layout-v1.service"
    "media-automation-bootstrap-qbittorrent.service"
  ];
  after = [
    "chaptarr.service"
    "qbittorrent.service"
    "chaptarr-storage-layout-v1.service"
    "media-automation-storage-layout-v1.service"
    "media-automation-bootstrap-qbittorrent.service"
  ];
  path = automationPath;
  serviceConfig = reconcileServiceConfig // {
    User = "chaptarr";
    Group = "chaptarr";
    RuntimeDirectory = "media-automation-bootstrap-chaptarr";
    RuntimeDirectoryMode = "0700";
    UMask = "0077";
    NoNewPrivileges = true;
    PrivateTmp = true;
    ProtectHome = true;
    ProtectSystem = "strict";
  };
  script = ''
    set -euo pipefail

    config_xml="''${CHAPTARR_CONFIG_XML:-${lib.escapeShellArg "${config.repo.chaptarr.paths.stateDir}/config.xml"}}"
    runtime_dir="''${RUNTIME_DIRECTORY:-/run/media-automation-bootstrap-chaptarr}"
    base_url="http://${loopback}:${toString ports.chaptarr}"
    qbit_host=${lib.escapeShellArg loopback}
    qbit_port=${toString ports.qbittorrentWeb}

    for _ in $(seq 1 120); do
      [[ -f "$config_xml" ]] && grep -q '<ApiKey>' "$config_xml" && break
      sleep 1
    done
    [[ -f "$config_xml" ]] || {
      echo "Chaptarr configuration is not ready; retrying media bootstrap." >&2
      exit 1
    }
    api_key="$(sed -n 's:.*<ApiKey>\(.*\)</ApiKey>.*:\1:p' "$config_xml" | head -n1)"
    [[ -n "$api_key" ]] || {
      echo "Chaptarr API key is not ready; retrying media bootstrap." >&2
      exit 1
    }

    umask 077
    api_header="$runtime_dir/api-header"
    install -m 0600 /dev/null "$api_header"
    printf 'X-Api-Key: %s\n' "$api_key" > "$api_header"

    api() {
      curl --silent --show-error --fail -H "@$api_header" "$@"
    }

    for _ in $(seq 1 60); do
      if api "$base_url/api/v1/system/status" >/dev/null; then
        break
      fi
      sleep 1
    done
    api "$base_url/api/v1/system/status" >/dev/null || {
      echo "Chaptarr HTTP endpoint is not ready; retrying media bootstrap." >&2
      exit 1
    }

    metadata_server_url=${lib.escapeShellArg config.repo.chaptarr.metadataServerUrl}
    development_payload="$(
      api "$base_url/api/v1/config/development" \
        | jq -c --arg metadataServerUrl "$metadata_server_url" \
          '.metadataServerUrl = $metadataServerUrl'
    )"
    development_id="$(jq -r '.id // 1' <<<"$development_payload")"
    [[ "$development_id" =~ ^[1-9][0-9]*$ ]] || {
      echo "Chaptarr development configuration ID is unavailable." >&2
      exit 1
    }
    printf '%s' "$development_payload" \
      | api -X PUT -H 'Content-Type: application/json' --data-binary @- \
        "$base_url/api/v1/config/development/$development_id" >/dev/null
    printf '%s' "$development_payload" \
      | api -X POST -H 'Content-Type: application/json' --data-binary @- \
        "$base_url/api/v1/config/development/test" >/dev/null

    reconcile_root_folder() {
      local name="$1"
      local path="$2"
      local folder_type="$3"
      local existing
      local existing_type
      local payload

      existing="$(
        api "$base_url/api/v1/rootfolder" \
          | jq -c --arg path "$path" 'map(select(.path == $path))[0] // null'
      )"
      if [[ "$existing" == "null" ]]; then
        payload="$(
          jq -cn \
            --arg name "$name" \
            --arg path "$path" \
            --argjson folderType "$folder_type" \
            '{
              name: $name,
              path: $path,
              folderType: $folderType,
              defaultTags: [],
              isCalibreLibrary: false,
              placeEbooksWithAudiobooks: false
            }'
        )"
        printf '%s' "$payload" \
          | api -X POST -H 'Content-Type: application/json' --data-binary @- \
            "$base_url/api/v1/rootfolder" >/dev/null
        return
      fi

      existing_type="$(jq -r '.folderType' <<<"$existing")"
      [[ "$existing_type" == "$folder_type" ]] || {
        echo "Chaptarr root folder $path exists with incompatible type $existing_type." >&2
        exit 1
      }
    }

    reconcile_root_folder "Audiobookshelf" /audiobooks 1
    reconcile_root_folder "Kavita Ebooks" /ebooks 2

    media_management_payload="$(
      api "$base_url/api/v1/config/mediamanagement" \
        | jq -c \
          '.defaultAudiobookRootFolderPath = "/audiobooks"
          | .defaultEbookRootFolderPath = "/ebooks"'
    )"
    media_management_id="$(jq -r '.id // 1' <<<"$media_management_payload")"
    [[ "$media_management_id" =~ ^[1-9][0-9]*$ ]] || {
      echo "Chaptarr media-management configuration ID is unavailable." >&2
      exit 1
    }
    printf '%s' "$media_management_payload" \
      | api -X PUT -H 'Content-Type: application/json' --data-binary @- \
        "$base_url/api/v1/config/mediamanagement/$media_management_id" >/dev/null

    existing_id="$(api "$base_url/api/v1/downloadclient" | jq -r '.[] | select(.name == "qBittorrent") | .id' | head -n1)"
    payload="$(
      api "$base_url/api/v1/downloadclient/schema" \
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
              elif .name == "category" then .value = "books"
              elif .name == "recentPriority" then .value = 0
              elif .name == "olderPriority" then .value = 0
              elif .name == "initialState" then .value = 0
              else .
              end
            ))'
    )"

    [[ -n "$payload" && "$payload" != "null" ]] || {
      echo "Chaptarr did not expose a qBittorrent client schema; retrying media bootstrap." >&2
      exit 1
    }
    if [[ -n "$existing_id" && "$existing_id" != "null" ]]; then
      jq --argjson id "$existing_id" '.id = $id' <<<"$payload" \
        | api -X PUT -H 'Content-Type: application/json' --data-binary @- "$base_url/api/v1/downloadclient/$existing_id" >/dev/null
    else
      printf '%s' "$payload" \
        | api -X POST -H 'Content-Type: application/json' --data-binary @- "$base_url/api/v1/downloadclient" >/dev/null
    fi

    download_client_id="$(
      api "$base_url/api/v1/downloadclient" \
        | jq -r '.[] | select(.name == "qBittorrent") | .id' \
        | head -n1
    )"
    [[ "$download_client_id" =~ ^[1-9][0-9]*$ ]] || {
      echo "Chaptarr qBittorrent client ID is unavailable after reconciliation." >&2
      exit 1
    }

    remote_path=${lib.escapeShellArg "${hostCompleteDir}/"}
    local_path=${lib.escapeShellArg "${containerCompleteDir}/"}
    mapping_id="$(
      api "$base_url/api/v1/remotepathmapping" \
        | jq -r \
          --argjson clientId "$download_client_id" \
          '.[] | select(.downloadClientId == $clientId) | .id' \
        | head -n1
    )"
    mapping_payload="$(
      jq -cn \
        --argjson downloadClientId "$download_client_id" \
        --arg host "$qbit_host" \
        --arg remotePath "$remote_path" \
        --arg localPath "$local_path" \
        '{downloadClientId: $downloadClientId, host: $host, remotePath: $remotePath, localPath: $localPath}'
    )"
    if [[ -n "$mapping_id" && "$mapping_id" != "null" ]]; then
      jq --argjson id "$mapping_id" '.id = $id' <<<"$mapping_payload" \
        | api -X PUT -H 'Content-Type: application/json' --data-binary @- "$base_url/api/v1/remotepathmapping/$mapping_id" >/dev/null
    else
      printf '%s' "$mapping_payload" \
        | api -X POST -H 'Content-Type: application/json' --data-binary @- "$base_url/api/v1/remotepathmapping" >/dev/null
    fi

    mapping_test="$(
      printf '%s' "$mapping_payload" \
        | api -X POST -H 'Content-Type: application/json' --data-binary @- "$base_url/api/v1/remotepathmapping/test"
    )"
    jq -e '
      .isMapped
      and .localPathExists
      and .downloadClientPathChecked
      and .downloadClientPathMatched
      and (.downloadClientTestError == null)
    ' <<<"$mapping_test" >/dev/null || {
      echo "Chaptarr could not map qBittorrent's completed-download directory into the container." >&2
      exit 1
    }
  '';
}
