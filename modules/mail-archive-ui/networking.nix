{ config, lib, vars, ... }:

let
  loopback = vars.networking.loopbackIPv4;
  cfg = config.services.mail-archive-ui;
  host = "emails.${vars.domain}";
in
{
  config = lib.mkIf cfg.enable {
    services.caddy.virtualHosts.${host} = {
      logFormat = null;
      useACMEHost = vars.domain;
      extraConfig = ''
        reverse_proxy http://${loopback}:${toString vars.networking.ports.oauth2ProxyMailArchive} {
          header_up X-Forwarded-Proto https
        }
      '';
    };

    services.unbound.privateHosts.${host} = {
      target = "private";
    };
  };
}
