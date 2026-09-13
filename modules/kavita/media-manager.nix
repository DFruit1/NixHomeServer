{ config, lib, pkgs, vars, ... }:

let
  cfg = config.repo.mediaManager;
  renderShell = import ../../lib/render-shell-template.nix { inherit lib; };
  kavitaMetadataAvailable = cfg.integrations.kavita.available or false;
  kavitaMetadataCache = "/var/cache/media-manager-kavita/metadata.json";
  kavitaRefreshAvailable = (cfg.integrations.kavita.available or false)
    && builtins.elem "library-refresh" cfg.integrations.kavita.capabilities;
  kavitaMetadataExport = pkgs.writeShellApplication {
    name = "media-manager-kavita-metadata-export";
    runtimeInputs = [ pkgs.bash pkgs.coreutils pkgs.curl pkgs.findutils pkgs.jq pkgs.python3 pkgs.sqlite ];
    text = renderShell ../../custom_apps/shell/media-manager/media-manager-kavita-metadata-export.sh.in {
      VARS_NETWORKING_LOOPBACKIPV4 = vars.networking.loopbackIPv4;
      VARS_NETWORKING_PORTS_KAVITA = toString vars.networking.ports.kavita;
      KAVITAMETADATACACHE_QUOTED = lib.escapeShellArg kavitaMetadataCache;
      CONFIG_AGE_SECRETS_KAVITATOKENKEY_PATH_QUOTED = lib.escapeShellArg config.age.secrets.kavitaTokenKey.path;
      VARS_KANIDMADMINUSER_QUOTED = lib.escapeShellArg vars.kanidmAdminUser;
      VARS_SHAREDROOT_QUOTED = lib.escapeShellArg vars.sharedRoot;
      VARS_USERSROOT_QUOTED = lib.escapeShellArg vars.usersRoot;
    };
  };
  kavitaRefresh = pkgs.writeShellApplication {
    name = "media-manager-refresh-kavita";
    runtimeInputs = [ pkgs.coreutils pkgs.curl pkgs.jq pkgs.python3 pkgs.sqlite ];
    text = renderShell ../../custom_apps/shell/media-manager/media-manager-refresh-kavita.sh.in {
      VARS_NETWORKING_LOOPBACKIPV4 = vars.networking.loopbackIPv4;
      VARS_NETWORKING_PORTS_KAVITA = toString vars.networking.ports.kavita;
      CONFIG_AGE_SECRETS_KAVITATOKENKEY_PATH_QUOTED = lib.escapeShellArg config.age.secrets.kavitaTokenKey.path;
      VARS_KANIDMADMINUSER_QUOTED = lib.escapeShellArg vars.kanidmAdminUser;
    };
  };
in
{
  repo.mediaManager.integrations.kavita = {
    available = true;
    refresh = {
      unit = "media-manager-refresh-kavita.service";
      metadataUnit = "media-manager-kavita-metadata.service";
      successMessage = "Kavita library scans and metadata observation completed.";
      failureMessage = "Kavita library scans failed. Check the adapter service log.";
    };
    environment = {
      MEDIA_MANAGER_KAVITA_METADATA_CACHE_FILE = kavitaMetadataCache;
      MEDIA_MANAGER_KAVITA_PUBLIC_URL = "https://books.${vars.domain}";
    };
    readOnlyPaths = [ "-/var/cache/media-manager-kavita" ];
  };
  systemd.services.media-manager-kavita-metadata = lib.mkIf kavitaMetadataAvailable {
    description = "Export a bounded Kavita metadata snapshot for Media Manager";
    after = [ "kavita.service" ];
    wants = [ "kavita.service" ];
    serviceConfig = {
      Type = "oneshot";
      User = "kavita";
      Group = "media-manager";
      ExecStart = lib.getExe kavitaMetadataExport;
      CacheDirectory = "media-manager-kavita";
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
      # SQLite must create and read -shm/-wal side files when opening the
      # WAL-mode database, even for mode=ro access. The exporter still opens
      # the database with mode=ro, so its content is never modified; only the
      # directory needs to be writable for side-file management.
      ReadWritePaths = [ "/var/lib/kavita/config" ];
      ReadOnlyPaths = [ config.age.secrets.kavitaTokenKey.path ];
      IPAddressDeny = "any";
      IPAddressAllow = [ "localhost" ];
      SystemCallArchitectures = "native";
      SystemCallFilter = [ "@system-service" "~@privileged" "~@resources" "fchown" ];
    };
  };
  systemd.timers.media-manager-kavita-metadata = lib.mkIf kavitaMetadataAvailable {
    description = "Refresh the Media Manager Kavita metadata snapshot";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "4m";
      OnUnitInactiveSec = "30m";
      RandomizedDelaySec = "45s";
      Persistent = true;
      Unit = "media-manager-kavita-metadata.service";
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
}
