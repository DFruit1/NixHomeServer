{ lib, vars, ... }:

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
  imports = [
    ./bootstrap.nix
    ./acme.nix
  ];

  services.caddy = {
    enable = true;
    email = vars.kanidmAdminEmail;
    virtualHosts = {
      "${vars.domain}" = {
        useACMEHost = vars.domain;
        extraConfig = ''
          ${accessLogConfig}
          redir https://homepage.${vars.domain}{uri} 308
        '';
      };

      "www.${vars.domain}" = {
        useACMEHost = vars.domain;
        extraConfig = ''
          ${accessLogConfig}
          redir https://homepage.${vars.domain}{uri} 308
        '';
      };

      "${vars.kanidmDomain}" = {
        useACMEHost = vars.kanidmDomain;
        extraConfig = ''
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
    };
  };

  networking.firewall.interfaces.${netbirdIface}.allowedTCPPorts = [
    ports.http
    ports.https
  ];
  networking.firewall.interfaces.${lanIface}.allowedTCPPorts = lib.mkIf splitDnsMode [
    ports.http
    ports.https
  ];

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
