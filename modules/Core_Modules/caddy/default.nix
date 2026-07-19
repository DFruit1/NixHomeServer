{ config, lib, vars, ... }:

let
  loopback = vars.networking.loopbackIPv4;
  ports = vars.networking.ports;
  lanIface = vars.networking.interfaces.lan;
  netbirdIface = vars.networking.interfaces.netbird;
  splitDnsMode = vars.networking.dns.mode == "split-horizon";
  domainSuffix = ".${vars.domain}";
  lanDomain = vars.networking.dns.lanDomain;
  hasModule = name: config.nixhomeserver.modules.${name} or false;
  homepageEnabled = hasModule "homepage";
  kiwixEnabled = hasModule "kiwix" && (config.repo.kiwix.enable or false);
  portalHost = if homepageEnabled then "homepage.${vars.domain}" else vars.kanidmDomain;
  # Optional applications register their real virtual hosts in their own
  # modules. Only publish convenience aliases for applications that actually
  # contributed a runtime unit, so removing an app module cannot leave an
  # alias pointing at a non-existent virtual host.
  shortAliasLongHosts =
    [ vars.kopiaDomain ]
    ++ lib.optionals homepageEnabled [ "homepage.${vars.domain}" ]
    ++ lib.optionals (hasModule "immich") [
      "photos.${vars.domain}"
      "sharephotos.${vars.domain}"
    ]
    ++ lib.optionals (hasModule "files") [ "files.${vars.domain}" ]
    ++ lib.optionals (hasModule "paperless") [ "paperless.${vars.domain}" ]
    ++ lib.optionals (hasModule "audiobookshelf") [ "audiobooks.${vars.domain}" ]
    ++ lib.optionals (hasModule "jellyfin") [ "videos.${vars.domain}" ]
    ++ lib.optionals (hasModule "kavita") [ "books.${vars.domain}" ]
    ++ lib.optionals kiwixEnabled [ "wiki.${vars.domain}" ]
    ++ lib.optionals (hasModule "vaultwarden") [ "passwords.${vars.domain}" ]
    ++ lib.optionals (hasModule "mail-archive-ui") [ "emails.${vars.domain}" ]
    ++ lib.optionals (hasModule "youtube-downloader") [ "ytdownload.${vars.domain}" ]
    ++ lib.optionals (hasModule "sonarr" && (config.repo.sonarr.enable or false)) [ "sonarr.${vars.domain}" ]
    ++ lib.optionals (hasModule "radarr" && (config.repo.radarr.enable or false)) [ "radarr.${vars.domain}" ]
    ++ lib.optionals (hasModule "prowlarr" && (config.repo.prowlarr.enable or false)) [ "prowlarr.${vars.domain}" ]
    ++ lib.optionals (hasModule "qbittorrent" && (config.repo.qbittorrent.enable or false)) [ "torrents.${vars.domain}" ]
    ++ lib.optionals (hasModule "offline-music" && (vars.offlineMedia.enable or false)) [ "syncthing.${vars.domain}" ]
    ++ lib.optionals (hasModule "seerr" && (config.repo.seerr.enable or false)) [ "requests.${vars.domain}" ]
    ++ lib.optionals (hasModule "groundwater-logger" && (config.repo.groundwaterLogger.enable or false)) [ "groundwater.${vars.domain}" ];
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
          redir https://${portalHost}{uri} 308
        '';
      };

      "www.${vars.domain}" = {
        logFormat = null;
        useACMEHost = vars.domain;
        extraConfig = ''
          ${accessLogConfig}
          redir https://${portalHost}{uri} 308
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
