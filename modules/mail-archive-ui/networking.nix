{ config, lib, vars, ... }:

let
  loopback = vars.networking.loopbackIPv4;
  cfg = config.services.mail-archive-ui;
in
{
  config = lib.mkIf cfg.enable {
    repo.networking = {
      ports = {
        mail-archive-ui = {
          port = vars.networking.ports.mailArchiveUi;
          protocol = "tcp";
          bind = "loopback";
          owner = "mail-archive-ui";
        };
        oauth2-proxy-mail-archive = {
          port = vars.networking.ports.oauth2ProxyMailArchive;
          protocol = "tcp";
          bind = "loopback";
          owner = "mail-archive-ui";
        };
      };

      caddy.virtualHosts."${vars.emailsDomain}" = {
        owner = "mail-archive-ui";
        extraConfig = ''
          reverse_proxy http://${loopback}:${toString vars.networking.ports.oauth2ProxyMailArchive} {
            header_up X-Forwarded-Proto https
            header_up X-Forwarded-Host {host}
          }
        '';
      };

      dns.privateHosts."${vars.emailsDomain}" = {
        owner = "mail-archive-ui";
        target = "private";
      };
    };
  };
}
