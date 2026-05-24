{ config, vars, ... }:

let
  loopback = vars.networking.loopbackIPv4;
  httpsPort = vars.networking.ports.https;
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
      ingress."${vars.kanidmDomain}" = {
        service = "https://${loopback}:${toString httpsPort}";
        originRequest.originServerName = vars.kanidmDomain;
      };
      default = "http_status:404";
    };
  };

  systemd.services."cloudflared-tunnel-${vars.cloudflareTunnelName}" = {
    wants = [ "network-online.target" "unbound.service" ];
    after = [ "network-online.target" "unbound.service" ];
  };
}
