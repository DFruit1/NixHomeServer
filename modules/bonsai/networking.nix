{ config, lib, vars, ... }:

let
  cfg = config.repo.bonsai;
in
{
  options.repo.bonsai = {
    listenAddress = lib.mkOption {
      type = lib.types.str;
      default = vars.networking.loopbackIPv4;
      readOnly = true;
      description = "Loopback-only llama.cpp API listen address.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = vars.networking.ports.bonsai;
      description = "Local OpenAI-compatible Bonsai API port.";
    };

    apiBaseUrl = lib.mkOption {
      type = lib.types.str;
      default = "http://${cfg.listenAddress}:${toString cfg.port}/v1";
      readOnly = true;
      description = "Stable local OpenAI-compatible base URL for other application modules.";
    };

    modelName = lib.mkOption {
      type = lib.types.str;
      default = "bonsai-ternary-27b";
      readOnly = true;
      description = "Stable API model alias for local application integrations.";
    };
  };

  config = lib.mkIf cfg.enable {
    repo.authGateway.protectedApps.bonsai = {
      host = "ai.${vars.domain}";
      upstream = "http://${cfg.listenAddress}:${toString cfg.port}";
      allowedGroups = [ "ai-users" ];
      apiUnauthenticated401 = true;
    };
    services.unbound.privateHosts."ai.${vars.domain}".target = "private";
    assertions = [
    {
      assertion = cfg.listenAddress == vars.networking.loopbackIPv4;
      message = "Bonsai has no API authentication and must remain bound to IPv4 loopback.";
    }
    {
      assertion = config.repo.authGateway.enable && config.repo.authGateway.mode == "gateway";
      message = "The AI UI requires the shared authentication gateway.";
    }
  ];
  };
}
