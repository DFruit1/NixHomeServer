{ config, vars, ... }:

let
  loopback = vars.networking.loopbackIPv4;
  host = "paperless.${vars.domain}";
in
{
  services.caddy.virtualHosts.${host} = {
    useACMEHost = vars.domain;
    extraConfig = ''
      reverse_proxy http://${loopback}:${toString config.services.paperless.port}
    '';
  };

  services.unbound.privateHosts.${host} = {
    target = "private";
  };
}
