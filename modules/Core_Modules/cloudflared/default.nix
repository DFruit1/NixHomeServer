{ config, vars, ... }:

let
  loopback = vars.networking.loopbackIPv4;
  httpsPort = vars.networking.ports.https;
  ingressConfig = builtins.mapAttrs
    (_: ingress: {
      service = ingress.service;
      originRequest.originServerName = ingress.originServerName;
    })
    config.repo.networking.cloudflare.ingress;
in
{
  users.users.cloudflared = {
    isSystemUser = true;
    group = "cloudflared";
    home = "/var/lib/cloudflared";
  };

  users.groups.cloudflared = { };

  repo.networking.cloudflare.ingress."${vars.kanidmDomain}" = {
    owner = "core";
    service = "https://${loopback}:${toString httpsPort}";
    originServerName = vars.kanidmDomain;
  };

  services.cloudflared = {
    enable = true;

    tunnels.${vars.cloudflareTunnelName} = {
      credentialsFile = config.age.secrets.cfHomeCreds.path;
      ingress = ingressConfig;
      default = "http_status:404";
    };
  };

  systemd.services."cloudflared-tunnel-${vars.cloudflareTunnelName}" = {
    wants = [ "network-online.target" "unbound.service" ];
    after = [ "network-online.target" "unbound.service" ];
  };
}
