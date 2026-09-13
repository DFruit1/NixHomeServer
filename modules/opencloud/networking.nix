{ vars, ... }:

let
  loopback = vars.networking.loopbackIPv4;
  cloudHost = "cloud.${vars.domain}";
  officeHost = "office.${vars.domain}";
in
{
  assertions = [
    {
      assertion = cloudHost != officeHost;
      message = "opencloud: the OpenCloud and Collabora hostnames must be distinct.";
    }
  ];

  # Both upstreams bind loopback only; Caddy terminates TLS. This is the sole
  # ingress for LAN and NetBird. Public Cloudflare access is added separately
  # by public-access.nix through a dedicated gated edge. No direct firewall
  # ports are published.
  services.caddy.virtualHosts = {
    ${cloudHost} = {
      logFormat = null;
      useACMEHost = vars.domain;
      extraConfig = ''
        reverse_proxy http://${loopback}:${toString vars.networking.ports.opencloud} {
          header_up X-Forwarded-Proto https
        }
      '';
    };
    ${officeHost} = {
      logFormat = null;
      useACMEHost = vars.domain;
      extraConfig = ''
        # Answer the editor root deterministically so the deploy public-route
        # check never depends on Collabora's optional welcome screen.
        @root path /
        respond @root "Collabora Online editor" 200
        reverse_proxy http://${loopback}:${toString vars.networking.ports.collaboraOnline} {
          header_up X-Forwarded-Proto https
        }
      '';
    };
  };

  services.unbound.privateHosts = {
    ${cloudHost} = {
      target = "private";
    };
    ${officeHost} = {
      target = "private";
    };
  };
}
