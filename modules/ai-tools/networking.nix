{ config, lib, vars, ... }:

let
  cfg = config.repo.aiTools;
in
{
  options.repo.aiTools = {
    listenAddress = lib.mkOption {
      type = lib.types.str;
      default = vars.networking.loopbackIPv4;
      readOnly = true;
      description = "Loopback-only MCP listen address. The gateway is the only client.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = vars.networking.ports.aiTools or 8097;
      description = "Local MCP Streamable HTTP port.";
    };

    searxngTimeoutSecs = lib.mkOption {
      type = lib.types.ints.positive;
      default = 20;
      description = "Upstream timeout for a SearXNG query, in seconds.";
    };

    maxResults = lib.mkOption {
      type = lib.types.ints.positive;
      default = 8;
      description = "Upper bound on results returned by web_search.";
    };
  };

  config = lib.mkIf cfg.enable {
    repo.authGateway.protectedApps.aiTools = {
      host = "tools.${vars.domain}";
      upstream = "http://${cfg.listenAddress}:${toString cfg.port}";
      allowedGroups = [ "ai-users" ];
      apiUnauthenticated401 = true;
    };

    services.unbound.privateHosts."tools.${vars.domain}".target = "private";

    assertions = [
      {
        assertion = cfg.listenAddress == vars.networking.loopbackIPv4;
        message = "repo.aiTools.listenAddress must stay on IPv4 loopback; the gateway is the only client.";
      }
    ];
  };
}
