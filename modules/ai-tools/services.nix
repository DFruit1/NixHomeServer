{ config, lib, pkgs, ... }:

let
  cfg = config.repo.aiTools;
  server = pkgs.writeShellApplication {
    name = "ai-tools-server";
    runtimeInputs = with pkgs; [ coreutils ];
    text = ''
      set -euo pipefail

      exec ${cfg.runtime.package}/bin/ai-tools
    '';
  };
in
{
  config = lib.mkIf cfg.enable {
    systemd.services.ai-tools = {
      description = "Read-only MCP tools for the llama.cpp web UI";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" "searxng.service" ];
      wants = [ "network-online.target" ];
      serviceConfig = {
        Type = "simple";
        User = "ai-tools";
        Group = "ai-tools";
        ExecStart = "${server}/bin/ai-tools-server";
        Restart = "on-failure";
        RestartSec = "5s";
        TimeoutStopSec = "10s";
        Environment = [
          "AI_TOOLS_LISTEN=${cfg.listenAddress}:${toString cfg.port}"
          "AI_TOOLS_SEARXNG_URL=${cfg.searxngUrl}"
          "AI_TOOLS_SEARXNG_TIMEOUT_SECS=${toString cfg.searxngTimeoutSecs}"
          "AI_TOOLS_MAX_RESULTS=${toString cfg.maxResults}"
          "AI_TOOLS_COLLABORA_URL=${cfg.collaboraUrl}"
          "AI_TOOLS_SHARED_ROOT=${cfg.sharedRoot}"
        ];
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        # convert_document reads documents from the shared root only. The unit
        # stays read-only so nothing it converts can be modified.
        ReadOnlyPaths = [ cfg.sharedRoot ];
        ProtectHome = true;
        ProtectClock = true;
        ProtectControlGroups = true;
        ProtectHostname = true;
        ProtectKernelLogs = true;
        ProtectKernelModules = true;
        ProtectKernelTunables = true;
        LockPersonality = true;
        RestrictSUIDSGID = true;
        RestrictNamespaces = true;
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
          "AF_UNIX"
        ];
        SystemCallArchitectures = "native";
        MemoryHigh = "512M";
        MemoryMax = "1G";
        MemorySwapMax = "0";
        Nice = 10;
        CPUWeight = 20;
        IOWeight = 20;
      };
      unitConfig = {
        StartLimitIntervalSec = "15min";
        StartLimitBurst = 5;
      };
    };
  };
}
