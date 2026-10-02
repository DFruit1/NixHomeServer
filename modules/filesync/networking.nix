{ vars, ... }:

let
  host = "filesync-api.${vars.domain}";
  loopback = vars.networking.loopbackIPv4;
  port = vars.networking.ports.filesyncApi;
in
{
  services.caddy.virtualHosts.${host} = {
    logFormat = null;
    useACMEHost = vars.domain;
    extraConfig = ''
      encode zstd gzip
      @health path /healthz
      handle @health {
        reverse_proxy http://${loopback}:${toString port}
      }
      handle {
        reverse_proxy http://${loopback}:${toString port}
      }
    '';
  };

  services.unbound.privateHosts.${host} = {
    target = "private";
  };
}
