{ lib, vars, config, ... }:

let
  loopback = vars.networking.loopbackIPv4;
  ports = vars.networking.ports;
  lanIface = vars.networking.interfaces.lan;
  netbirdIface = vars.networking.interfaces.netbird;
  splitDnsMode = vars.networking.dns.mode == "split-horizon";
  accessLogConfig = ''
    log {
      output file /var/log/caddy/access.log {
        mode 0640
      }
      format json
    }
  '';
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
          ${accessLogConfig}
          redir https://${vars.kanidmDomain}{uri} 308
        '';
      };

      "www.${vars.domain}" = {
        extraConfig = ''
          tls /var/lib/acme/${vars.domain}/fullchain.pem /var/lib/acme/${vars.domain}/key.pem
          ${accessLogConfig}
          redir https://${vars.kanidmDomain}{uri} 308
        '';
      };

      "${vars.kanidmDomain}" = {
        extraConfig = ''
          tls /var/lib/acme/${vars.kanidmDomain}/fullchain.pem /var/lib/acme/${vars.kanidmDomain}/key.pem
          ${accessLogConfig}
          @edge_http header X-Forwarded-Proto http
          redir @edge_http https://{host}{uri} 308
          reverse_proxy https://${loopback}:${toString ports.kanidm} {
            transport http {
              tls_server_name ${vars.kanidmDomain}
              tls_trust_pool file /var/lib/acme/${vars.kanidmDomain}/fullchain.pem
            }
            header_up X-Forwarded-Proto https
            header_up X-Forwarded-Host  {host}
          }
        '';
      };

      "${vars.paperlessDomain}" = {
        extraConfig = ''
          tls /var/lib/acme/${vars.domain}/fullchain.pem /var/lib/acme/${vars.domain}/key.pem
          ${accessLogConfig}
          reverse_proxy http://${loopback}:${toString config.services.paperless.port}
        '';
      };

      "${vars.audiobooksDomain}" = {
        extraConfig = ''
          tls /var/lib/acme/${vars.domain}/fullchain.pem /var/lib/acme/${vars.domain}/key.pem
          ${accessLogConfig}
          reverse_proxy http://${loopback}:${toString config.services.audiobookshelf.port}
        '';
      };

      "${vars.uploadsDomain}" = {
        extraConfig = ''
          tls /var/lib/acme/${vars.domain}/fullchain.pem /var/lib/acme/${vars.domain}/key.pem
          ${accessLogConfig}
          @edge_http header X-Forwarded-Proto http
          redir @edge_http https://{host}{uri} 308
          reverse_proxy http://${config.services.oauth2-proxy.httpAddress} {
            header_up X-Forwarded-Proto https
            header_up X-Forwarded-Host {host}
            header_up X-Forwarded-For {http.request.header.Cf-Connecting-Ip}
            header_up Cf-Connecting-Ip {http.request.header.Cf-Connecting-Ip}
          }
        '';
      };

      "${vars.filebrowserDomain}" = {
        extraConfig = ''
          tls /var/lib/acme/${vars.domain}/fullchain.pem /var/lib/acme/${vars.domain}/key.pem
          ${accessLogConfig}
          redir /login /api/auth/oidc/login{?query} temporary
          reverse_proxy http://${loopback}:${toString ports.filebrowserQuantum} {
            header_up X-Forwarded-Proto https
            header_up X-Forwarded-Host {host}
          }
        '';
      };

      "${vars.emailsDomain}" = {
        extraConfig = ''
          tls /var/lib/acme/${vars.domain}/fullchain.pem /var/lib/acme/${vars.domain}/key.pem
          ${accessLogConfig}
          reverse_proxy http://${loopback}:${toString ports.oauth2ProxyMailArchive} {
            header_up X-Forwarded-Proto https
            header_up X-Forwarded-Host {host}
          }
        '';
      };

      "${vars.vaultwardenDomain}" = {
        extraConfig = ''
          tls /var/lib/acme/${vars.domain}/fullchain.pem /var/lib/acme/${vars.domain}/key.pem
          ${accessLogConfig}
          reverse_proxy http://${loopback}:${toString ports.vaultwarden} {
            header_up X-Forwarded-Proto https
            header_up X-Forwarded-Host {host}
          }
        '';
      };

      "${vars.kiwixDomain}" = {
        extraConfig = ''
          tls /var/lib/acme/${vars.domain}/fullchain.pem /var/lib/acme/${vars.domain}/key.pem
          ${accessLogConfig}
          reverse_proxy http://${loopback}:${toString ports.oauth2ProxyKiwix} {
            header_up X-Forwarded-Proto https
            header_up X-Forwarded-Host {host}
          }
        '';
      };

      "${vars.metubeDomain}" = {
        extraConfig = ''
          tls /var/lib/acme/${vars.domain}/fullchain.pem /var/lib/acme/${vars.domain}/key.pem
          ${accessLogConfig}
          reverse_proxy http://${loopback}:${toString ports.oauth2ProxyMetube} {
            header_up X-Forwarded-Proto https
            header_up X-Forwarded-Host {host}
          }
        '';
      };

      "${vars.monitorDomain}" = {
        extraConfig = ''
          tls /var/lib/acme/${vars.domain}/fullchain.pem /var/lib/acme/${vars.domain}/key.pem
          ${accessLogConfig}
          reverse_proxy http://${loopback}:${toString ports.oauth2ProxyGlances} {
            header_up X-Forwarded-Proto https
            header_up X-Forwarded-Host {host}
          }
        '';
      };

      "${vars.photosDomain}" = {
        extraConfig = ''
          tls /var/lib/acme/${vars.domain}/fullchain.pem /var/lib/acme/${vars.domain}/key.pem
          ${accessLogConfig}
          reverse_proxy http://${loopback}:${toString config.services.immich.port}
        '';
      };

      "${vars.sharePhotosDomain}" = {
        extraConfig = ''
          tls /var/lib/acme/${vars.domain}/fullchain.pem /var/lib/acme/${vars.domain}/key.pem
          ${accessLogConfig}
          reverse_proxy http://${loopback}:${toString ports.immichPublicProxy} {
            header_up X-Forwarded-Proto https
            header_up X-Forwarded-Host {host}
          }
        '';
      };

      "${vars.kavitaDomain}" = {
        extraConfig = ''
          tls /var/lib/acme/${vars.domain}/fullchain.pem /var/lib/acme/${vars.domain}/key.pem
          ${accessLogConfig}
          reverse_proxy http://${loopback}:${toString config.services.kavita.settings.Port}
        '';
      };

      "${vars.jellyfinDomain}" = {
        extraConfig = ''
          tls /var/lib/acme/${vars.domain}/fullchain.pem /var/lib/acme/${vars.domain}/key.pem
          ${accessLogConfig}
          reverse_proxy http://${loopback}:${toString ports.jellyfin} {
            header_up X-Forwarded-Proto https
          }
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
      ${netbirdIface}.allowedTCPPorts = [ ports.https ];
    }
    // lib.optionalAttrs splitDnsMode {
      ${lanIface}.allowedTCPPorts = [ ports.https ];
    };
}
