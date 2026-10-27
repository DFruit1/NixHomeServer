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
        message = "The groundwater platform trusts gateway identity headers and requires the shared authentication gateway.";
      }
    ];

    repo.authGateway.protectedApps.groundwater = {
      inherit host;
      upstream = "http://${loopback}:${toString vars.networking.ports.groundwaterLogger}";
      allowedGroups = [ "app-admin" "groundwater-user" ];
      apiUnauthenticated401 = true;
    };

    # The shared gateway owns Caddy, strips spoofable identity headers and
    # forwards verified identity through its loopback-only internal router.

    services.unbound.privateHosts.${host} = {
      target = "private";
    };
  };
}
