{ config, lib, pkgs, vars, ... }:

let
  cfg = config.repo.mediaManager;
  renderShell = import ../../lib/render-shell-template.nix { inherit lib; };
  jellyfinMetadataAvailable = cfg.integrations.jellyfin.available or false;
  jellyfinMetadataCache = "/var/cache/media-manager-jellyfin/metadata.json";
  jellyfinApiKeyMirror = "/var/cache/media-manager-jellyfin/api-key";
  jellyfinBaseUrl = "http://${vars.networking.loopbackIPv4}:${toString vars.networking.ports.jellyfin}";
  # Online sources Jellyfin itself uses for movies and shows, by display name.
  fetchers = import ./metadata-fetchers.nix;
  sourceNames = {
    TheMovieDb = "TMDB";
    TheTVDB = "TheTVDB";
    Fanart = "Fanart.tv";
  };
  videoKinds = [ "Movie" "Series" ];
  jellyfinMetadataSources = lib.unique (map (fetcher: sourceNames.${fetcher})
    (lib.filter (fetcher: sourceNames ? ${fetcher})
      (lib.concatMap (kind: fetchers.${kind}.MetadataFetcherOrder) videoKinds
        ++ lib.concatMap (kind: fetchers.${kind}.ImageFetcherOrder) videoKinds)));
  jellyfinRefreshAvailable = (cfg.integrations.jellyfin.available or false)
    && builtins.elem "library-refresh" cfg.integrations.jellyfin.capabilities;
  jellyfinRefresh = pkgs.writeShellApplication {
    name = "media-manager-refresh-jellyfin";
    runtimeInputs = [ pkgs.coreutils pkgs.curl pkgs.jq ];
    text = renderShell ../../custom_apps/shell/media-manager/media-manager-refresh-jellyfin.sh.in {
      VARS_NETWORKING_LOOPBACKIPV4 = vars.networking.loopbackIPv4;
      VARS_NETWORKING_PORTS_JELLYFIN = toString vars.networking.ports.jellyfin;
    };
  };
  jellyfinMetadataExport = pkgs.writeShellApplication {
    name = "media-manager-jellyfin-metadata-export";
    runtimeInputs = [ pkgs.coreutils pkgs.curl pkgs.gnugrep pkgs.jq ];
    text = renderShell ../../custom_apps/shell/media-manager/media-manager-jellyfin-metadata-export.sh.in {
      VARS_NETWORKING_LOOPBACKIPV4 = vars.networking.loopbackIPv4;
      VARS_NETWORKING_PORTS_JELLYFIN = toString vars.networking.ports.jellyfin;
      JELLYFINMETADATACACHE_QUOTED = lib.escapeShellArg jellyfinMetadataCache;
      JELLYFINAPIKEYMIRROR_QUOTED = lib.escapeShellArg jellyfinApiKeyMirror;
      VARS_SHAREDROOT_QUOTED = lib.escapeShellArg vars.sharedRoot;
      VARS_USERSROOT_QUOTED = lib.escapeShellArg vars.usersRoot;
    };
  };
in
{
  repo.mediaManager.integrations.jellyfin = {
    available = true;
    refresh = {
      unit = "media-manager-refresh-jellyfin.service";
      metadataUnit = "media-manager-jellyfin-metadata.service";
      successMessage = "Jellyfin library scan and metadata observation completed.";
      failureMessage = "Jellyfin library scan failed. Check the adapter service log.";
    };
    environment = {
      MEDIA_MANAGER_JELLYFIN_METADATA_CACHE_FILE = jellyfinMetadataCache;
      MEDIA_MANAGER_JELLYFIN_BASE_URL = jellyfinBaseUrl;
      MEDIA_MANAGER_JELLYFIN_API_KEY_FILE = jellyfinApiKeyMirror;
      MEDIA_MANAGER_JELLYFIN_PUBLIC_URL = "https://videos.${vars.domain}";
    };
    readOnlyPaths = [ "-/var/cache/media-manager-jellyfin" ];
  };
  # Online services shows Jellyfin beside Immich under "On this server", with
  # the metadata sources it already uses inside Jellyfin.
  systemd.services.media-manager-provider-broker.environment = {
    MEDIA_MANAGER_JELLYFIN_BASE_URL = jellyfinBaseUrl;
    MEDIA_MANAGER_JELLYFIN_METADATA_SOURCES = lib.concatStringsSep "," jellyfinMetadataSources;
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
  systemd.services.media-manager-jellyfin-metadata = lib.mkIf jellyfinMetadataAvailable {
    description = "Export a bounded Jellyfin metadata snapshot for Media Manager";
    after = [ "jellyfin.service" ];
    wants = [ "jellyfin.service" ];
    serviceConfig = {
      Type = "oneshot";
      User = "root";
      Group = "media-manager";
      ExecStart = lib.getExe jellyfinMetadataExport;
      CacheDirectory = "media-manager-jellyfin";
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
      # Two listings plus up to six first-time subtitle extractions.
      TimeoutStartSec = "8m";
      CapabilityBoundingSet = [ ];
      AmbientCapabilities = [ ];
      ReadOnlyPaths = [ "/var/lib/jellyfin/data/library-sync.api-key" ];
      IPAddressDeny = "any";
      IPAddressAllow = [ "localhost" ];
      SystemCallArchitectures = "native";
      SystemCallFilter = [ "@system-service" "~@privileged" "~@resources" ];
    };
  };
  systemd.timers.media-manager-jellyfin-metadata = lib.mkIf jellyfinMetadataAvailable {
    description = "Refresh the Media Manager Jellyfin metadata snapshot";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "2m";
      OnUnitInactiveSec = "30m";
      RandomizedDelaySec = "30s";
      Persistent = true;
      Unit = "media-manager-jellyfin-metadata.service";
    };
  };
}
