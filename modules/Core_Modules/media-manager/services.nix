{ config, lib, pkgs, vars, ... }:

let
  cfg = config.repo.mediaManager;
  integrationsJson = builtins.toJSON (lib.mapAttrsToList
    (id: integration: {
      inherit id;
      inherit (integration) label available capabilities;
    })
    cfg.integrations);
  commonEnvironment = {
    MEDIA_MANAGER_ADDRESS = cfg.address;
    MEDIA_MANAGER_PORT = toString cfg.port;
    MEDIA_MANAGER_STATE_DIR = cfg.stateDir;
    MEDIA_MANAGER_SHARED_ROOT = vars.sharedRoot;
    MEDIA_MANAGER_USERS_ROOT = vars.usersRoot;
    MEDIA_MANAGER_EDITOR_GROUP = cfg.editorGroup;
    MEDIA_MANAGER_MUTATION_MODE = cfg.mutationMode;
    MEDIA_MANAGER_MKVMAKER_PROGRESS_FILE = "/run/mkvmaker/progress.json";
    MEDIA_MANAGER_INTEGRATIONS_JSON = integrationsJson;
    MEDIA_MANAGER_FRONTEND_DIR = "${cfg.package}/share/media-manager/frontend";
  };
  openSubtitlesConfigured = builtins.hasAttr "openSubtitlesCredentials" config.age.secrets;
  webEnvironment = commonEnvironment // lib.optionalAttrs openSubtitlesConfigured {
    MEDIA_MANAGER_OPENSUBTITLES_CREDENTIALS_FILE = config.age.secrets.openSubtitlesCredentials.path;
  };
  refreshAvailable = id:
    (cfg.integrations.${id}.available or false)
    && lib.any
      (capability: capability == "library-refresh" || capability == "folder-rescan")
      (cfg.integrations.${id}.capabilities or [ ]);
  jellyfinRefreshAvailable = refreshAvailable "jellyfin";
  audiobookshelfRefreshAvailable = refreshAvailable "audiobookshelf";
  kavitaRefreshAvailable = refreshAvailable "kavita";
  syncthingRefreshAvailable = refreshAvailable "syncthing";
  refreshDispatcher = pkgs.writeShellApplication {
    name = "media-manager-refresh-dispatch";
    runtimeInputs = [ pkgs.coreutils pkgs.jq pkgs.systemd ];
    text = ''
      set -euo pipefail
      shopt -s nullglob

      request_dir=${lib.escapeShellArg "${cfg.stateDir}/refresh-requests"}
      result_dir=${lib.escapeShellArg "${cfg.stateDir}/refresh-results"}
      had_failure=0
      while true; do
        markers=("$request_dir"/*.request)
        (( ''${#markers[@]} > 0 )) || break
        for marker in "''${markers[@]}"; do
        if [[ ! -f "$marker" || -L "$marker" ]]; then
          rm -f -- "$marker"
          continue
        fi
        integration="$(basename "$marker" .request)"
        request_id="$(jq -er \
          --arg integration "$integration" \
          'select(.schemaVersion == 1 and .integrationId == $integration and .state == "queued") | .requestId' \
          "$marker" 2>/dev/null || true)"
        queued_at="$(jq -er '.queuedAt | select(type == "number")' "$marker" 2>/dev/null || true)"
        if [[ ! "$request_id" =~ ^r[0-9a-f]+-[0-9a-f]+$ || ! "$queued_at" =~ ^[0-9]+$ ]]; then
          jq -cn \
            --arg integrationId "$integration" \
            '{level:"error",service:"media-manager-refresh-dispatch",event:"integration_refresh_marker_invalid",integrationId:$integrationId}' >&2
          rm -f -- "$marker"
          had_failure=1
          continue
        fi

        case "$integration" in
          ${lib.optionalString jellyfinRefreshAvailable ''
          jellyfin)
            unit=media-manager-refresh-jellyfin.service
            success_message="Jellyfin library scan completed."
            failure_message="Jellyfin library scan failed. Check the adapter service log."
            ;;
          ''}
          ${lib.optionalString audiobookshelfRefreshAvailable ''
          audiobookshelf)
            unit=media-manager-refresh-audiobookshelf.service
            success_message="Audiobookshelf library scans completed."
            failure_message="Audiobookshelf library scans failed. Check the adapter service log."
            ;;
          ''}
          ${lib.optionalString kavitaRefreshAvailable ''
          kavita)
            unit=media-manager-refresh-kavita.service
            success_message="Kavita library scans completed."
            failure_message="Kavita library scans failed. Check the adapter service log."
            ;;
          ''}
          ${lib.optionalString syncthingRefreshAvailable ''
          syncthing)
            unit=media-manager-refresh-syncthing.service
            success_message="Syncthing folder scan completed."
            failure_message="Syncthing folder scan failed. Check the adapter service log."
            ;;
          ''}
          *)
            jq -cn \
              --arg integrationId "$integration" \
              --arg requestId "$request_id" \
              '{level:"error",service:"media-manager-refresh-dispatch",event:"integration_refresh_adapter_unavailable",integrationId:$integrationId,requestId:$requestId}' >&2
            rm -f -- "$marker"
            had_failure=1
            continue
            ;;
        esac

        started_at="$(date +%s)"
        running_tmp="$(mktemp "$request_dir/.running.XXXXXX")"
        jq --argjson startedAt "$started_at" \
          '.state = "running" | .startedAt = $startedAt' \
          "$marker" >"$running_tmp"
        chmod 0640 "$running_tmp"
        mv -f -- "$running_tmp" "$marker"

        if systemctl start --wait "$unit"; then
          terminal_state=succeeded
          message="$success_message"
          level=info
          event=integration_refresh_succeeded
        else
          terminal_state=failed
          message="$failure_message"
          level=error
          event=integration_refresh_failed
          had_failure=1
        fi
        finished_at="$(date +%s)"
        result_tmp="$(mktemp "$result_dir/.result.XXXXXX")"
        jq -cn \
          --arg integrationId "$integration" \
          --arg state "$terminal_state" \
          --arg requestId "$request_id" \
          --arg message "$message" \
          --argjson queuedAt "$queued_at" \
          --argjson startedAt "$started_at" \
          --argjson finishedAt "$finished_at" \
          '{schemaVersion:1,integrationId:$integrationId,state:$state,requestId:$requestId,queuedAt:$queuedAt,startedAt:$startedAt,finishedAt:$finishedAt,message:$message}' \
          >"$result_tmp"
        chmod 0640 "$result_tmp"
        mv -f -- "$result_tmp" "$result_dir/$integration.json"
        rm -f -- "$marker"

        jq -cn \
          --arg level "$level" \
          --arg event "$event" \
          --arg integrationId "$integration" \
          --arg requestId "$request_id" \
          --argjson durationSeconds "$((finished_at - started_at))" \
          '{level:$level,service:"media-manager-refresh-dispatch",event:$event,integrationId:$integrationId,requestId:$requestId,durationSeconds:$durationSeconds}' \
          >&2
        done
      done
      exit "$had_failure"
    '';
  };
  jellyfinRefresh = pkgs.writeShellApplication {
    name = "media-manager-refresh-jellyfin";
    runtimeInputs = [ pkgs.coreutils pkgs.curl pkgs.jq ];
    text = ''
      set -euo pipefail
      base_url="http://${vars.networking.loopbackIPv4}:${toString vars.networking.ports.jellyfin}"
      api_key_file=/var/lib/jellyfin/data/library-sync.api-key
      [[ -f "$api_key_file" && ! -L "$api_key_file" ]] || {
        echo "Jellyfin library-sync API key is unavailable" >&2
        exit 1
      }
      api_key="$(tr -d '\r\n' <"$api_key_file")"
      [[ "$api_key" =~ ^[A-Za-z0-9._~-]+$ ]] || {
        echo "Jellyfin library-sync API key is malformed" >&2
        exit 1
      }
      jellyfin_curl() {
        printf 'header = "X-Emby-Token: %s"\n' "$api_key" \
          | curl --config - --fail --silent --show-error --max-time 30 "$@"
      }

      tasks="$(jellyfin_curl "$base_url/ScheduledTasks")"
      task_id="$(jq -er '
        map(select((.Key // .key) == "RefreshLibrary"))
        | first
        | (.Id // .id)
        | select(type == "string" and test("^[A-Fa-f0-9-]+$"))
      ' <<<"$tasks")"
      previous_finished="$(jq -r \
        --arg taskId "$task_id" \
        'map(select((.Id // .id) == $taskId)) | first | (.LastExecutionResult.EndTimeUtc // .lastExecutionResult.endTimeUtc // "")' \
        <<<"$tasks")"
      jellyfin_curl -X POST "$base_url/ScheduledTasks/Running/$task_id" >/dev/null

      saw_running=false
      for _ in $(seq 1 3600); do
        task="$(jellyfin_curl "$base_url/ScheduledTasks/$task_id")"
        state="$(jq -r '.State // .state // empty' <<<"$task")"
        finished="$(jq -r '.LastExecutionResult.EndTimeUtc // .lastExecutionResult.endTimeUtc // ""' <<<"$task")"
        if [[ "$state" == "Running" || "$state" == "Cancelling" ]]; then
          saw_running=true
        elif [[ "$state" == "Idle" && ( "$saw_running" == "true" || ( -n "$finished" && "$finished" != "$previous_finished" ) ) ]]; then
          status="$(jq -r '.LastExecutionResult.Status // .lastExecutionResult.status // empty' <<<"$task")"
          [[ "$status" == "Completed" ]] && exit 0
          echo "Jellyfin scheduled task ended with status: ''${status:-unknown}" >&2
          exit 1
        fi
        sleep 2
      done
      echo "Timed out waiting for the Jellyfin library scan" >&2
      exit 1
    '';
  };
  audiobookshelfRefresh = pkgs.writeShellApplication {
    name = "media-manager-refresh-audiobookshelf";
    runtimeInputs = [ pkgs.coreutils pkgs.curl pkgs.jq ];
    text = ''
      set -euo pipefail
      base_url="http://${vars.networking.loopbackIPv4}:${toString vars.networking.ports.audiobookshelf}"
      password="$(< ${config.age.secrets.absBootstrapPass.path})"
      login="$(${pkgs.jq}/bin/jq -cn \
        --arg username ${lib.escapeShellArg vars.kanidmAdminUser} \
        --arg password "$password" \
        '{username: $username, password: $password}')"
      response="$(printf '%s' "$login" | curl --fail --silent --show-error --max-time 30 \
        -X POST -H 'Content-Type: application/json' --data-binary @- \
        "$base_url/login")"
      token="$(jq -r '.user.token // .user.accessToken // .token // .accessToken // empty' <<<"$response")"
      [[ "$token" =~ ^[A-Za-z0-9._~+/-]+$ ]] || {
        echo "Audiobookshelf returned no safe API token" >&2
        exit 1
      }
      libraries="$(printf 'header = "Authorization: Bearer %s"\n' "$token" \
        | curl --config - --fail --silent --show-error --max-time 60 \
          "$base_url/api/libraries")"
      library_ids="$(jq -c '[((.libraries // .)[]?.id // empty)]' <<<"$libraries")"
      library_count="$(jq 'length' <<<"$library_ids")"
      (( library_count > 0 )) || {
        echo "Audiobookshelf has no libraries to scan" >&2
        exit 1
      }
      started_at_ms="$(date +%s%3N)"
      while IFS= read -r library_id; do
        [[ -n "$library_id" ]] || continue
        printf 'header = "Authorization: Bearer %s"\n' "$token" \
          | curl --config - --fail --silent --show-error --max-time 300 -X POST \
            "$base_url/api/libraries/$library_id/scan" >/dev/null
      done < <(jq -r '.[]' <<<"$library_ids")

      for attempt in $(seq 1 3600); do
        tasks="$(printf 'header = "Authorization: Bearer %s"\n' "$token" \
          | curl --config - --fail --silent --show-error --max-time 30 \
            "$base_url/api/tasks")"
        libraries="$(printf 'header = "Authorization: Bearer %s"\n' "$token" \
          | curl --config - --fail --silent --show-error --max-time 30 \
            "$base_url/api/libraries")"
        completed_count="$(jq \
          --argjson ids "$library_ids" \
          --argjson startedAt "$started_at_ms" \
          '[((.libraries // .)[]?) | select((.id as $id | $ids | index($id)) != null and (.lastScan // 0) >= $startedAt)] | length' \
          <<<"$libraries")"
        active_count="$(jq \
          --argjson ids "$library_ids" \
          '[.tasks[]? | select(.action == "library-scan" and (.data.libraryId as $id | $ids | index($id)) != null)] | length' \
          <<<"$tasks")"
        (( completed_count == library_count )) && exit 0
        if (( active_count == 0 && completed_count < library_count && attempt > 5 )); then
          echo "An Audiobookshelf library scan ended without updating lastScan" >&2
          exit 1
        fi
        sleep 2
      done
      echo "Timed out waiting for Audiobookshelf library scans" >&2
      exit 1
    '';
  };
  kavitaRefresh = pkgs.writeShellApplication {
    name = "media-manager-refresh-kavita";
    runtimeInputs = [ pkgs.coreutils pkgs.curl pkgs.jq pkgs.python3 pkgs.sqlite ];
    text = ''
      set -euo pipefail
      base_url="http://${vars.networking.loopbackIPv4}:${toString vars.networking.ports.kavita}"
      db=/var/lib/kavita/config/kavita.db
      token_key_file=${lib.escapeShellArg config.age.secrets.kavitaTokenKey.path}
      admin_username=${lib.escapeShellArg vars.kanidmAdminUser}

      [[ "$admin_username" =~ ^[a-z][a-z0-9._-]{0,63}$ ]] || {
        echo "Kavita admin username is malformed" >&2
        exit 1
      }
      [[ -f "$db" && ! -L "$db" ]] || {
        echo "Kavita database is unavailable" >&2
        exit 1
      }
      [[ -f "$token_key_file" && ! -L "$token_key_file" ]] || {
        echo "Kavita token key is unavailable" >&2
        exit 1
      }

      admin_token="$(python3 - "$token_key_file" "$db" "$admin_username" <<'PY'
import base64
import hashlib
import hmac
import json
import sqlite3
import sys
import time

def encode(value):
    return base64.urlsafe_b64encode(value).rstrip(b"=")

token_key_path, database_path, username = sys.argv[1:]
with sqlite3.connect(f"file:{database_path}?mode=ro", uri=True, timeout=5) as database:
    row = database.execute(
        "select Id, UserName from AspNetUsers where UserName = ? limit 1",
        (username,),
    ).fetchone()
if row is None:
    raise SystemExit("Kavita admin identity is unavailable")
token_key = open(token_key_path, "rb").read().strip()
if len(token_key) < 32:
    raise SystemExit("Kavita token key is malformed")
now = int(time.time())
header = encode(json.dumps(
    {"alg": "HS512", "typ": "JWT"}, separators=(",", ":")
).encode())
payload = encode(json.dumps({
    "name": row[1],
    "nameid": str(row[0]),
    "role": ["Admin", "Login"],
    "nbf": now,
    "iat": now,
    "exp": now + 300,
}, separators=(",", ":")).encode())
unsigned = header + b"." + payload
signature = encode(hmac.new(token_key, unsigned, hashlib.sha512).digest())
print((unsigned + b"." + signature).decode())
PY
)"
      kavita_curl() {
        printf 'header = "Authorization: Bearer %s"\n' "$admin_token" \
          | curl --config - --fail --silent --show-error --max-time 60 "$@"
      }

      baseline="$(sqlite3 -readonly -json -cmd '.timeout 5000' "$db" \
        'select Id as id, LastScanned as lastScanned from Library order by Id;')"
      library_count="$(jq 'length' <<<"$baseline")"
      if (( library_count == 0 )); then
        echo "Kavita has no libraries to scan"
        exit 0
      fi

      kavita_curl -X POST "$base_url/api/library/scan-all?force=false" >/dev/null
      unset admin_token
      # Kavita has no public scan-job status endpoint. LastScanned is persisted
      # after the library data update, so every baseline timestamp must advance.
      for _ in $(seq 1 3600); do
        current="$(sqlite3 -readonly -json -cmd '.timeout 5000' "$db" \
          'select Id as id, LastScanned as lastScanned from Library order by Id;')"
        if ! jq -e --argjson before "$baseline" \
          '. as $current
           | all($before[]; . as $previous
             | any($current[]; .id == $previous.id))' \
          <<<"$current" >/dev/null; then
          echo "A Kavita library was removed while its scan was running" >&2
          exit 1
        fi
        if jq -e --argjson before "$baseline" \
          '. as $current
           | all($before[]; . as $previous
             | any($current[];
               .id == $previous.id and .lastScanned != $previous.lastScanned))' \
          <<<"$current" >/dev/null; then
          exit 0
        fi
        sleep 2
      done
      echo "Timed out waiting for Kavita library scans" >&2
      exit 1
    '';
  };
  syncthingRefresh = pkgs.writeShellApplication {
    name = "media-manager-refresh-syncthing";
    runtimeInputs = [ pkgs.coreutils pkgs.curl pkgs.libxml2 ];
    text = ''
      set -euo pipefail
      config_file=/var/lib/syncthing/.config/syncthing/config.xml
      [[ -f "$config_file" && ! -L "$config_file" ]] || {
        echo "Syncthing configuration is unavailable" >&2
        exit 1
      }
      api_key="$(xmllint --xpath 'string(configuration/gui/apikey)' "$config_file")"
      [[ "$api_key" =~ ^[A-Za-z0-9_-]+$ ]] || {
        echo "Syncthing API key is unavailable or malformed" >&2
        exit 1
      }
      printf 'header = "X-API-Key: %s"\n' "$api_key" \
        | curl --config - --fail --silent --show-error --max-time 300 -X POST \
          http://127.0.0.1:8384/rest/db/scan >/dev/null
    '';
  };
in
{
  systemd.services.media-manager = {
    description = "Catalog and coordinate safe media-library changes";
    wantedBy = [ "multi-user.target" ];
    requires = [ "data-pool-layout.service" "media-manager-storage-access.service" ];
    after = [ "network.target" "data-pool-layout.service" "media-manager-storage-access.service" ];
    environment = webEnvironment;
    restartTriggers = lib.optionals openSubtitlesConfigured [ config.age.secrets.openSubtitlesCredentials.file ];
    serviceConfig = {
      Type = "simple";
      User = "media-manager";
      Group = "media-manager";
      DynamicUser = false;
      ExecStart = lib.getExe cfg.package;
      Restart = "on-failure";
      RestartSec = "5s";
      StateDirectory = "media-manager";
      StateDirectoryMode = "0770";
      RuntimeDirectory = "media-manager";
      RuntimeDirectoryMode = "0750";
      UMask = "0007";
      NoNewPrivileges = true;
      PrivateTmp = true;
      PrivateDevices = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectKernelLogs = true;
      ProtectControlGroups = true;
      ProtectProc = "invisible";
      ProcSubset = "pid";
      ProtectClock = true;
      ProtectHostname = true;
      RestrictAddressFamilies = [ "AF_INET" "AF_INET6" ];
      RestrictNamespaces = true;
      RestrictRealtime = true;
      RestrictSUIDSGID = true;
      LockPersonality = true;
      MemoryDenyWriteExecute = true;
      CapabilityBoundingSet = [ ];
      AmbientCapabilities = [ ];
      ReadOnlyPaths = [ "-${vars.sharedRoot}" "-${vars.usersRoot}" "-/run/mkvmaker" ];
      ReadWritePaths = [ cfg.stateDir ];
      SystemCallArchitectures = "native";
      SystemCallFilter = [ "@system-service" "~@privileged" "~@resources" ];
    };
  };

  systemd.services.media-manager-broker = {
    description = "Apply one queued Media Manager mutation plan";
    requires = [ "data-pool-layout.service" "media-manager-storage-access.service" ];
    after = [ "data-pool-layout.service" "media-manager-storage-access.service" ];
    environment = commonEnvironment;
    serviceConfig = {
      Type = "oneshot";
      User = "media-manager-broker";
      Group = "media-manager";
      SupplementaryGroups = [ "media-manager-broker" ];
      ExecStart = lib.getExe' cfg.package "media-manager-broker";
      UMask = "0007";
      NoNewPrivileges = true;
      PrivateTmp = true;
      PrivateDevices = true;
      PrivateNetwork = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectKernelLogs = true;
      ProtectControlGroups = true;
      ProtectProc = "invisible";
      ProcSubset = "pid";
      ProtectClock = true;
      ProtectHostname = true;
      RestrictAddressFamilies = [ ];
      RestrictNamespaces = true;
      RestrictRealtime = true;
      RestrictSUIDSGID = true;
      LockPersonality = true;
      MemoryDenyWriteExecute = true;
      CapabilityBoundingSet = [ ];
      AmbientCapabilities = [ ];
      ReadWritePaths = [ cfg.stateDir vars.sharedRoot vars.usersRoot ];
      SystemCallArchitectures = "native";
      SystemCallFilter = [ "@system-service" "~@privileged" "~@resources" ];
    };
  };

  systemd.timers.media-manager-broker = lib.mkIf (cfg.mutationMode == "enabled") {
    description = "Poll the durable Media Manager mutation queue";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "20s";
      OnUnitInactiveSec = "10s";
      AccuracySec = "1s";
      Unit = "media-manager-broker.service";
    };
  };

  systemd.paths.media-manager-refresh-requests = {
    description = "Dispatch queued Media Manager application refresh requests";
    wantedBy = [ "paths.target" ];
    pathConfig = {
      PathChanged = "${cfg.stateDir}/refresh-requests";
      Unit = "media-manager-refresh-dispatch.service";
    };
  };

  systemd.services.media-manager-refresh-dispatch = {
    description = "Dispatch closed Media Manager refresh adapter requests";
    serviceConfig = {
      Type = "oneshot";
      User = "root";
      Group = "media-manager";
      ExecStart = lib.getExe refreshDispatcher;
      UMask = "0027";
      NoNewPrivileges = true;
      PrivateTmp = true;
      PrivateDevices = true;
      PrivateNetwork = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectKernelLogs = true;
      ProtectClock = true;
      ProtectHostname = true;
      RestrictAddressFamilies = [ "AF_UNIX" ];
      RestrictNamespaces = true;
      RestrictRealtime = true;
      RestrictSUIDSGID = true;
      LockPersonality = true;
      MemoryDenyWriteExecute = true;
      CapabilityBoundingSet = [ ];
      AmbientCapabilities = [ ];
      ReadWritePaths = [ cfg.stateDir ];
      SystemCallArchitectures = "native";
      SystemCallFilter = [ "@system-service" "~@privileged" "~@resources" ];
    };
  };

  systemd.services.media-manager-refresh-jellyfin = lib.mkIf jellyfinRefreshAvailable {
    description = "Run and follow the Jellyfin media-library scan task";
    after = [ "jellyfin.service" ];
    wants = [ "jellyfin.service" ];
    serviceConfig = {
      Type = "oneshot";
      User = "root";
      Group = "root";
      ExecStart = lib.getExe jellyfinRefresh;
      NoNewPrivileges = true;
      PrivateTmp = true;
      PrivateDevices = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectKernelLogs = true;
      ProtectControlGroups = true;
      ProtectProc = "invisible";
      ProcSubset = "pid";
      RestrictAddressFamilies = [ "AF_INET" "AF_INET6" ];
      RestrictNamespaces = true;
      RestrictRealtime = true;
      RestrictSUIDSGID = true;
      LockPersonality = true;
      MemoryDenyWriteExecute = true;
      CapabilityBoundingSet = [ ];
      AmbientCapabilities = [ ];
      ReadOnlyPaths = [ "/var/lib/jellyfin/data/library-sync.api-key" ];
      IPAddressDeny = "any";
      IPAddressAllow = [ "localhost" ];
      SystemCallArchitectures = "native";
      SystemCallFilter = [ "@system-service" "~@privileged" "~@resources" ];
    };
  };

  systemd.services.media-manager-refresh-audiobookshelf = lib.mkIf audiobookshelfRefreshAvailable {
    description = "Request scans for every Audiobookshelf library";
    after = [ "audiobookshelf.service" ];
    wants = [ "audiobookshelf.service" ];
    serviceConfig = {
      Type = "oneshot";
      User = "root";
      Group = "root";
      ExecStart = lib.getExe audiobookshelfRefresh;
      NoNewPrivileges = true;
      PrivateTmp = true;
      PrivateDevices = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectKernelLogs = true;
      ProtectControlGroups = true;
      ProtectProc = "invisible";
      ProcSubset = "pid";
      RestrictAddressFamilies = [ "AF_INET" "AF_INET6" ];
      RestrictNamespaces = true;
      RestrictRealtime = true;
      RestrictSUIDSGID = true;
      LockPersonality = true;
      MemoryDenyWriteExecute = true;
      CapabilityBoundingSet = [ ];
      AmbientCapabilities = [ ];
      IPAddressDeny = "any";
      IPAddressAllow = [ "localhost" ];
      SystemCallArchitectures = "native";
      SystemCallFilter = [ "@system-service" "~@privileged" "~@resources" ];
    };
  };

  systemd.services.media-manager-refresh-kavita = lib.mkIf kavitaRefreshAvailable {
    description = "Request and follow Kavita library scans";
    after = [ "kavita.service" "kavita-oidc-bootstrap.service" ];
    wants = [ "kavita.service" "kavita-oidc-bootstrap.service" ];
    serviceConfig = {
      Type = "oneshot";
      User = "kavita";
      Group = "kavita";
      ExecStart = lib.getExe kavitaRefresh;
      NoNewPrivileges = true;
      PrivateTmp = true;
      PrivateDevices = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectKernelLogs = true;
      ProtectControlGroups = true;
      ProtectProc = "invisible";
      ProcSubset = "pid";
      RestrictAddressFamilies = [ "AF_INET" "AF_INET6" ];
      RestrictNamespaces = true;
      RestrictRealtime = true;
      RestrictSUIDSGID = true;
      LockPersonality = true;
      MemoryDenyWriteExecute = true;
      TimeoutStartSec = "2h5m";
      CapabilityBoundingSet = [ ];
      AmbientCapabilities = [ ];
      ReadOnlyPaths = [
        "/var/lib/kavita/config/kavita.db"
        config.age.secrets.kavitaTokenKey.path
      ];
      IPAddressDeny = "any";
      IPAddressAllow = [ "localhost" ];
      SystemCallArchitectures = "native";
      SystemCallFilter = [ "@system-service" "~@privileged" "~@resources" "fchown" ];
    };
  };

  systemd.services.media-manager-refresh-syncthing = lib.mkIf syncthingRefreshAvailable {
    description = "Request an immediate scan of every Syncthing folder";
    after = [ "syncthing.service" ];
    wants = [ "syncthing.service" ];
    serviceConfig = {
      Type = "oneshot";
      User = "root";
      Group = "root";
      ExecStart = lib.getExe syncthingRefresh;
      NoNewPrivileges = true;
      PrivateTmp = true;
      PrivateDevices = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectKernelLogs = true;
      ProtectControlGroups = true;
      ProtectProc = "invisible";
      ProcSubset = "pid";
      RestrictAddressFamilies = [ "AF_INET" "AF_INET6" ];
      RestrictNamespaces = true;
      RestrictRealtime = true;
      RestrictSUIDSGID = true;
      LockPersonality = true;
      MemoryDenyWriteExecute = true;
      CapabilityBoundingSet = [ ];
      AmbientCapabilities = [ ];
      ReadOnlyPaths = [ "/var/lib/syncthing/.config/syncthing" ];
      IPAddressDeny = "any";
      IPAddressAllow = [ "localhost" ];
      SystemCallArchitectures = "native";
      SystemCallFilter = [ "@system-service" "~@privileged" "~@resources" ];
    };
  };
}
