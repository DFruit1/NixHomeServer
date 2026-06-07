{ vars, ... }:

let
  loopback = vars.networking.loopbackIPv4;
  host = "homepage.${vars.domain}";
in
{
  services.caddy.virtualHosts.${host} = {
    useACMEHost = vars.domain;
    extraConfig = ''
      reverse_proxy http://${loopback}:${toString vars.networking.ports.oauth2ProxyHomepage} {
        header_up X-Forwarded-Proto https
        header_up X-Forwarded-Host {host}
      }
    '';
  };

  services.unbound.privateHosts.${host} = {
    target = "private";
  };
}
