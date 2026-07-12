{ vars, ... }:

let
  loopback = vars.networking.loopbackIPv4;
in
{
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
