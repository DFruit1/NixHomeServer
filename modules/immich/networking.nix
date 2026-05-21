{ config, lib, vars, ... }:

let
  loopback = vars.networking.loopbackIPv4;
  httpsPort = vars.networking.ports.https;
in
{
  config = lib.mkIf config.nixhomeserver.apps.immich.enable {
    assertions = [
      {
        assertion = vars.photosDomain != vars.sharePhotosDomain;
        message = "immich: private and public share hostnames must be distinct.";
      }
    ];

    repo.networking = {
      ports = {
        immich = {
          port = vars.networking.ports.immich;
          protocol = "tcp";
          bind = "loopback";
          owner = "immich";
        };
        immich-public-proxy = {
          port = vars.networking.ports.immichPublicProxy;
          protocol = "tcp";
          bind = "loopback";
          owner = "immich";
        };
        immich-public-proxy-container = {
          port = vars.networking.ports.immichPublicProxyContainer;
          protocol = "tcp";
          bind = "container";
          owner = "immich";
        };
      };

      caddy.virtualHosts = {
        "${vars.photosDomain}" = {
          owner = "immich";
          extraConfig = ''
            reverse_proxy http://${loopback}:${toString config.services.immich.port}
          '';
        };
        "${vars.sharePhotosDomain}" = {
          owner = "immich";
          extraConfig = ''
            reverse_proxy http://${loopback}:${toString vars.networking.ports.immichPublicProxy} {
              header_up X-Forwarded-Proto https
              header_up X-Forwarded-Host {host}
            }
          '';
        };
      };

      cloudflare.ingress."${vars.sharePhotosDomain}" = {
        owner = "immich";
        service = "https://${loopback}:${toString httpsPort}";
        originServerName = vars.sharePhotosDomain;
      };

      dns.privateHosts = {
        "${vars.photosDomain}" = {
          owner = "immich";
          target = "private";
        };
        "${vars.sharePhotosDomain}" = {
          owner = "immich";
          target = "private";
        };
      };
    };
  };
}
