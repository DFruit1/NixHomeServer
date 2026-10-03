{ config, lib, vars, ... }:

let
  cfg = config.repo.searxng;
in
{
  options.repo.searxng = {
    port = lib.mkOption {
      type = lib.types.port;
      default = vars.networking.ports.searxng or 8098;
      description = "Loopback SearXNG port, reachable only from ai-tools.";
    };

    stateDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/searxng";
      description = "Per-service state directory. SearXNG keeps no durable state here.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        # SearXNG is loopback-only and reaches the network solely as ai-tools'
        # upstream, so the invariant to protect is that nothing publishes
        # *SearXNG itself* through the gateway.
        #
        # Matching on the `ai.<domain>` host instead would be wrong: that host
        # belongs to the local model UI, which is a protected app in its own
        # right, so the assertion fired on a legitimate registration.
        assertion = !builtins.any (
          app: (app.upstream or null) == "http://${vars.networking.loopbackIPv4}:${toString cfg.port}"
        ) (builtins.attrValues config.repo.authGateway.protectedApps);
        message = "searxng must never be published through the gateway; only the ai-tools MCP host is exposed.";
      }
    ];
  };
}
