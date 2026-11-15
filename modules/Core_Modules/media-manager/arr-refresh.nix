# Builds the Media Manager "folder-rescan" integration for a Radarr-style app:
# after a video conversion (or an App refresh request) the app rescans its
# library from disk, re-linking files whose extension changed.
{ config, lib, pkgs, vars }:
{ id, label, port, configXml, command }:
let
  renderShell = import ../../../lib/render-shell-template.nix { inherit lib; };
  unit = "media-manager-refresh-${id}";
  script = pkgs.writeShellApplication {
    name = unit;
    runtimeInputs = [ pkgs.coreutils pkgs.curl pkgs.gnused pkgs.jq ];
    text = renderShell ../../../custom_apps/shell/media-manager/media-manager-refresh-arr.sh.in {
      APP_LABEL = lib.escapeShellArg label;
      VARS_NETWORKING_LOOPBACKIPV4 = vars.networking.loopbackIPv4;
      PORT = toString port;
      CONFIG_XML_QUOTED = lib.escapeShellArg configXml;
      COMMAND_QUOTED = lib.escapeShellArg command;
    };
  };
in
{
  repo.mediaManager.integrations.${id} = {
    available = true;
    refresh = {
      unit = "${unit}.service";
      successMessage = "${label} rescanned its library.";
      failureMessage = "${label} could not rescan its library. Check the adapter service log.";
    };
  };
  systemd.services.${unit} = {
    description = "Ask ${label} to rescan its library for Media Manager";
    after = [ "${id}.service" ];
    wants = [ "${id}.service" ];
    serviceConfig = {
      Type = "oneshot";
      User = "root";
      Group = "root";
      ExecStart = lib.getExe script;
      TimeoutStartSec = "75m";
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
      ReadOnlyPaths = [ configXml ];
      IPAddressDeny = "any";
      IPAddressAllow = [ "localhost" ];
      SystemCallArchitectures = "native";
      SystemCallFilter = [ "@system-service" "~@privileged" "~@resources" ];
    };
  };
}
