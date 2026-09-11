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
    MEDIA_MANAGER_FFPROBE = "${pkgs.ffmpeg}/bin/ffprobe";
    MEDIA_MANAGER_FILESTASH_BASE_URL = "https://files.${vars.domain}";
    MEDIA_MANAGER_PROVIDER_BROKER_BASE_URL = "http://${cfg.address}:${toString cfg.providerPort}/";
  };
  activeIntegrations = lib.filterAttrs (_: integration: integration.available) cfg.integrations;
  webEnvironment = commonEnvironment
    // lib.foldl' (environment: integration: environment // integration.environment) { }
    (lib.attrValues activeIntegrations)
    // { MEDIA_MANAGER_FPCALC_PATH = "${pkgs.chromaprint}/bin/fpcalc"; };
  providerEnvironment = {
    MEDIA_MANAGER_PROVIDER_ADDRESS = cfg.address;
    MEDIA_MANAGER_PROVIDER_PORT = toString cfg.providerPort;
    MEDIA_MANAGER_PROVIDER_STATE_DIR = cfg.providerStateDir;
  };
  refreshCases = lib.concatStringsSep "\n" (lib.mapAttrsToList
    (id: integration:
      let refresh = integration.refresh; in ''
        ${lib.escapeShellArg id})
          unit=${lib.escapeShellArg refresh.unit}
          metadata_unit=${lib.escapeShellArg refresh.metadataUnit}
          success_message=${lib.escapeShellArg refresh.successMessage}
          failure_message=${lib.escapeShellArg refresh.failureMessage}
          ;;
      '')
    (lib.filterAttrs
      (_: integration: integration.refresh != null
        && lib.any (capability: builtins.elem capability integration.capabilities)
          [ "library-refresh" "folder-rescan" ])
      activeIntegrations));
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
          ${refreshCases}
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

        if systemctl start --wait "$unit" \
          && { [[ -z "$metadata_unit" ]] || systemctl start --wait "$metadata_unit"; }; then
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
in
{
  systemd.services.media-manager = {
    description = "Catalog and coordinate safe media-library changes";
    wantedBy = [ "multi-user.target" ];
    requires = [ "data-pool-layout.service" "media-manager-storage-access.service" "media-manager-provider-broker.service" ];
    after = [ "network.target" "data-pool-layout.service" "media-manager-storage-access.service" "media-manager-provider-broker.service" ];
    environment = webEnvironment;
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
      # RestrictSUIDSGID blocks openat2, which contained media reads require.
      LockPersonality = true;
      MemoryDenyWriteExecute = true;
      CapabilityBoundingSet = [ ];
      AmbientCapabilities = [ ];
      ReadOnlyPaths = [ "-${vars.sharedRoot}" "-${vars.usersRoot}" "-/run/mkvmaker" ]
        ++ lib.concatMap (integration: integration.readOnlyPaths) (lib.attrValues activeIntegrations);
      ReadWritePaths = [ cfg.stateDir ];
      SystemCallArchitectures = "native";
      SystemCallFilter = [ "@system-service" "~@privileged" "~@resources" ];
    };
  };

  systemd.services.media-manager-provider-broker = {
    description = "Store and test per-user Media Manager provider accounts";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];
    environment = providerEnvironment;
    serviceConfig = {
      Type = "simple";
      User = "media-manager-provider";
      Group = "media-manager-provider";
      DynamicUser = false;
      ExecStart = lib.getExe' cfg.package "media-manager-provider-broker";
      Restart = "on-failure";
      RestartSec = "5s";
      StateDirectory = "media-manager-provider";
      StateDirectoryMode = "0700";
      RuntimeDirectory = "media-manager-provider";
      RuntimeDirectoryMode = "0700";
      UMask = "0077";
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
      ReadWritePaths = [ cfg.providerStateDir ];
      SystemCallArchitectures = "native";
      SystemCallFilter = [ "@system-service" "~@privileged" "~@resources" ];
    };
  };

  systemd.services.media-manager-scanner = {
    description = "Reconcile Media Manager catalogs with the current filesystem";
    requires = [ "data-pool-layout.service" "media-manager-storage-access.service" ];
    after = [ "data-pool-layout.service" "media-manager-storage-access.service" ];
    environment = commonEnvironment;
    serviceConfig = {
      Type = "oneshot";
      User = "media-manager";
      Group = "media-manager";
      ExecStart = lib.getExe' cfg.package "media-manager-scanner";
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
      RestrictAddressFamilies = [ ];
      RestrictNamespaces = true;
      RestrictRealtime = true;
      LockPersonality = true;
      MemoryDenyWriteExecute = true;
      CapabilityBoundingSet = [ ];
      AmbientCapabilities = [ ];
      ReadOnlyPaths = [ "-${vars.sharedRoot}" "-${vars.usersRoot}" ];
      ReadWritePaths = [ cfg.stateDir ];
      SystemCallArchitectures = "native";
      SystemCallFilter = [ "@system-service" "~@privileged" "~@resources" ];
    };
  };

  systemd.timers.media-manager-scanner = {
    description = "Periodically reconcile Media Manager catalogs";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "2m";
      OnUnitInactiveSec = "15m";
      RandomizedDelaySec = "2m";
      Persistent = true;
      Unit = "media-manager-scanner.service";
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
      # The broker uses the same openat2-based contained path traversal.
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










}
