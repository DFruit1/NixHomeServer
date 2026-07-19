{ config, lib, vars, ... }:

let
  loopback = vars.networking.loopbackIPv4;
  host = "groundwater.${vars.domain}";
in
{
  config = lib.mkIf config.repo.groundwaterLogger.enable {
    assertions = [
      {
        assertion = config.repo.authGateway.enable && config.repo.authGateway.mode == "gateway";
        message = "Groundwater Logger publishes MQTT command topics and must be protected by the shared authentication gateway.";
      }
    ];

    repo.authGateway.protectedApps.groundwater = {
      inherit host;
      upstream = "http://${loopback}:${toString vars.networking.ports.groundwaterLogger}";
      allowedGroups = [ "app-admin" ];
      apiUnauthenticated401 = true;
    };

    services.caddy.virtualHosts.${host} = {
      logFormat = null;
      useACMEHost = vars.domain;
      extraConfig = ''
        reverse_proxy http://${loopback}:${toString vars.networking.ports.groundwaterLogger} {
          header_up X-Forwarded-Proto https
        }
      '';
    };

    services.unbound.privateHosts.${host} = {
      target = "private";
    };
  };
}
