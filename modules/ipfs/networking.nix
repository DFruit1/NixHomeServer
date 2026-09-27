{ config, lib, vars, ... }:

let
  host = "ipfs.${vars.domain}";
  loopback = vars.networking.loopbackIPv4;
  gatewayPort = vars.networking.ports.ipfsGateway;
  aliasPort = vars.networking.ports.ipfsAlias;
  swarmPort = vars.networking.ports.ipfsSwarm;
in
{
  config = lib.mkIf config.repo.ipfs.enable {
    services.caddy.virtualHosts.${host} = {
      logFormat = null;
      useACMEHost = vars.domain;
      extraConfig = ''
        @aliases path /published/* /fdroid/repo /fdroid/repo/*
        handle @aliases {
          reverse_proxy http://${loopback}:${toString aliasPort}
        }

        @content path /ipfs/*
        handle @content {
          reverse_proxy http://${loopback}:${toString gatewayPort}
        }

        handle {
          respond "IPFS content not found" 404
        }
      '';
    };

    services.unbound.privateHosts.${host} = {
      target = "private";
      publishOnLan = true;
      publishOnNetbird = true;
    };

    # Peers can fetch known CIDs over NetBird. The HTTP gateway stays behind Caddy.
    networking.firewall.interfaces.${vars.networking.interfaces.netbird}.allowedTCPPorts = [ swarmPort ];
  };
}
