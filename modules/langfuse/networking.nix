{ config, lib, vars, ... }:
let
  cfg = config.repo.langfuse;
  host = "langfuse.${vars.domain}";
  upstream = "${vars.networking.loopbackIPv4}:${toString cfg.port}";
in {
  config = lib.mkIf cfg.enable {
    assertions = [ {
      assertion = config.repo.authGateway.enable && config.repo.authGateway.mode == "gateway";
      message = "Langfuse requires the shared authentication gateway.";
    } ];
    repo.authGateway.protectedApps.langfuse = {
      inherit host;
      allowedGroups = [ "langfuse-users" ];
      apiUnauthenticated401 = false;
      authenticatedCaddyConfig = "reverse_proxy ${upstream}";
      # Only the documented public API bypasses browser SSO. Langfuse checks
      # project Basic Auth itself, including OTLP ingestion below this prefix.
      nativeAuthPaths = [ "/api/public/*" ];
      nativeAuthCaddyConfig = "reverse_proxy ${upstream}";
    };
    services.unbound.privateHosts.${host}.target = "private";
  };
}
