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
    systemd.sockets.ai-tools-office-io = {
      description = "Caller-scoped Office file broker socket";
      wantedBy = [ "sockets.target" ];
      socketConfig = {
        ListenStream = "/run/ai-tools-office-io.sock";
        SocketUser = "ai-tools";
        SocketGroup = "ai-tools";
        SocketMode = "0600";
        RemoveOnStop = true;
        Service = "ai-tools-office-io.service";
      };
    };
    # This account has no file ACL grant. Only a disposable worker receives a
    # proven human's credentials. The parent never parses Office documents.
    systemd.services.ai-tools-office-io = {
      description = "Office file access under verified caller credentials";
      requires = [ "ai-tools-office-io.socket" ];
      after = [ "network-online.target" "kanidm.service" "ai-tools-shared-access.service" ];
      wants = [ "network-online.target" "ai-tools-shared-access.service" ];
      unitConfig = {
        RequiresMountsFor = [ cfg.sharedRoot cfg.workspaceRoot ];
        StartLimitIntervalSec = "15min";
        StartLimitBurst = 5;
        OnFailure = [ config.repo.monitoring.failureAlerts.targetUnit ];
      };
      environment = {
        AI_TOOLS_TRANSPORT = "office-broker";
        AI_TOOLS_GATEWAY_SOCKET = "/run/ai-tools-office-io.sock";
        AI_TOOLS_DIRECTORY_URL = "https://${vars.kanidmDomain}:${toString vars.networking.ports.kanidm}/";
        # These existing provisioning lists contain human persons. Unix tokens
        # alone do not distinguish a person from a service account.
        AI_TOOLS_OFFICE_HUMANS = builtins.toJSON (lib.unique (
          [ vars.kanidmAdminUser ] ++ (vars.kanidmAppUsers or [ ]) ++ (vars.filesSftpUsers or [ ])
        ));
        AI_TOOLS_SHARED_ROOT = cfg.sharedRoot;
        AI_TOOLS_WORKSPACE_ROOT = cfg.workspaceRoot;
      };
      serviceConfig = {
        ExecStart = "${cfg.runtime.package}/bin/ai-tools";
        User = "ai-tools-io";
        Group = "ai-tools-io";
        AmbientCapabilities = [ "CAP_SETUID" "CAP_SETGID" ];
        CapabilityBoundingSet = [ "CAP_SETUID" "CAP_SETGID" ];
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ReadOnlyPaths = [ cfg.sharedRoot ];
        ReadWritePaths = [ cfg.workspaceRoot ];
        ProtectHome = true;
        ProtectClock = true;
        ProtectControlGroups = true;
        ProtectHostname = true;
        ProtectKernelLogs = true;
        ProtectKernelModules = true;
        ProtectKernelTunables = true;
        LockPersonality = true;
        RestrictNamespaces = true;
        RestrictSUIDSGID = true;
        RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
        SystemCallArchitectures = "native";
        IPAddressDeny = "any";
        IPAddressAllow = "localhost";
        MemoryHigh = "256M";
        MemoryMax = "512M";
        MemorySwapMax = "0";
        Nice = 10;
        CPUWeight = 20;
        IOWeight = 20;
        Restart = "on-failure";
        RestartSec = "5s";
      };
    };
    # Only Caddy may connect. ai-tools receives the listening descriptor from
    # systemd and cannot connect to the pathname as its own Unix user.
    systemd.sockets.ai-tools-gateway = {
      description = "Authenticated AI Tools gateway socket";
      wantedBy = [ "sockets.target" ];
      socketConfig = {
        ListenStream = "/run/ai-tools-gateway.sock";
        SocketUser = "caddy";
        SocketGroup = "caddy";
        SocketMode = "0600";
        RemoveOnStop = true;
        Service = "ai-tools.service";
      };
    };

    systemd.services.ai-tools = {
      description = "MCP tools for the llama.cpp web UI, writing only to the shared AI workspace";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" "searxng.service" "ai-tools-shared-access.service" ];
      wants = [ "network-online.target" "ai-tools-shared-access.service" ];
      requires = [ "ai-tools-gateway.socket" "ai-tools-office-io.socket" ];
      unitConfig = {
        StartLimitIntervalSec = "15min";
        StartLimitBurst = 5;
        OnFailure = [ config.repo.monitoring.failureAlerts.targetUnit ];
        OnFailureJobMode = "replace-irreversibly";
        RequiresMountsFor = [
          cfg.sharedRoot
          cfg.workspaceRoot
        ];
      };
      environment = {
        AI_TOOLS_LISTEN = "${cfg.listenAddress}:${toString cfg.port}";
        AI_TOOLS_GATEWAY_SOCKET = "/run/ai-tools-gateway.sock";
        AI_TOOLS_OFFICE_IO_SOCKET = "/run/ai-tools-office-io.sock";
        AI_TOOLS_SEARXNG_URL = cfg.searxngUrl;
        AI_TOOLS_SEARXNG_TIMEOUT_SECS = toString cfg.searxngTimeoutSecs;
        AI_TOOLS_MAX_RESULTS = toString cfg.maxResults;
        AI_TOOLS_COLLABORA_URL = cfg.collaboraUrl;
        AI_TOOLS_SHARED_ROOT = cfg.sharedRoot;
        # Roots are configured for validation; only the separate broker opens them.
        AI_TOOLS_WORKSPACE_ROOT = cfg.workspaceRoot;
        # The pinned helper receives bytes inside an additional parser sandbox.
        AI_TOOLS_OFFICE_HELPER = "${cfg.officeHelper}/bin/ai-tools-office-helper";
        # rmcp rejects any Host the transport was not configured with, and Caddy
        # forwards the client's Host unchanged, so the service has to be told
        # the name the gateway publishes. Without this it starts loopback-only
        # and every proxied request is refused with a 403.
        AI_TOOLS_PUBLIC_HOST = "tools.${vars.domain}";
      } // lib.optionalAttrs (cfg.searchHost != null) {
        AI_TOOLS_SEARCH_HOST = cfg.searchHost;
      } // lib.optionalAttrs (cfg.youtubeHost != null) {
        AI_TOOLS_YOUTUBE_HOST = cfg.youtubeHost;
      } // lib.optionalAttrs (cfg.chatHost != null) {
        AI_TOOLS_CHAT_HOST = cfg.chatHost;
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
        # File access belongs exclusively to the separate caller worker.
        # The parser additionally has its own Landlock/seccomp boundary.
        InaccessiblePaths = [ cfg.sharedRoot ];
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
