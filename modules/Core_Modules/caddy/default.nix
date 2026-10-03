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
  mailArchiveEnabled =
    hasModule "mail-archive-ui"
    && (config.services.mail-archive-ui.enable or false);
  homepageHost = "homepage.${vars.domain}";
  homepageLandingUrl = "https://${homepageHost}";
  fallbackLandingUrl = "https://${vars.kanidmDomain}/ui/apps";
  rootLandingConfig =
    if homepageEnabled then
      ''
        ${accessLogConfig}
        handle_errors {
          redir ${fallbackLandingUrl} 302
        }
        reverse_proxy http://${loopback}:${toString ports.homepage} {
          method GET
          rewrite /healthz
          @healthy status 200
          handle_response @healthy {
            redir ${homepageLandingUrl}{uri} 302
          }
          handle_response {
            redir ${fallbackLandingUrl} 302
          }
        }
      ''
    else
      ''
        ${accessLogConfig}
        redir ${fallbackLandingUrl} 302
      '';
  # Optional applications register their real virtual hosts in their own
  # modules. Only publish convenience aliases for applications that actually
  # contributed a runtime unit, so removing an app module cannot leave an
  # alias pointing at a non-existent virtual host.
  shortAliasLongHosts =
    [ vars.kopiaDomain ]
    ++ lib.optionals homepageEnabled [ homepageHost ]
    ++ lib.optionals (hasModule "immich") [
      "photos.${vars.domain}"
      "sharephotos.${vars.domain}"
    ]
    ++ lib.optionals (hasModule "files") [ "files.${vars.domain}" ]
    ++ lib.optionals (hasModule "forgejo" && (config.repo.forgejo.enable or false)) [ "git.${vars.domain}" ]
    ++ lib.optionals (hasModule "paperless") [ "paperless.${vars.domain}" ]
    ++ lib.optionals (hasModule "audiobookshelf") [ "audiobooks.${vars.domain}" ]
    ++ lib.optionals (hasModule "jellyfin") [ "videos.${vars.domain}" ]
    ++ lib.optionals (hasModule "kavita") [ "books.${vars.domain}" ]
    ++ lib.optionals kiwixEnabled [ "wiki.${vars.domain}" ]
    ++ lib.optionals (hasModule "vaultwarden") [ "passwords.${vars.domain}" ]
    ++ lib.optionals mailArchiveEnabled [ "emails.${vars.domain}" ]
    ++ lib.optionals (hasModule "youtube-downloader") [ "ytdownload.${vars.domain}" ]
    ++ lib.optionals (hasModule "sonarr" && (config.repo.sonarr.enable or false)) [ "sonarr.${vars.domain}" ]
    ++ lib.optionals (hasModule "radarr" && (config.repo.radarr.enable or false)) [ "radarr.${vars.domain}" ]
    ++ lib.optionals (hasModule "prowlarr" && (config.repo.prowlarr.enable or false)) [ "prowlarr.${vars.domain}" ]
    ++ lib.optionals (hasModule "qbittorrent" && (config.repo.qbittorrent.enable or false)) [ "torrents.${vars.domain}" ]
    ++ lib.optionals (hasModule "offline-music" && (vars.offlineMedia.enable or false)) [ "syncthing.${vars.domain}" ]
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
  edgeProtectionCfg = config.repo.caddy.edgeProtection;
