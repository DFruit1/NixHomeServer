{ vars, ... }:

let
  loopback = vars.networking.loopbackIPv4;
  host = "wiki.${vars.domain}";
in
{
  services.caddy.virtualHosts.${host} = {
    logFormat = null;
    useACMEHost = vars.domain;
    extraConfig = ''
      reverse_proxy http://${loopback}:${toString vars.networking.ports.oauth2ProxyKiwix} {
        header_up X-Forwarded-Proto https
      }
    '';
  };

  services.unbound.privateHosts.${host} = {
    target = "private";
  };
}
