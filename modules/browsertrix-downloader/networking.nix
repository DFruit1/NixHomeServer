{ vars, ... }:

let
  host = "archives.${vars.domain}";
in
{
  services.caddy.virtualHosts.${host} = {
    logFormat = null;
    useACMEHost = vars.domain;
    extraConfig = ''
      handle {
        reverse_proxy http://${vars.networking.loopbackIPv4}:${toString vars.networking.ports.oauth2ProxyBrowsertrix} {
          header_up X-Forwarded-Proto https
        }
      }
    '';
  };

  services.unbound.privateHosts.${host}.target = "private";
}
