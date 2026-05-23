{ config, vars, ... }:

let
  loopback = vars.networking.loopbackIPv4;
  host = "books.${vars.domain}";
in
{
  services.caddy.virtualHosts.${host} = {
    useACMEHost = vars.domain;
    extraConfig = ''
      reverse_proxy http://${loopback}:${toString config.services.kavita.settings.Port}
    '';
  };

  services.unbound.privateHosts.${host} = {
    target = "private";
  };
}