in
{
  imports = [
    ./bootstrap.nix
    ./acme.nix
  ];

  options.repo.caddy.edgeProtection = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Bound the resources a single inbound connection stream can occupy in
        Caddy. These are stock Caddyfile directives (no plugins) and they are
        per-connection and per-upstream, not per-client-identity: no
        client_ip_headers or trusted_proxies are configured, so nothing here
        keys on a client-supplied X-Forwarded-For or CF-Connecting-IP value.
      '';
    };

    readHeaderTimeout = lib.mkOption {
      type = lib.types.str;
      default = "10s";
      description = ''
        How long a client may take to finish sending request headers. Bounds
        the classic slowloris connection-exhaustion pattern at the cheapest
        possible point, before any request body or upstream work begins.
      '';
    };

    idleTimeout = lib.mkOption {
      type = lib.types.str;
      default = "2m";
      description = ''
        How long a keepalive connection may sit idle between requests before
        Caddy closes it, so idle connections cannot be parked indefinitely.
      '';
    };

    maxHeaderSize = lib.mkOption {
      type = lib.types.str;
      default = "16KiB";
      description = ''
        Maximum accepted request-header size. Oversized headers are rejected
        rather than buffered.
      '';
    };

    maxRequestBodySize = lib.mkOption {
      type = lib.types.str;
      default = "2MB";
      description = ''
        Maximum request body Caddy will buffer on the identity vhost. Far
        above anything the Kanidm web UI posts, and a hard ceiling for a
        flood of large-body uploads.
      '';
    };

    upstreamMaxConnsPerHost = lib.mkOption {
      type = lib.types.int;
      default = 512;
      description = ''
        Maximum simultaneous connections Caddy opens to the identity backend.
        This is the containment point for a request flood: excess requests
        queue or fail against the upstream pool instead of opening unbounded
        backend connections.
      '';
    };

    upstreamIdleConnsPerHost = lib.mkOption {
      type = lib.types.int;
      default = 64;
      description = ''
        Idle keepalive connections Caddy retains to the identity backend, so
        a burst cannot force a fresh backend TLS handshake per request.
      '';
    };
  };

  config.services.caddy = {
    enable = true;
    email = vars.kanidmAdminEmail;

    # Appended after upstream's global block (email/http_port/log) so the
    # per-server resource bounds land inside the same Caddyfile global scope.
    globalConfig = lib.mkIf edgeProtectionCfg.enable ''
      servers {
        timeouts {
          read_header ${edgeProtectionCfg.readHeaderTimeout}
          idle ${edgeProtectionCfg.idleTimeout}
        }
        max_header_size ${edgeProtectionCfg.maxHeaderSize}
      }
    '';
    virtualHosts = {
      "${vars.domain}" = {
        logFormat = null;
        useACMEHost = vars.domain;
        extraConfig = rootLandingConfig;
      };

      "www.${vars.domain}" = {
        logFormat = null;
        useACMEHost = vars.domain;
        extraConfig = rootLandingConfig;
      };

      "${vars.kanidmDomain}" = {
        logFormat = null;
        useACMEHost = vars.kanidmDomain;
        extraConfig = ''
          ${accessLogConfig}
          encode zstd gzip
          @edge_http header X-Forwarded-Proto http
          redir @edge_http https://{host}{uri} 308
          @kanidm_override_css path /pkg/override.css
          header @kanidm_override_css {
            Cache-Control "no-store, max-age=0"
            Pragma "no-cache"
            Expires "0"
          }
          ${lib.optionalString edgeProtectionCfg.enable ''
            request_body {
              max_size ${edgeProtectionCfg.maxRequestBodySize}
            }
          ''}
          reverse_proxy https://${loopback}:${toString ports.kanidm} {
            transport http {
              tls_server_name ${vars.kanidmDomain}
              tls_trust_pool file /var/lib/acme/${vars.kanidmDomain}/fullchain.pem
              ${lib.optionalString edgeProtectionCfg.enable ''
                max_conns_per_host ${toString edgeProtectionCfg.upstreamMaxConnsPerHost}
                keepalive_idle_conns_per_host ${toString edgeProtectionCfg.upstreamIdleConnsPerHost}
              ''}
            }
            header_up X-Forwarded-Proto https
          }
        '';
      };
    } // shortAliasCaddyHosts // shortAliasLanCaddyHosts;
  };

  config = {
    assertions = [
      {
        # Caddy accepts zero and negative counts silently, which would turn
        # these bounds off rather than fail. Catch it in evaluation instead.
        assertion =
          !edgeProtectionCfg.enable
          || (
            edgeProtectionCfg.upstreamMaxConnsPerHost > 0
            && edgeProtectionCfg.upstreamIdleConnsPerHost > 0
          );
        message = "repo.caddy.edgeProtection.upstreamMaxConnsPerHost and upstreamIdleConnsPerHost must be greater than zero when edge protection is enabled.";
      }
      {
        assertion =
          !edgeProtectionCfg.enable
          || (
            lib.hasInfix "KiB" edgeProtectionCfg.maxHeaderSize
            || lib.hasInfix "MiB" edgeProtectionCfg.maxHeaderSize
            || lib.hasInfix "B" edgeProtectionCfg.maxHeaderSize
          );
        message = "repo.caddy.edgeProtection.maxHeaderSize must be a Caddy byte size such as 16KiB, not a bare number; Caddy would reject it at service start rather than at evaluation.";
      }
    ];

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
  };
}
