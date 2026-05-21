{ lib, vars, config, ... }:

let
  cfg = config.repo.networking;
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
  tlsConfig = certificate:
    if certificate == "kanidm" then
      "tls /var/lib/acme/${vars.kanidmDomain}/fullchain.pem /var/lib/acme/${vars.kanidmDomain}/key.pem"
    else if certificate == "wildcard" then
      "tls /var/lib/acme/${vars.domain}/fullchain.pem /var/lib/acme/${vars.domain}/key.pem"
    else
      "";
  mkVirtualHost = _: host: {
    extraConfig = ''
      ${tlsConfig host.certificate}
      ${lib.optionalString host.accessLog accessLogConfig}
      ${host.extraConfig}
    '';
  };
in
{
  repo.networking = {
    ports.https = {
      port = ports.https;
      protocol = "tcp";
      bind = "public";
      owner = "core";
      externallyBound = true;
    };

    caddy.virtualHosts = {
      "${vars.domain}" = {
        owner = "core";
        certificate = "wildcard";
        allowExternal = true;
        extraConfig = ''
          redir https://${vars.kanidmDomain}{uri} 308
        '';
      };

      "www.${vars.domain}" = {
        owner = "core";
        certificate = "wildcard";
        allowExternal = true;
        extraConfig = ''
          redir https://${vars.kanidmDomain}{uri} 308
        '';
      };

      "${vars.kanidmDomain}" = {
        owner = "core";
        certificate = "kanidm";
        extraConfig = ''
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
    };

    firewall.interfacePorts =
      [
        {
          owner = "core-caddy";
          interface = netbirdIface;
          protocol = "tcp";
          port = ports.https;
        }
      ]
      ++ lib.optional splitDnsMode {
        owner = "core-caddy";
        interface = lanIface;
        protocol = "tcp";
        port = ports.https;
      };
  };

  services.caddy = {
    enable = true;
    email = vars.kanidmAdminEmail;
    virtualHosts = lib.mapAttrs mkVirtualHost cfg.caddy.virtualHosts;
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
}
