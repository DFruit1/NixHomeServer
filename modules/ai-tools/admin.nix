{ config, lib, pkgs, vars, ... }:
let
  cfg = config.repo.aiTools;
  admin = cfg.admin;
  host = "tools.${vars.domain}";
  validUnit = unit: lib.stringLength unit <= 200
    && builtins.match "[A-Za-z0-9][A-Za-z0-9_.:@-]*\\.service" unit != null;
  # Only ordinary application daemons are restartable by default. Identity,
  # routing, networking, storage, backup and the administration broker itself
  # are intentionally absent. Disabled/removed application units disappear.
  candidates = [ "audiobookshelf" "bonsai-llama" "phpfpm-freshrss" "immich-server"
    "jellyfin" "kavita" "mail-archive-ui" "paperless-web" "paperless-task-queue"
    "search-ui" "searxng" "youtube-downloader" ];
  present = name: builtins.hasAttr name config.systemd.services;
  backendConfig = builtins.toJSON {
    username = vars.kanidmAdminUser;
    inherit host;
    systemctl = "${pkgs.systemd}/bin/systemctl";
    diagnostic_services = admin.diagnosticServices;
    restartable_services = admin.restartableServices;
  };
in
{
  options.repo.aiTools.admin = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Offer bounded server-administration tools only to the configured Kanidm server-admin login.";
    };
    diagnosticServices = lib.mkOption {
      type = lib.types.listOf (lib.types.addCheck lib.types.str validUnit);
      default = builtins.filter validUnit (map (name: "${name}.service") (builtins.attrNames config.systemd.services));
      readOnly = true;
      description = "Configured service names whose non-secret systemd state may be inspected.";
    };
    restartableServices = lib.mkOption {
      type = lib.types.listOf (lib.types.addCheck lib.types.str validUnit);
      default = map (name: "${name}.service") (builtins.filter present candidates);
      description = "Explicit application restart allowlist. This grants no other systemctl operation.";
    };
  };

  config = lib.mkIf (cfg.enable && admin.enable) {
    assertions = [ {
      assertion = lib.all (unit: builtins.elem unit admin.diagnosticServices) admin.restartableServices;
      message = "AI admin restart targets must be configured services in the diagnostic allowlist.";
    } ];
    systemd.services.ai-tools.environment = {
      AI_TOOLS_ADMIN_USERNAME = vars.kanidmAdminUser;
      AI_TOOLS_ADMIN_HOST = host;
    };
    systemd.sockets.ai-tools-admin = {
      description = "Caddy-only server-administration socket";
      wantedBy = [ "sockets.target" ];
      socketConfig = {
        ListenStream = "/run/ai-tools-admin.sock";
        SocketUser = "caddy";
        SocketGroup = "caddy";
        SocketMode = "0600";
        RemoveOnStop = true;
        Service = "ai-tools-admin.service";
      };
    };
    systemd.services.ai-tools-admin = {
      description = "Bounded AI server administration for the configured owner";
      requires = [ "ai-tools-admin.socket" ];
      unitConfig = {
        StartLimitIntervalSec = "15min";
        StartLimitBurst = 5;
        OnFailure = [ config.repo.monitoring.failureAlerts.targetUnit ];
      };
      environment = {
        AI_TOOLS_TRANSPORT = "admin";
        AI_TOOLS_GATEWAY_SOCKET = "/run/ai-tools-admin.sock";
        AI_TOOLS_ADMIN_CONFIG = backendConfig;
      };
      serviceConfig = {
        User = "root";
        ExecStart = "${cfg.runtime.package}/bin/ai-tools";
        Restart = "on-failure";
        RestartSec = "5s";
        TimeoutStopSec = "10s";
        NoNewPrivileges = true;
        # An empty Nix list omits the directive; an empty assignment clears it.
        CapabilityBoundingSet = "";
        PrivateTmp = true;
        PrivateDevices = true;
        PrivateNetwork = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ProtectProc = "invisible";
        InaccessiblePaths = [ "-/run/agenix" "-/persist" "-/var/lib" cfg.sharedRoot ];
        ProtectClock = true;
        ProtectControlGroups = true;
        ProtectHostname = true;
        ProtectKernelLogs = true;
        ProtectKernelModules = true;
        ProtectKernelTunables = true;
        LockPersonality = true;
        RestrictSUIDSGID = true;
        RestrictNamespaces = true;
        RestrictAddressFamilies = [ "AF_UNIX" ];
        SystemCallArchitectures = "native";
        IPAddressDeny = "any";
        MemoryHigh = "128M";
        MemoryMax = "256M";
        MemorySwapMax = "0";
        Nice = 10;
        CPUWeight = 20;
        IOWeight = 20;
      };
    };
  };
}
