{ config, lib, vars, ... }:

let
  loopback = vars.networking.loopbackIPv4;
in
{
  config = lib.mkIf config.nixhomeserver.apps.files.enable {
    repo.networking = {
      ports = {
        filestash = {
          port = vars.filesPort;
          protocol = "tcp";
          bind = "loopback";
          owner = "files";
        };
        oauth2-proxy-filestash = {
          port = vars.networking.ports.oauth2ProxyFilestash;
          protocol = "tcp";
          bind = "loopback";
          owner = "files";
        };
      };

      caddy.virtualHosts."${vars.filesDomain}" = {
        owner = "files";
        extraConfig = ''
          @download_html_svg path *.html *.svg
          header @download_html_svg Content-Disposition attachment
          header @download_html_svg X-Content-Type-Options nosniff
          reverse_proxy http://${loopback}:${toString vars.networking.ports.oauth2ProxyFilestash} {
            header_up X-Forwarded-Proto https
            header_up X-Forwarded-Host {host}
          }
        '';
      };

      dns.privateHosts."${vars.filesDomain}" = {
        owner = "files";
        target = "private";
      };
    };
  };
}
