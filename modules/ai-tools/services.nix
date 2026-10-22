{ config, lib, pkgs, vars, ... }:

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
      after = [ "network-online.target" "searxng.service" "ai-tools-shared-access.service" ];
      wants = [ "network-online.target" "ai-tools-shared-access.service" ];
      unitConfig = {
        StartLimitIntervalSec = "15min";
        StartLimitBurst = 5;
        OnFailure = [ config.repo.monitoring.failureAlerts.targetUnit ];
        OnFailureJobMode = "replace-irreversibly";
      };
      environment = {
        AI_TOOLS_LISTEN = "${cfg.listenAddress}:${toString cfg.port}";
        AI_TOOLS_SEARXNG_URL = cfg.searxngUrl;
        AI_TOOLS_SEARXNG_TIMEOUT_SECS = toString cfg.searxngTimeoutSecs;
        AI_TOOLS_MAX_RESULTS = toString cfg.maxResults;
        AI_TOOLS_COLLABORA_URL = cfg.collaboraUrl;
        AI_TOOLS_SHARED_ROOT = cfg.sharedRoot;
        # Writes are confined here. The Rust side re-checks every write path
        # against this prefix; the sandbox below is what makes the refusal real
        # even if a future tool forgets to.
        AI_TOOLS_WORKSPACE_ROOT = cfg.workspaceRoot;
        # The pinned native xlsx/docx helper. It holds no grant of its own and
        # runs as part of this unit, in this sandbox, as this account.
        AI_TOOLS_OFFICE_HELPER = "${cfg.officeHelper}/bin/ai-tools-office-helper";
        # rmcp rejects any Host the transport was not configured with, and Caddy
        # forwards the client's Host unchanged, so the service has to be told
        # the name the gateway publishes. Without this it starts loopback-only
        # and every proxied request is refused with a 403.
        AI_TOOLS_PUBLIC_HOST = "tools.${vars.domain}";
      };
      serviceConfig = {
        Type = "simple";
        User = "ai-tools";
        Group = "ai-tools";
        ExecStart = "${server}/bin/ai-tools-server";
        Restart = "on-failure";
        RestartSec = "5s";
        TimeoutStopSec = "10s";
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        # convert_document reads documents from the shared root only. The unit
        # stays read-only so nothing it converts can be modified. The catalog
        # guards this unit on the data pool, so the path exists by exec time.
        ReadOnlyPaths = [ cfg.sharedRoot ];
        RequiresMountsFor = [ cfg.sharedRoot ];
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
        # Both upstreams are loopback, so nothing here needs to leave the host.
        # A prompt-injected tool call therefore cannot reach the network.
        IPAddressDeny = "any";
        IPAddressAllow = "localhost";
      };
    };
  };
}
