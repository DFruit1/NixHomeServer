{ vars, ... }:

let
  loopback = vars.networking.loopbackIPv4;
in
{
  repo.authGateway.protectedApps.monitor = {
    host = vars.monitorDomain;
    upstream = "http://${loopback}:${toString vars.networking.ports.beszelHub}";
    allowedGroups = [ vars.monitoringAccessGroup ];
  };

  services.caddy.virtualHosts.${vars.monitorDomain} = {
    logFormat = null;
    useACMEHost = vars.domain;
    extraConfig = ''
      reverse_proxy http://${loopback}:${toString vars.networking.ports.oauth2ProxyMonitor} {
        header_up X-Forwarded-Proto https
      }
    '';
  };

  services.unbound.privateHosts.${vars.monitorDomain} = {
    target = "private";
  };
}
