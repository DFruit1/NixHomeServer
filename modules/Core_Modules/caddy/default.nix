{ lib, vars, config, ... }:

let
  mailArchiveOauth2ProxyPort = 4181;
  jellyfinPort = 8096;
in
{
  services.caddy = {
    enable = true;

    ## Caddy will register this e-mail with Let’s Encrypt
    email = vars.kanidmAdminEmail;

    virtualHosts = {
      "${vars.domain}" = {
        extraConfig = ''
          tls /var/lib/acme/${vars.domain}/fullchain.pem /var/lib/acme/${vars.domain}/key.pem
          redir https://${vars.kanidmDomain}{uri} 308
        '';
      };

      "www.${vars.domain}" = {
        extraConfig = ''
          tls /var/lib/acme/${vars.domain}/fullchain.pem /var/lib/acme/${vars.domain}/key.pem
          redir https://${vars.kanidmDomain}{uri} 308
        '';
      };

      "${vars.kanidmDomain}" = {
        extraConfig = ''
          tls /var/lib/acme/${vars.kanidmDomain}/fullchain.pem /var/lib/acme/${vars.kanidmDomain}/key.pem
          @edge_http header X-Forwarded-Proto http
          redir @edge_http https://{host}{uri} 308
          reverse_proxy https://127.0.0.1:${toString vars.kanidmPort} {
            transport http {
              tls_server_name ${vars.kanidmDomain}
              tls_trust_pool file /var/lib/acme/${vars.kanidmDomain}/fullchain.pem
            }
            header_up X-Forwarded-Proto https
            header_up X-Forwarded-Host  {host}
          }
        '';
      };

      "paperless.${vars.domain}" = {
        extraConfig = ''
          tls /var/lib/acme/${vars.domain}/fullchain.pem /var/lib/acme/${vars.domain}/key.pem
          reverse_proxy http://127.0.0.1:${toString config.services.paperless.port}
        '';
      };

      "${vars.audiobooksDomain}" = {
        extraConfig = ''
          tls /var/lib/acme/${vars.domain}/fullchain.pem /var/lib/acme/${vars.domain}/key.pem
          reverse_proxy http://127.0.0.1:${toString config.services.audiobookshelf.port}
        '';
      };

      "${vars.filesDomain}" = {
        extraConfig = ''
          tls /var/lib/acme/${vars.domain}/fullchain.pem /var/lib/acme/${vars.domain}/key.pem
          @edge_http header X-Forwarded-Proto http
          redir @edge_http https://{host}{uri} 308
          @copyparty_shares path /shares /shares/*
          handle @copyparty_shares {
            reverse_proxy http://127.0.0.1:${toString config.services.copyparty.settings.p} {
              header_up X-Forwarded-Proto https
              header_up X-Forwarded-Host {host}
              header_up X-Forwarded-For {http.request.header.Cf-Connecting-Ip}
              header_up Cf-Connecting-Ip {http.request.header.Cf-Connecting-Ip}
            }
          }
          handle {
            reverse_proxy http://${config.services.oauth2-proxy.httpAddress} {
              header_up X-Forwarded-Proto https
              header_up X-Forwarded-Host {host}
              header_up X-Forwarded-For {http.request.header.Cf-Connecting-Ip}
              header_up Cf-Connecting-Ip {http.request.header.Cf-Connecting-Ip}
            }
          }
        '';
      };

      "${vars.emailsDomain}" = {
        extraConfig = ''
          tls /var/lib/acme/${vars.domain}/fullchain.pem /var/lib/acme/${vars.domain}/key.pem
          reverse_proxy http://127.0.0.1:${toString mailArchiveOauth2ProxyPort} {
            header_up X-Forwarded-Proto https
            header_up X-Forwarded-Host {host}
          }
        '';
      };

      "${vars.photosDomain}" = {
        extraConfig = ''
          tls /var/lib/acme/${vars.domain}/fullchain.pem /var/lib/acme/${vars.domain}/key.pem
          reverse_proxy http://127.0.0.1:${toString config.services.immich.port}
        '';
      };

      "${vars.kavitaDomain}" = {
        extraConfig = ''
          tls /var/lib/acme/${vars.domain}/fullchain.pem /var/lib/acme/${vars.domain}/key.pem
          reverse_proxy http://127.0.0.1:${toString config.services.kavita.settings.Port}
        '';
      };

      "${vars.jellyfinDomain}" = {
        extraConfig = ''
          tls /var/lib/acme/${vars.domain}/fullchain.pem /var/lib/acme/${vars.domain}/key.pem
          reverse_proxy http://127.0.0.1:${toString jellyfinPort} {
            header_up X-Forwarded-Proto https
          }
        '';
      };

      "${vars.jellyseerrDomain}" = {
        extraConfig = ''
          tls /var/lib/acme/${vars.domain}/fullchain.pem /var/lib/acme/${vars.domain}/key.pem
          reverse_proxy http://127.0.0.1:${toString config.services.jellyseerr.port}
        '';
      };
    };
  };

  systemd.services.caddy = {
    wants = [
      "acme-${vars.domain}.service"
      "acme-${vars.kanidmDomain}.service"
    ];
    after = [
      "acme-${vars.domain}.service"
      "acme-${vars.kanidmDomain}.service"
    ];
  };

  # NetBird is always allowed to reach the private HTTPS entrypoints. In
  # split-horizon mode, expose the same listener on the LAN so router-distributed
  # local DNS answers remain reachable.
  networking.firewall.interfaces =
    {
      ${vars.netbirdIface}.allowedTCPPorts = [ 443 ];
    }
    // lib.optionalAttrs vars.splitDnsMode {
      ${vars.netIface}.allowedTCPPorts = [ 443 ];
    };
}
