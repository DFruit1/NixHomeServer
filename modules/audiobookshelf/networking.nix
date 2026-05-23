{ config, vars, ... }:

let
  loopback = vars.networking.loopbackIPv4;
  host = "audiobooks.${vars.domain}";
in
{
  services.caddy.virtualHosts.${host} = {
    useACMEHost = vars.domain;
    extraConfig = ''
      reverse_proxy http://${loopback}:${toString config.services.audiobookshelf.port}
    '';
  };

  services.unbound.privateHosts.${host} = {
    target = "private";
  };
}
