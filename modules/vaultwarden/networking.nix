{ config, lib, vars, ... }:

let
  loopback = vars.networking.loopbackIPv4;
in
{
  config = lib.mkIf config.nixhomeserver.apps.vaultwarden.enable {
    repo.networking = {
      ports.vaultwarden = {
        port = vars.networking.ports.vaultwarden;
        protocol = "tcp";
        bind = "loopback";
        owner = "vaultwarden";
      };

      caddy.virtualHosts."${vars.vaultwardenDomain}" = {
        owner = "vaultwarden";
        extraConfig = ''
          reverse_proxy http://${loopback}:${toString vars.networking.ports.vaultwarden} {
            header_up X-Forwarded-Proto https
            header_up X-Forwarded-Host {host}
          }
        '';
      };

      dns.privateHosts."${vars.vaultwardenDomain}" = {
        owner = "vaultwarden";
        target = "private";
      };
    };
  };
}
