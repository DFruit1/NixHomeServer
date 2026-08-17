{ config, lib, vars, ... }:

let
  loopback = vars.networking.loopbackIPv4;
  httpsPort = vars.networking.ports.https;
  filesEnabled = config.nixhomeserver.modules."files" or false;
in
{
  imports = [
    ./bootstrap.nix
  ];

  users.users.cloudflared = {
    isSystemUser = true;
    group = "cloudflared";
    home = "/var/lib/cloudflared";
  };

  users.groups.cloudflared = { };

  services.cloudflared = {
    enable = true;

    tunnels.${vars.cloudflareTunnelName} = {
      credentialsFile = config.age.secrets.cfHomeCreds.path;
      ingress = {
        "${vars.kanidmDomain}" = {
          service = "https://${loopback}:${toString httpsPort}";
          originRequest.originServerName = vars.kanidmDomain;
        };
      } // lib.optionalAttrs filesEnabled {
        # Unauthenticated public share-link host for Filestash. cloudflared
        # connects to the dedicated Caddy listener over TLS and validates the
        # presented certificate against this hostname.
        "transfers.${vars.domain}" = {
          service = "https://${loopback}:${toString vars.networking.ports.filestashTransfers}";
          originRequest.originServerName = "transfers.${vars.domain}";
        };
      };
      default = "http_status:404";
    };
  };

  systemd.services."cloudflared-tunnel-${vars.cloudflareTunnelName}" = {
    wants = [ "network-online.target" "unbound.service" ];
    after = [ "network-online.target" "unbound.service" ];
  };
}
