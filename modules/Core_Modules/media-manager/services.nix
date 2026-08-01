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
  syncthingRefreshAvailable = refreshAvailable "syncthing";
  refreshDispatcher = pkgs.writeShellApplication {
    name = "media-manager-refresh-dispatch";
    runtimeInputs = [ pkgs.coreutils pkgs.systemd ];
    text = ''
      set -euo pipefail
      shopt -s nullglob

      request_dir=${lib.escapeShellArg "${cfg.stateDir}/refresh-requests"}
      install -d -m 0750 -o media-manager -g media-manager "$request_dir"
      for marker in "$request_dir"/*.request; do
        if [[ ! -f "$marker" || -L "$marker" ]]; then
          rm -f -- "$marker"
          continue
        fi
        integration="$(basename "$marker" .request)"
        case "$integration" in
          ${lib.optionalString jellyfinRefreshAvailable ''
          jellyfin)
            systemctl start --no-block jellyfin-library-sync.service
            ;;
          ''}
          ${lib.optionalString audiobookshelfRefreshAvailable ''
          audiobookshelf)
            systemctl start --no-block media-manager-refresh-audiobookshelf.service
            ;;
          ''}
          ${lib.optionalString syncthingRefreshAvailable ''
          syncthing)
            systemctl start --no-block media-manager-refresh-syncthing.service
            ;;
          ''}
          *)
            echo "Ignoring unavailable Media Manager refresh adapter: $integration" >&2
            ;;
        esac
        rm -f -- "$marker"
      done
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
      while IFS= read -r library_id; do
        [[ -n "$library_id" ]] || continue
        printf 'header = "Authorization: Bearer %s"\n' "$token" \
          | curl --config - --fail --silent --show-error --max-time 300 -X POST \
            "$base_url/api/libraries/$library_id/scan" >/dev/null
      done < <(jq -r '(.libraries // .)[]?.id // empty' <<<"$libraries")
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
      Group = "root";
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
