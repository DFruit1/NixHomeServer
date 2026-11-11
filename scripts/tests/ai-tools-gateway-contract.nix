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
    kanidmAuthSessionExpirySeconds = 86400;
    cloudflareTunnelName = "fixture";
    networking = { loopbackIPv4 = "127.0.0.1"; ports = { kopia = 51515; https = 443; }; };
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
  };
  evaluate = enabled: preflight: (lib.evalModules {
    specialArgs = { inherit pkgs vars; };
    modules = [
      ../../modules/Core_Modules/auth-gateway
      ../../modules/ai-tools/networking.nix
      ../../modules/ai-tools/services.nix
      ({ lib, ... }: {
        options = lib.genAttrs [ "services" "systemd" ] (_: lib.mkOption {
          type = lib.types.attrsOf lib.types.anything;
          default = { };
        }) // {
          assertions = lib.mkOption { type = lib.types.listOf lib.types.anything; default = [ ]; };
          nixhomeserver = lib.mkOption { type = lib.types.anything; default.modules = { }; };
          repo = {
            aiTools = lib.mapAttrs (_: value: lib.mkOption { type = lib.types.anything; default = value; }) appDefaults;
            monitoring = lib.mkOption { type = lib.types.anything; default.failureAlerts.targetUnit = "failure-alert.target"; };
            backups = lib.mkOption { type = lib.types.anything; default.snapshotRoots = [ "/persist" ]; };
          };
        };
        config.repo.aiTools.enable = enabled;
        config.repo.authGateway.protectedApps = lib.optionalAttrs enabled {
          aiTools.skipAuthPreflight = preflight;
        };
      })
    ];
  }).config;
  cfg = evaluate true false;
  disabled = evaluate false false;
  unsafe = evaluate true true;
  app = cfg.repo.authGateway.protectedApps.aiTools;
  route = cfg.services.caddy.virtualHosts."tools.example.test".extraConfig;
  direct = "reverse_proxy unix//run/ai-tools-gateway.sock";
  split = lib.splitString direct route;
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
assert cfg.systemd.services.ai-tools.requires == [ "ai-tools-gateway.socket" ];
assert cfg.systemd.services.ai-tools.environment.AI_TOOLS_GATEWAY_SOCKET == "/run/ai-tools-gateway.sock";
assert !(disabled.systemd.sockets or { } ? ai-tools-gateway);
assert !(disabled.systemd.services ? ai-tools);
assert !(disabled.repo.authGateway.protectedApps ? aiTools);
{
  authenticatedBranches = lib.length split - 1;
  protectedSocket = true;
  spoofableInternalRouterExcluded = true;
  preflightBypassRejected = true;
  disabledSocketAbsent = true;
}
