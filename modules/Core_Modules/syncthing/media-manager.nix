{ config, lib, pkgs, ... }:

let
  cfg = config.repo.mediaManager;
  renderShell = import ../../../lib/render-shell-template.nix { inherit lib; };
  syncthingRefreshAvailable = (cfg.integrations.syncthing.available or false)
    && builtins.elem "folder-rescan" cfg.integrations.syncthing.capabilities;
  syncthingRefresh = pkgs.writeShellApplication {
    name = "media-manager-refresh-syncthing";
    runtimeInputs = [ pkgs.coreutils pkgs.curl pkgs.libxml2 ];
    text = renderShell ../../../custom_apps/shell/media-manager/media-manager-refresh-syncthing.sh.in { };
  };
in
{
  repo.mediaManager.integrations.syncthing = {
    available = config.services.syncthing.enable;
    refresh = {
      unit = "media-manager-refresh-syncthing.service";
      metadataUnit = "";
      successMessage = "Syncthing folder scan completed.";
      failureMessage = "Syncthing folder scan failed. Check the adapter service log.";
    };
    label = "Syncthing";
    capabilities = [ "folder-rescan" ];
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
