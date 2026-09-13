{ pkgs, vars, appPackages, ... }:

# Public Cloudflare edge for OpenCloud.
#
# Local/NetBird clients keep reaching `cloud.*` and `office.*` through the
# ordinary Caddy vhosts and never touch this path. The Cloudflare tunnel points
# those two hostnames at a dedicated loopback Caddy instance instead, which
# admits a request only once it carries the signed cookie issued by the share
# gate after a valid public share link was opened.
#
# Collabora's editor stays on its own `office.*` subdomain, matching the
# upstream OpenCloud topology (the WOPI endpoint is served by OpenCloud on the
# main domain, while the editor app lives on a separate host). The cookie is
# scoped to the bare domain so the editor iframe, which is same-site with
# `cloud.*`, is covered by the same session.

let
  loopback = vars.networking.loopbackIPv4;
  cloudHost = "cloud.${vars.domain}";
  officeHost = "office.${vars.domain}";
  opencloudPort = vars.networking.ports.opencloud;
  collaboraPort = vars.networking.ports.collaboraOnline;
  gatePort = vars.networking.ports.opencloudShareGate;
  edgePort = vars.networking.ports.opencloudPublicEdge;

  gateUser = "opencloud-share-gate";
  edgeUser = "opencloud-public-edge";

  cookieName = "__Secure-ocshare";
  cookieDomain = ".${vars.domain}";
  cookieTtlSecs = 12 * 60 * 60;

  upstreamHeaders = ''
    header_up X-Forwarded-Proto https
    header_up X-Forwarded-Host {host}
  '';

  forwardAuth = ''
    forward_auth http://${loopback}:${toString gatePort} {
      uri /verify
      @denied status 401
      handle_response @denied {
        respond "Not Found" 404
      }
    }
  '';

  edgeCaddyfile = pkgs.writeText "opencloud-public-edge.Caddyfile" ''
    {
      admin off
      auto_https off
    }

    http://:${toString edgePort} {
      bind ${loopback}

      @cloud host ${cloudHost}
      @office host ${officeHost}

      handle @cloud {
        route {
          # Collabora's server-side WOPI callbacks carry no browser cookie;
          # OpenCloud authenticates them with the short-lived WOPI access token.
          @wopi path /wopi /wopi/*
          handle @wopi {
            reverse_proxy http://${loopback}:${toString opencloudPort} {
              ${upstreamHeaders}
            }
          }

          # A cookie-less navigation to a public share link is validated by the
          # gate, which issues the signed cookie and redirects back.
          @shareNav {
            method GET HEAD
            path_regexp share ^/(index\.php/)?s/[A-Za-z0-9._~-]+(/.*)?$
            not header_regexp Cookie (^|;\s*)${cookieName}=
          }
          handle @shareNav {
            reverse_proxy http://${loopback}:${toString gatePort}
          }

          # Everything else on the cloud host requires a valid share cookie.
          handle {
            ${forwardAuth}
            reverse_proxy http://${loopback}:${toString opencloudPort} {
              ${upstreamHeaders}
            }
          }
        }
      }

      # Collabora editor UI for public share sessions; gated by the same cookie.
      handle @office {
        route {
          ${forwardAuth}
          reverse_proxy http://${loopback}:${toString collaboraPort} {
            ${upstreamHeaders}
          }
        }
      }

      respond "Not Found" 404
    }
  '';
in
{
  users.groups.${gateUser} = { };
  users.users.${gateUser} = {
    isSystemUser = true;
    group = gateUser;
  };

  users.groups.${edgeUser} = { };
  users.users.${edgeUser} = {
    isSystemUser = true;
    group = edgeUser;
  };

  systemd.services.opencloud-share-gate = {
    description = "Signed-cookie gate for public OpenCloud share links";
    wantedBy = [ "multi-user.target" ];
    wants = [ "opencloud.service" ];
    after = [
      "network.target"
      "opencloud.service"
    ];
    environment = {
      OPENCLOUD_SHARE_GATE_LISTEN = "${loopback}:${toString gatePort}";
      OPENCLOUD_SHARE_GATE_OPENCLOUD_URL = "http://${loopback}:${toString opencloudPort}";
      OPENCLOUD_SHARE_GATE_COOKIE_NAME = cookieName;
      OPENCLOUD_SHARE_GATE_COOKIE_DOMAIN = cookieDomain;
      OPENCLOUD_SHARE_GATE_COOKIE_TTL_SECS = toString cookieTtlSecs;
      # Generated on first start and preserved across restarts within a boot.
      OPENCLOUD_SHARE_GATE_COOKIE_KEY_FILE = "/run/opencloud-share-gate/cookie.key";
    };
    serviceConfig = {
      Type = "simple";
      User = gateUser;
      Group = gateUser;
      ExecStart = "${appPackages.opencloud-share-gate}/bin/opencloud-share-gate";
      Restart = "on-failure";
      RestartSec = "5s";
      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      RuntimeDirectory = "opencloud-share-gate";
      RuntimeDirectoryMode = "0700";
      RuntimeDirectoryPreserve = "restart";
      RestrictAddressFamilies = [
        "AF_INET"
        "AF_INET6"
      ];
    };
  };

  systemd.services.opencloud-public-edge = {
    description = "Public Cloudflare edge for OpenCloud share links and the Collabora editor";
    wantedBy = [ "multi-user.target" ];
    wants = [
      "opencloud-share-gate.service"
      "opencloud.service"
    ];
    after = [
      "network.target"
      "opencloud-share-gate.service"
      "opencloud.service"
    ];
    serviceConfig = {
      Type = "simple";
      User = edgeUser;
      Group = edgeUser;
      ExecStart = "${pkgs.caddy}/bin/caddy run --config ${edgeCaddyfile}";
      Restart = "on-failure";
      RestartSec = "5s";
      NoNewPrivileges = true;
      PrivateTmp = true;
    };
  };

  # Never publish a dead edge to the tunnel. The cloudflared NixOS module runs
  # one unit per tunnel named `cloudflared-tunnel-<name>`; the bare
  # `cloudflared.service` is not a real unit.
  systemd.services."cloudflared-tunnel-${vars.cloudflareTunnelName}" = {
    wants = [ "opencloud-public-edge.service" ];
    after = [ "opencloud-public-edge.service" ];
  };

  services.cloudflared.tunnels.${vars.cloudflareTunnelName}.ingress = {
    ${cloudHost} = {
      service = "http://${loopback}:${toString edgePort}";
      originRequest.httpHostHeader = cloudHost;
    };
    ${officeHost} = {
      service = "http://${loopback}:${toString edgePort}";
      originRequest.httpHostHeader = officeHost;
    };
  };
}
