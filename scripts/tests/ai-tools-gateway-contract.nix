# Focused settings evaluation: the real gateway and AI Tools networking/service
# modules, with inert platform stubs. No host evaluation, build or live service.
# Tests are justified by the risk of sending private-data calls to a forgeable
# loopback router instead of the authenticated Unix socket.
{ lib, pkgs }:
let
  vars = {
    domain = "example.test";
    kopiaDomain = "backups.example.test";
    backupAdminGroup = "backup-admin";
    kanidmDomain = "identity.example.test";
    kanidmAdminUser = "operator";
    kanidmAppUsers = [ "alice" ];
    kanidmAuthSessionExpirySeconds = 86400;
    cloudflareTunnelName = "fixture";
    networking = { loopbackIPv4 = "127.0.0.1"; ports = { kopia = 51515; https = 443; kanidm = 8443; }; };
  };
  appDefaults = {
    enable = true;
    runtime.package = "/nix/store/fixture-ai-tools";
    searxngUrl = "http://127.0.0.1:8098";
    collaboraUrl = "http://127.0.0.1:9980";
    sharedRoot = "/mnt/data/shared";
    workspaceRoot = "/mnt/data/shared/ai-workspace";
    workspaceDirName = "ai-workspace";
    officeHelper = "/nix/store/fixture-office-helper";
    searchHost = null;
    youtubeHost = null;
    chatHost = null;
  };
  evaluate = enabled: preflight: chatEnabled: (lib.evalModules {
    specialArgs = { inherit pkgs vars; };
    modules = [
      ../../modules/Core_Modules/auth-gateway
      ../../modules/ai-tools/networking.nix
      ../../modules/ai-tools/services.nix
      ../../modules/Integrations/serve_ai_tools_through_bonsai.nix
      ({ lib, ... }: {
        options = lib.genAttrs [ "services" "systemd" ] (_: lib.mkOption {
          type = lib.types.attrsOf lib.types.anything;
          default = { };
        }) // {
          assertions = lib.mkOption { type = lib.types.listOf lib.types.anything; default = [ ]; };
          nixhomeserver = lib.mkOption { type = lib.types.anything; default.modules = { }; };
          repo = {
            aiTools = lib.mapAttrs (_: value: lib.mkOption { type = lib.types.anything; default = value; }) appDefaults;
            bonsai = lib.mapAttrs (_: value: lib.mkOption { type = lib.types.anything; default = value; }) {
              enable = chatEnabled;
              listenAddress = "127.0.0.1";
              port = 8094;
              extraArgs = [ ];
            };
            monitoring = lib.mkOption { type = lib.types.anything; default.failureAlerts.targetUnit = "failure-alert.target"; };
            backups = lib.mkOption { type = lib.types.anything; default.snapshotRoots = [ "/persist" ]; };
          };
        };
        config.repo.aiTools.enable = enabled;
        config.repo.authGateway.protectedApps = lib.optionalAttrs enabled {
          aiTools.skipAuthPreflight = preflight;
        } // lib.optionalAttrs chatEnabled {
          bonsai = {
            host = "ai.example.test";
            upstream = "http://127.0.0.1:8094";
            allowedGroups = [ "ai-users" ];
          };
        };
      })
    ];
  }).config;
  cfg = evaluate true false true;
  disabled = evaluate false false true;
  unsafe = evaluate true true true;
  noChat = evaluate true false false;
  app = cfg.repo.authGateway.protectedApps.aiTools;
  route = cfg.services.caddy.virtualHosts."tools.example.test".extraConfig;
  direct = "reverse_proxy unix//run/ai-tools-gateway.sock";
  split = lib.splitString direct route;
  chatRoute = cfg.services.caddy.virtualHosts."ai.example.test".extraConfig;
in
assert lib.all (check: check.assertion) cfg.assertions;
assert !(lib.all (check: check.assertion) unsafe.assertions);
assert app.upstream == null;
assert app.allowedGroups == [ "ai-users" ];
assert app.apiUnauthenticated401;
assert lib.length split == 4; # ordinary, Accept: JSON, and /api routes
assert lib.hasInfix "@denied_aiTools not header_regexp X-Auth-Request-Groups" route;
assert lib.hasInfix "copy_headers X-Auth-Request-User" route;
assert lib.hasInfix "request_header -X-Forwarded-User" route;
assert lib.hasInfix "header_up X-Forwarded-User {http.request.header.X-Auth-Request-User}" route;
assert lib.hasInfix "header_up X-Forwarded-Preferred-Username {http.request.header.X-Auth-Request-Preferred-Username}" route;
assert !(lib.hasInfix "reverse_proxy http://127.0.0.1:4188" route);
assert cfg.systemd.sockets.ai-tools-gateway.socketConfig == {
  ListenStream = "/run/ai-tools-gateway.sock";
  SocketUser = "caddy"; SocketGroup = "caddy"; SocketMode = "0600";
  RemoveOnStop = true; Service = "ai-tools.service";
};
assert cfg.systemd.services.ai-tools.requires == [ "ai-tools-gateway.socket" "ai-tools-office-io.socket" ];
assert cfg.systemd.services.ai-tools.serviceConfig.InaccessiblePaths == [ appDefaults.sharedRoot ];
assert cfg.systemd.sockets.ai-tools-office-io.socketConfig.SocketMode == "0600";
assert cfg.systemd.sockets.ai-tools-office-io.socketConfig.SocketUser == "ai-tools";
assert cfg.systemd.services.ai-tools-office-io.serviceConfig.CapabilityBoundingSet == [ "CAP_SETUID" "CAP_SETGID" ];
assert cfg.systemd.services.ai-tools-office-io.serviceConfig.User == "ai-tools-io";
assert builtins.fromJSON cfg.systemd.services.ai-tools-office-io.environment.AI_TOOLS_OFFICE_HUMANS == [ "operator" "alice" ];
assert cfg.systemd.services.ai-tools.environment.AI_TOOLS_GATEWAY_SOCKET == "/run/ai-tools-gateway.sock";
assert !(disabled.systemd.sockets or { } ? ai-tools-gateway);
assert !(disabled.systemd.services ? ai-tools);
assert !(disabled.repo.authGateway.protectedApps ? aiTools);
assert cfg.repo.aiTools.chatHost == "ai.example.test";
assert cfg.repo.authGateway.protectedApps.bonsai.allowedGroups == [ "ai-users" ];
assert lib.length (lib.splitString direct chatRoute) == 4;
assert lib.hasInfix "@chat_mcp path /mcp /mcp/*" chatRoute;
assert lib.hasInfix "@denied_bonsai not header_regexp X-Auth-Request-Groups" chatRoute;
assert lib.hasInfix "reverse_proxy http://127.0.0.1:8094" chatRoute;
assert lib.elem "--ui-config-file" cfg.repo.bonsai.extraArgs;
assert disabled.repo.aiTools.chatHost == null;
assert !(lib.hasInfix "/mcp" disabled.services.caddy.virtualHosts."ai.example.test".extraConfig);
assert noChat.repo.aiTools.chatHost == null;
assert !(noChat.repo.authGateway.protectedApps ? bonsai);
{
  authenticatedBranches = lib.length split - 1;
  protectedSocket = true;
  spoofableInternalRouterExcluded = true;
  preflightBypassRejected = true;
  disabledSocketAbsent = true;
  sameOriginChatRoute = true;
  disabledChatRouteAbsent = true;
}
