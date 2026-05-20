{ lib, vars, config, ... }:

let
  loopback = vars.networking.loopbackIPv4;
  ports = vars.networking.ports;
  apps = config.nixhomeserver.apps;
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

      "${vars.paperlessDomain}" = lib.mkIf apps.paperless.enable {
        extraConfig = ''
          tls /var/lib/acme/${vars.domain}/fullchain.pem /var/lib/acme/${vars.domain}/key.pem
          ${accessLogConfig}
          reverse_proxy http://${loopback}:${toString config.services.paperless.port}
        '';
      };

      "${vars.audiobooksDomain}" = lib.mkIf apps.audiobookshelf.enable {
        extraConfig = ''
          tls /var/lib/acme/${vars.domain}/fullchain.pem /var/lib/acme/${vars.domain}/key.pem
          ${accessLogConfig}
          reverse_proxy http://${loopback}:${toString config.services.audiobookshelf.port}
        '';
      };

      "${vars.uploadsDomain}" = lib.mkIf apps.copyparty.enable {
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

      "${vars.filebrowserDomain}" = lib.mkIf apps."filebrowser-quantum".enable {
        extraConfig = ''
          tls /var/lib/acme/${vars.domain}/fullchain.pem /var/lib/acme/${vars.domain}/key.pem
          ${accessLogConfig}
          redir /login /api/auth/oidc/login{?query} temporary
          @download_html_svg path *.html *.svg
          header @download_html_svg Content-Disposition attachment
          header @download_html_svg X-Content-Type-Options nosniff
          reverse_proxy http://${loopback}:${toString ports.filebrowserQuantum} {
            header_up X-Forwarded-Proto https
            header_up X-Forwarded-Host {host}
          }
        '';
      };

      "${vars.filestashDomain}" = lib.mkIf apps.filestash.enable {
        extraConfig = ''
          tls /var/lib/acme/${vars.domain}/fullchain.pem /var/lib/acme/${vars.domain}/key.pem
          ${accessLogConfig}
          @download_html_svg path *.html *.svg
          header @download_html_svg Content-Disposition attachment
          header @download_html_svg X-Content-Type-Options nosniff
          reverse_proxy http://${loopback}:${toString ports.oauth2ProxyFilestash} {
            header_up X-Forwarded-Proto https
            header_up X-Forwarded-Host {host}
          }
        '';
      };

      "${vars.emailsDomain}" = lib.mkIf apps."mail-archive-ui".enable {
        extraConfig = ''
          tls /var/lib/acme/${vars.domain}/fullchain.pem /var/lib/acme/${vars.domain}/key.pem
          ${accessLogConfig}
          reverse_proxy http://${loopback}:${toString ports.oauth2ProxyMailArchive} {
            header_up X-Forwarded-Proto https
            header_up X-Forwarded-Host {host}
          }
        '';
      };

      "${vars.vaultwardenDomain}" = lib.mkIf apps.vaultwarden.enable {
        extraConfig = ''
          tls /var/lib/acme/${vars.domain}/fullchain.pem /var/lib/acme/${vars.domain}/key.pem
          ${accessLogConfig}
          reverse_proxy http://${loopback}:${toString ports.vaultwarden} {
            header_up X-Forwarded-Proto https
            header_up X-Forwarded-Host {host}
          }
        '';
      };

      "${vars.kiwixDomain}" = lib.mkIf apps.kiwix.enable {
        extraConfig = ''
          tls /var/lib/acme/${vars.domain}/fullchain.pem /var/lib/acme/${vars.domain}/key.pem
          ${accessLogConfig}
          reverse_proxy http://${loopback}:${toString ports.oauth2ProxyKiwix} {
            header_up X-Forwarded-Proto https
            header_up X-Forwarded-Host {host}
          }
        '';
      };

      "${vars.metubeDomain}" = lib.mkIf apps.metube.enable {
        extraConfig = ''
          tls /var/lib/acme/${vars.domain}/fullchain.pem /var/lib/acme/${vars.domain}/key.pem
          ${accessLogConfig}
          reverse_proxy http://${loopback}:${toString ports.oauth2ProxyMetube} {
            header_up X-Forwarded-Proto https
            header_up X-Forwarded-Host {host}
          }
        '';
      };

      "${vars.photosDomain}" = lib.mkIf apps.immich.enable {
        extraConfig = ''
          tls /var/lib/acme/${vars.domain}/fullchain.pem /var/lib/acme/${vars.domain}/key.pem
          ${accessLogConfig}
          reverse_proxy http://${loopback}:${toString config.services.immich.port}
        '';
      };

      "${vars.sharePhotosDomain}" = lib.mkIf apps.immich.enable {
        extraConfig = ''
          tls /var/lib/acme/${vars.domain}/fullchain.pem /var/lib/acme/${vars.domain}/key.pem
          ${accessLogConfig}
          reverse_proxy http://${loopback}:${toString ports.immichPublicProxy} {
            header_up X-Forwarded-Proto https
            header_up X-Forwarded-Host {host}
          }
        '';
      };

      "${vars.kavitaDomain}" = lib.mkIf apps.kavita.enable {
        extraConfig = ''
          tls /var/lib/acme/${vars.domain}/fullchain.pem /var/lib/acme/${vars.domain}/key.pem
          ${accessLogConfig}
          reverse_proxy http://${loopback}:${toString config.services.kavita.settings.Port}
        '';
      };

      "${vars.jellyfinDomain}" = lib.mkIf apps.jellyfin.enable {
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
