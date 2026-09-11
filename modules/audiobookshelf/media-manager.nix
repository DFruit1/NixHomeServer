{ config, lib, pkgs, vars, ... }:

let
  cfg = config.repo.mediaManager;
  renderShell = import ../../lib/render-shell-template.nix { inherit lib; };
  audiobookshelfMetadataAvailable = cfg.integrations.audiobookshelf.available or false;
  audiobookshelfMetadataCache = "/var/cache/media-manager-audiobookshelf/metadata.json";
  audiobookshelfRefreshAvailable = (cfg.integrations.audiobookshelf.available or false)
    && builtins.elem "library-refresh" cfg.integrations.audiobookshelf.capabilities;
  audiobookshelfMetadataExport = pkgs.writeShellApplication {
    name = "media-manager-audiobookshelf-metadata-export";
    runtimeInputs = [ pkgs.coreutils pkgs.curl pkgs.jq ];
    text = renderShell ../../custom_apps/shell/media-manager/media-manager-audiobookshelf-metadata-export.sh.in {
      VARS_NETWORKING_LOOPBACKIPV4 = vars.networking.loopbackIPv4;
      VARS_NETWORKING_PORTS_AUDIOBOOKSHELF = toString vars.networking.ports.audiobookshelf;
      AUDIOBOOKSHELFMETADATACACHE_QUOTED = lib.escapeShellArg audiobookshelfMetadataCache;
      CONFIG_AGE_SECRETS_ABSBOOTSTRAPPASS_PATH = config.age.secrets.absBootstrapPass.path;
      VARS_KANIDMADMINUSER_QUOTED = lib.escapeShellArg vars.kanidmAdminUser;
      VARS_SHAREDROOT_QUOTED = lib.escapeShellArg vars.sharedRoot;
      VARS_USERSROOT_QUOTED = lib.escapeShellArg vars.usersRoot;
    };
  };
  audiobookshelfRefresh = pkgs.writeShellApplication {
    name = "media-manager-refresh-audiobookshelf";
    runtimeInputs = [ pkgs.coreutils pkgs.curl pkgs.jq ];
    text = renderShell ../../custom_apps/shell/media-manager/media-manager-refresh-audiobookshelf.sh.in {
      VARS_NETWORKING_LOOPBACKIPV4 = vars.networking.loopbackIPv4;
      VARS_NETWORKING_PORTS_AUDIOBOOKSHELF = toString vars.networking.ports.audiobookshelf;
      CONFIG_AGE_SECRETS_ABSBOOTSTRAPPASS_PATH = config.age.secrets.absBootstrapPass.path;
      JQ = pkgs.jq;
      VARS_KANIDMADMINUSER_QUOTED = lib.escapeShellArg vars.kanidmAdminUser;
    };
  };
in
{
  repo.mediaManager.integrations.audiobookshelf = {
    available = true;
    refresh = {
      unit = "media-manager-refresh-audiobookshelf.service";
      metadataUnit = "media-manager-audiobookshelf-metadata.service";
      successMessage = "Audiobookshelf library scans and metadata observation completed.";
      failureMessage = "Audiobookshelf library scans failed. Check the adapter service log.";
    };
    environment = {
      MEDIA_MANAGER_AUDIOBOOKSHELF_METADATA_CACHE_FILE = audiobookshelfMetadataCache;
      MEDIA_MANAGER_AUDIOBOOKSHELF_PUBLIC_URL = "https://audiobooks.${vars.domain}";
    };
    readOnlyPaths = [ "-/var/cache/media-manager-audiobookshelf" ];
  };
  systemd.services.media-manager-audiobookshelf-metadata = lib.mkIf audiobookshelfMetadataAvailable {
    description = "Export a bounded Audiobookshelf metadata snapshot for Media Manager";
    after = [ "audiobookshelf.service" ];
    wants = [ "audiobookshelf.service" ];
    serviceConfig = {
      Type = "oneshot";
      User = "root";
      Group = "media-manager";
      ExecStart = lib.getExe audiobookshelfMetadataExport;
      CacheDirectory = "media-manager-audiobookshelf";
      CacheDirectoryMode = "0750";
      UMask = "0027";
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
      MemoryMax = "256M";
      TasksMax = 32;
      TimeoutStartSec = "3m";
      CapabilityBoundingSet = [ ];
      AmbientCapabilities = [ ];
      ReadOnlyPaths = [ config.age.secrets.absBootstrapPass.path ];
      IPAddressDeny = "any";
      IPAddressAllow = [ "localhost" ];
      SystemCallArchitectures = "native";
      SystemCallFilter = [ "@system-service" "~@privileged" "~@resources" ];
    };
  };
  systemd.timers.media-manager-audiobookshelf-metadata = lib.mkIf audiobookshelfMetadataAvailable {
    description = "Refresh the Media Manager Audiobookshelf metadata snapshot";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "3m";
      OnUnitInactiveSec = "30m";
      RandomizedDelaySec = "45s";
      Persistent = true;
      Unit = "media-manager-audiobookshelf-metadata.service";
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
}
