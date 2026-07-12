{ config, lib, vars, ... }:

let
  loopback = vars.networking.loopbackIPv4;
  ports = vars.networking.ports;
  lanIface = vars.networking.interfaces.lan;
  netbirdIface = vars.networking.interfaces.netbird;
  splitDnsMode = vars.networking.dns.mode == "split-horizon";
  domainSuffix = ".${vars.domain}";
  lanDomain = vars.networking.dns.lanDomain;
  shortAliasLongHosts = [
    "homepage.${vars.domain}"
    "photos.${vars.domain}"
    "sharephotos.${vars.domain}"
    "files.${vars.domain}"
    "paperless.${vars.domain}"
    "audiobooks.${vars.domain}"
    "videos.${vars.domain}"
    "books.${vars.domain}"
    "wiki.${vars.domain}"
    "passwords.${vars.domain}"
    "emails.${vars.domain}"
    "ytdownload.${vars.domain}"
    "sonarr.${vars.domain}"
    "radarr.${vars.domain}"
    "prowlarr.${vars.domain}"
    "torrents.${vars.domain}"
    "syncthing.${vars.domain}"
    vars.kopiaDomain
  ] ++ lib.optionals (config.repo.seerr.enable or false) [
    "requests.${vars.domain}"
  ] ++ lib.optionals (config.repo.groundwaterLogger.enable or false) [
    "groundwater.${vars.domain}"
  ];
  shortAliasCaddyHosts = lib.listToAttrs (
    map
      (hostName:
        let
          shortHost = lib.removeSuffix domainSuffix hostName;
          httpAlias = "http://${shortHost}";
        in
        {
          name = httpAlias;
          value = {
            logFormat = null;
            extraConfig = ''
              redir https://${hostName}{uri} 308
            '';
          };
        }
      )
      shortAliasLongHosts
  );
  shortAliasPrivateHosts = lib.listToAttrs (
    map
      (hostName:
        {
          name = lib.removeSuffix domainSuffix hostName;
          value = {
            target = "private";
          };
        }
      )
      shortAliasLongHosts
  );
  shortAliasLanCaddyHosts = lib.listToAttrs (
    map
      (hostName:
        let
          shortHost = lib.removeSuffix domainSuffix hostName;
        in
        {
          name = "http://${shortHost}.${lanDomain}";
          value = {
            logFormat = null;
            extraConfig = ''
              redir https://${hostName}{uri} 308
            '';
          };
        }
      )
      shortAliasLongHosts
  );
  shortAliasLanPrivateHosts = lib.listToAttrs (
    map
      (hostName:
        let
          shortHost = lib.removeSuffix domainSuffix hostName;
        in
        {
          name = "${shortHost}.${lanDomain}";
          value = {
            target = "private";
          };
        }
      )
      shortAliasLongHosts
  );
  accessLogConfig = ''
    log {
      output file /var/log/caddy/access.log {
        mode 0640
        roll_size 25MiB
        roll_keep 5
        roll_keep_for 720h
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
        logFormat = null;
        useACMEHost = vars.domain;
        extraConfig = ''
          ${accessLogConfig}
          redir https://homepage.${vars.domain}{uri} 308
        '';
      };

      "www.${vars.domain}" = {
        logFormat = null;
        useACMEHost = vars.domain;
        extraConfig = ''
          ${accessLogConfig}
          redir https://homepage.${vars.domain}{uri} 308
        '';
      };

      "${vars.kanidmDomain}" = {
        logFormat = null;
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
          }
        '';
      };
    } // shortAliasCaddyHosts // shortAliasLanCaddyHosts;
  };
  services.unbound.privateHosts = shortAliasPrivateHosts // shortAliasLanPrivateHosts;

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
