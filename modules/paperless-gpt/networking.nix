{ config, lib, vars, ... }:
{
  options.repo.paperlessGpt.port = lib.mkOption {
    type = lib.types.port;
    default = vars.networking.ports.paperlessGpt;
    description = "Loopback-only Paperless-GPT port.";
  };
  config = lib.mkIf config.repo.paperlessGpt.enable {
    assertions = [{
      assertion = config.repo.authGateway.enable && config.repo.authGateway.mode == "gateway";
      message = "Paperless-GPT requires the shared authentication gateway.";
    }];
    repo.authGateway.protectedApps.paperless-gpt = {
      host = "paperless-gpt.${vars.domain}";
      upstream = "http://${vars.networking.loopbackIPv4}:${toString config.repo.paperlessGpt.port}";
      allowedGroups = [ "paperless-gpt-users" ];
      apiUnauthenticated401 = true;
    };
    services.unbound.privateHosts."paperless-gpt.${vars.domain}".target = "private";
    # No public tunnel route and no direct firewall port.
  };
}
