{ config, lib, pkgs, vars, ... }:

let
  cfg = config.repo.authGateway;
  loopback = vars.networking.loopbackIPv4;
  kopiaPort = vars.networking.ports.kopia;
  # Invalid user input is rejected by Core_Modules/validation.  Avoid doing
  # arithmetic on it first, which would hide that diagnostic behind a Nix
  # type error.
  kopiaAuthProxyPort = if builtins.isInt kopiaPort then kopiaPort + 1 else -1;
  authHost = cfg.domain;
  hasModule = name: config.nixhomeserver.modules.${name} or false;
  homepageEnabled = hasModule "homepage";
  moduleEnabled = name:
    hasModule name
    && (config.repo.${name}.enable or true);
  mailArchiveEnabled =
    hasModule "mail-archive-ui"
    && config.services.mail-archive-ui.enable;
  sidecarServices = [
    "kopia-oauth2-proxy"
  ]
  ++ lib.optionals (hasModule "beszel") [ "monitor-oauth2-proxy" ]
  ++ lib.optionals (hasModule "files") [ "filestash-oauth2-proxy" ]
  ++ lib.optionals homepageEnabled [ "homepage-oauth2-proxy" ]
  ++ lib.optionals (moduleEnabled "kiwix") [ "kiwix-oauth2-proxy" ]
  ++ lib.optionals mailArchiveEnabled [ "mail-archive-oauth2-proxy" ]
  ++ lib.optionals (moduleEnabled "prowlarr") [ "prowlarr-oauth2-proxy" ]
  ++ lib.optionals (moduleEnabled "qbittorrent") [ "qbittorrent-oauth2-proxy" ]
  ++ lib.optionals (moduleEnabled "radarr") [ "radarr-oauth2-proxy" ]
  ++ lib.optionals (moduleEnabled "sonarr") [ "sonarr-oauth2-proxy" ]
  ++ lib.optionals (hasModule "youtube-downloader") [ "youtube-downloader-oauth2-proxy" ]
  ++ lib.optionals (moduleEnabled "browsertrix-downloader") [ "browsertrix-downloader-oauth2-proxy" ]
  ++ lib.optionals (moduleEnabled "seerr") [ "seerr-oauth2-proxy" ];
  sidecarUnits = map (name: "${name}.service") sidecarServices;
  mkApp = host: upstream: allowedGroups: {
    inherit host upstream allowedGroups;
  };
  homepageAccessGroups = lib.unique [
    "users"
    vars.fileAccess.webAccessGroup
    vars.fileAccess.sftpAccessGroup
    vars.fileAccess.sharedAccessGroup
    vars.fileAccess.usbAccessGroup
    vars.backupStorageGroup
  ];
  defaultApps = {
    kopia = mkApp vars.kopiaDomain "http://${loopback}:${toString kopiaAuthProxyPort}" [ vars.backupAdminGroup ];
  }
  // lib.optionalAttrs homepageEnabled {
    homepage = mkApp "homepage.${vars.domain}" "http://${loopback}:${toString vars.networking.ports.homepage}" homepageAccessGroups;
  }
  // lib.optionalAttrs (hasModule "files") {
    files = (mkApp "files.${vars.domain}" "http://${loopback}:${toString vars.networking.ports.filestash}" [
      vars.fileAccess.webAccessGroup
    ]) // {
      skipAuthPreflight = true;
    };
  }
  // lib.optionalAttrs mailArchiveEnabled {
    mail = mkApp "emails.${vars.domain}" "http://${loopback}:${toString vars.networking.ports.mailArchiveUi}" [ "mail-archive-users" ];
  }
  // lib.optionalAttrs (moduleEnabled "kiwix") {
    kiwix = mkApp "wiki.${vars.domain}" "http://${loopback}:${toString vars.networking.ports.kiwix}" [ "kiwix-users" ];
  }
  // lib.optionalAttrs (hasModule "youtube-downloader") {
    downloads = mkApp "ytdownload.${vars.domain}" "http://${loopback}:${toString vars.networking.ports.youtubeDownloader}" [ "downloads-users" ];
  }
  // lib.optionalAttrs (moduleEnabled "browsertrix-downloader") {
    browsertrix = mkApp "archives.${vars.domain}" "http://${loopback}:${toString vars.networking.ports.browsertrixDownloader}" [ "web-archive-users" ];
  }
  // lib.optionalAttrs (moduleEnabled "sonarr") {
    sonarr = mkApp "sonarr.${vars.domain}" "http://${loopback}:${toString vars.networking.ports.sonarr}" [ "media-automation-users" ];
  }
  // lib.optionalAttrs (moduleEnabled "radarr") {
    radarr = mkApp "radarr.${vars.domain}" "http://${loopback}:${toString vars.networking.ports.radarr}" [ "media-automation-users" ];
  }
  // lib.optionalAttrs (moduleEnabled "prowlarr") {
    prowlarr = mkApp "prowlarr.${vars.domain}" "http://${loopback}:${toString vars.networking.ports.prowlarr}" [ "media-automation-users" ];
  }
  // lib.optionalAttrs (moduleEnabled "qbittorrent") {
    qbittorrent = mkApp "torrents.${vars.domain}" "http://${loopback}:${toString vars.networking.ports.qbittorrentWeb}" [ "media-automation-users" ];
  }
  // lib.optionalAttrs (moduleEnabled "seerr") {
    seerr = mkApp "requests.${vars.domain}" "http://${loopback}:${toString vars.networking.ports.seerr}" [ "media-automation-users" ];
  };
  upstreamTransport = app: lib.optionalString (app.upstream != null && app.upstreamTimeout != null) ''
    transport http {
      response_header_timeout ${app.upstreamTimeout}
    }
  '';
  matcherName = name: lib.replaceStrings [ "-" "." ] [ "_" "_" ] name;
  mkRouterBlock = name: app:
    let
      matcher = matcherName name;
      groups = lib.concatStringsSep "|" (map lib.escapeRegex app.allowedGroups);
      authenticatedRouteBlocks = lib.concatStringsSep "\n" (lib.imap0
        (index: route: ''
          @route_${matcher}_${toString index} path ${route.pathPrefix} ${route.pathPrefix}/*
          handle @route_${matcher}_${toString index} {
            reverse_proxy ${route.upstream} {
              ${upstreamTransport app}
              header_up -X-Auth-Request-User
              header_up -X-Auth-Request-Email
              header_up -X-Auth-Request-Groups
              header_up -X-Auth-Request-Preferred-Username
              header_up X-Forwarded-Proto https
              header_up X-Forwarded-Host {http.request.header.X-Forwarded-Host}
              header_up X-Forwarded-User {http.request.header.X-Forwarded-User}
              header_up X-Forwarded-Email {http.request.header.X-Forwarded-Email}
              header_up X-Forwarded-Groups {http.request.header.X-Forwarded-Groups}
              header_up X-Forwarded-Preferred-Username {http.request.header.X-Forwarded-Preferred-Username}
            }
          }
        '')
        app.authenticatedRoutes);
    in
    ''
      @host_${matcher} header X-Forwarded-Host ${app.host}
      handle @host_${matcher} {
        @denied_${matcher} not header_regexp X-Forwarded-Groups "(?i)(^|,)[[:space:]]*(${groups})[[:space:]]*(,|$)"
        respond @denied_${matcher} "Forbidden" 403
        ${authenticatedRouteBlocks}
        handle {
          reverse_proxy ${app.upstream} {
            ${upstreamTransport app}
            header_up -X-Auth-Request-User
            header_up -X-Auth-Request-Email
            header_up -X-Auth-Request-Groups
            header_up -X-Auth-Request-Preferred-Username
            header_up X-Forwarded-Proto https
            header_up X-Forwarded-Host {http.request.header.X-Forwarded-Host}
            header_up X-Forwarded-User {http.request.header.X-Forwarded-User}
            header_up X-Forwarded-Email {http.request.header.X-Forwarded-Email}
            header_up X-Forwarded-Groups {http.request.header.X-Forwarded-Groups}
            header_up X-Forwarded-Preferred-Username {http.request.header.X-Forwarded-Preferred-Username}
          }
        }
      }
    '';
  routerApps = lib.filterAttrs (_: app: app.upstream != null) cfg.protectedApps;
  routerCaddyfile = pkgs.writeText "auth-gateway-router.Caddyfile" ''
    {
      admin off
      auto_https off
    }
    http://:${toString cfg.internalPort} {
      bind ${loopback}
      ${lib.concatStringsSep "\n" (lib.mapAttrsToList mkRouterBlock routerApps)}
      respond "Unknown protected application" 404
    }
  '';
  prepareCookieSecret = pkgs.writeShellScript "auth-gateway-cookie-secret" ''
    set -euo pipefail
    ${pkgs.openssl}/bin/openssl dgst -sha256 -binary \
      ${lib.escapeShellArg config.age.secrets.oauth2ProxyCookieSecret.path} \
      > /run/auth-gateway/cookie-secret
    chmod 0400 /run/auth-gateway/cookie-secret
  '';
  prepareClientSecret = pkgs.writeShellScript "auth-gateway-client-secret" ''
    set -euo pipefail
    ${pkgs.coreutils}/bin/tr -d '\r\n' \
      < ${lib.escapeShellArg config.age.secrets.oauth2ProxyClientSecret.path} \
      > /run/auth-gateway/client-secret
    test -s /run/auth-gateway/client-secret
    chmod 0400 /run/auth-gateway/client-secret
  '';
  waitForDiscovery = pkgs.writeShellScript "auth-gateway-wait-for-discovery" ''
    set -euo pipefail
    for _ in $(${pkgs.coreutils}/bin/seq 1 90); do
      if ${pkgs.curl}/bin/curl --silent --show-error --fail \
        --cacert /etc/ssl/certs/ca-bundle.crt \
        ${lib.escapeShellArg (vars.kanidmDiscoveryUrl "auth-gateway-web")} >/dev/null; then
        exit 0
      fi
      ${pkgs.coreutils}/bin/sleep 1
    done
    echo "Timed out waiting for auth-gateway-web OIDC discovery" >&2
    exit 1
  '';
  commonAccessLog = ''
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
  spoofableHeaders = [
    "X-Auth-Request-User"
    "X-Auth-Request-Email"
    "X-Auth-Request-Groups"
    "X-Auth-Request-Preferred-Username"
    "X-Forwarded-User"
    "X-Forwarded-Email"
    "X-Forwarded-Groups"
    "X-Forwarded-Preferred-Username"
    "Remote-User"
    "Remote_User"
    "X-WebAuth-User"
    "X_WebAuth_User"
  ];
  stripSpoofableHeaders = lib.concatMapStringsSep "\n" (header: "request_header -${header}") spoofableHeaders;
  routerProxy = ''
    reverse_proxy http://${loopback}:${toString cfg.internalPort} {
      header_up X-Forwarded-Host {host}
      header_up X-Forwarded-User {http.request.header.X-Auth-Request-User}
      header_up X-Forwarded-Email {http.request.header.X-Auth-Request-Email}
      header_up X-Forwarded-Groups {http.request.header.X-Auth-Request-Groups}
      header_up X-Forwarded-Preferred-Username {http.request.header.X-Auth-Request-Preferred-Username}
    }
  '';
  directCaddyBackend = name: app:
    let
      matcher = matcherName name;
      groups = lib.concatStringsSep "|" (map lib.escapeRegex app.allowedGroups);
    in
    ''
      @denied_${matcher} not header_regexp X-Auth-Request-Groups "(?i)(^|,)[[:space:]]*(${groups})[[:space:]]*(,|$)"
      respond @denied_${matcher} "Forbidden" 403
      ${app.authenticatedCaddyConfig}
    '';
  protectedBackend = name: app:
    if app.authenticatedCaddyConfig != null then
      directCaddyBackend name app
    else
      routerProxy;
  nativeAuthCaddyHandler = name: app:
    lib.optionalString (app.nativeAuthCaddyConfig != null) ''
      @native_auth_${matcherName name} path ${lib.concatStringsSep " " app.nativeAuthPaths}
      handle @native_auth_${matcherName name} {
        ${app.nativeAuthCaddyConfig}
      }
    '';
  forwardAuth = redirectUnauthorized: ''
    forward_auth http://${loopback}:${toString cfg.port} {
      uri /oauth2/auth
      header_up X-Real-IP {remote_host}
      copy_headers X-Auth-Request-User X-Auth-Request-Email X-Auth-Request-Groups X-Auth-Request-Preferred-Username
      ${lib.optionalString redirectUnauthorized ''
        @unauthorized status 401
        handle_response @unauthorized {
          redir * https://${authHost}/oauth2/start?rd=https://{host}{uri} 302
        }
      ''}
    }
  '';
  mkProtectedProxyConfig = name: app: ''
    ${commonAccessLog}
    route {
      ${stripSpoofableHeaders}
      @logout_${matcherName name} {
        method GET HEAD
        path /oauth2/sign_out
      }
      handle @logout_${matcherName name} {
        redir * https://${authHost}/oauth2/sign_out 302
      }
      ${nativeAuthCaddyHandler name app}
      ${lib.optionalString app.skipAuthPreflight ''
        @preflight_${matcherName name} method OPTIONS
        handle @preflight_${matcherName name} {
          reverse_proxy ${app.upstream} {
            ${upstreamTransport app}
          }
        }
      ''}
      ${lib.optionalString app.apiUnauthenticated401 ''
        @json_${matcherName name} header Accept *application/json*
        handle @json_${matcherName name} {
          ${forwardAuth false}
          ${routerProxy}
        }
        @api_${matcherName name} path /api /api/*
        handle @api_${matcherName name} {
          ${forwardAuth false}
          ${routerProxy}
        }
      ''}
      handle {
        ${forwardAuth true}
        ${protectedBackend name app}
      }
    }
  '';
  authGatewayProxy = ''
    reverse_proxy http://${loopback}:${toString cfg.port} {
      header_up X-Forwarded-Proto https
      header_up X-Forwarded-Host {host}
    }
  '';
  authProxyConfig = ''
    ${commonAccessLog}
    @auth_logout {
      method GET HEAD
      path /oauth2/sign_out
    }
    handle @auth_logout {
      uri query rd https://${vars.kanidmDomain}/ui/logout
      ${authGatewayProxy}
    }
    @signed_out {
      method GET HEAD
      path /signed-out
    }
    handle @signed_out {
      header {
        Cache-Control "no-store"
        Content-Security-Policy "default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; frame-ancestors 'none'"
        Content-Type "text/html; charset=utf-8"
        Referrer-Policy "no-referrer"
        X-Content-Type-Options "nosniff"
        X-Frame-Options "DENY"
      }
      respond <<HTML
        <!doctype html>
        <html lang="en">
          <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <title>Signed out of shared apps</title>
            <style>
              :root { color-scheme: light dark; font-family: system-ui, sans-serif; }
              body { display: grid; min-height: 100vh; margin: 0; place-items: center; background: #f4f7fb; color: #1f2937; }
              main { width: min(32rem, calc(100% - 3rem)); padding: 2rem; border: 1px solid #cad5e2; border-radius: 0.75rem; background: #fff; box-shadow: 0 1rem 3rem rgb(15 23 42 / 12%); }
              h1 { margin: 0 0 0.75rem; font-size: 1.75rem; }
              p { margin: 0; color: #526177; line-height: 1.6; }
              @media (prefers-color-scheme: dark) {
                body { background: #111827; color: #f8fafc; }
                main { border-color: #334155; background: #1e293b; }
                p { color: #cbd5e1; }
              }
            </style>
          </head>
          <body>
            <main>
              <h1>Signed out of shared apps</h1>
              <p>If you arrived here after choosing Sign out, the shared application session was cleared. Close this tab, or return to an app when you are ready to sign in again.</p>
            </main>
          </body>
        </html>
        HTML 200
    }
    handle {
      ${authGatewayProxy}
    }
  '';
in
{
  options.repo.authGateway = {
    enable = lib.mkOption { type = lib.types.bool; default = true; };
    mode = lib.mkOption {
      type = lib.types.enum [ "gateway" "sidecar" ];
      default = "gateway";
      description = "Shared gateway mode or legacy per-app OAuth2 Proxy sidecars.";
    };
    domain = lib.mkOption { type = lib.types.str; default = "auth.${vars.domain}"; };
    port = lib.mkOption { type = lib.types.port; default = 4180; };
    internalPort = lib.mkOption { type = lib.types.port; default = 4188; };
    protectedApps = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          host = lib.mkOption { type = lib.types.str; };
          upstream = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "HTTP upstream reached through the authenticated internal router.";
          };
          authenticatedRoutes = lib.mkOption {
            type = lib.types.listOf (lib.types.submodule {
              options = {
                pathPrefix = lib.mkOption {
                  type = lib.types.addCheck lib.types.str
                    (path: builtins.match "/[A-Za-z0-9._~!$&'()*+,;=:@%-]+(/[A-Za-z0-9._~!$&'()*+,;=:@%-]+)*" path != null);
                  description = "Authenticated path prefix routed to a secondary loopback service.";
                };
                upstream = lib.mkOption { type = lib.types.str; };
              };
            });
            default = [ ];
          };
          authenticatedCaddyConfig = lib.mkOption {
            type = lib.types.nullOr lib.types.lines;
            default = null;
            description = "Caddy directives executed directly after OIDC and group authorization instead of proxying to an HTTP upstream.";
          };
          nativeAuthPaths = lib.mkOption {
            type = lib.types.listOf (lib.types.addCheck lib.types.str
              (path: builtins.match "/[A-Za-z0-9._~!$&'()*+,;=:@%/?-]*" path != null));
            default = [ ];
            description = "Exact Caddy path matchers that bypass browser OIDC and rely on the application's native authentication.";
          };
          nativeAuthCaddyConfig = lib.mkOption {
            type = lib.types.nullOr lib.types.lines;
            default = null;
            description = "Caddy directives for native-authentication paths; these receive no identity from the shared OIDC gateway.";
          };
          allowedGroups = lib.mkOption { type = lib.types.listOf lib.types.str; };
          skipAuthPreflight = lib.mkOption { type = lib.types.bool; default = false; };
          apiUnauthenticated401 = lib.mkOption { type = lib.types.bool; default = true; };
          upstreamTimeout = lib.mkOption { type = lib.types.nullOr lib.types.str; default = null; };
        };
      });
      default = { };
    };
  };

  config = lib.mkMerge [
    {
      # This is a normal attrsOf definition rather than an option default so
      # independently registered apps merge with the core/app inventory.
      repo.authGateway.protectedApps = defaultApps;
    }

    (lib.mkIf (cfg.enable && cfg.mode == "gateway") {
      assertions = lib.mapAttrsToList
        (name: app: {
          assertion = (app.upstream != null) != (app.authenticatedCaddyConfig != null)
            && (app.authenticatedCaddyConfig == null || (!app.skipAuthPreflight && !app.apiUnauthenticated401))
            && ((app.nativeAuthPaths != [ ]) == (app.nativeAuthCaddyConfig != null))
            && (app.nativeAuthCaddyConfig == null || app.authenticatedCaddyConfig != null)
            && lib.length (lib.unique app.nativeAuthPaths) == lib.length app.nativeAuthPaths
            && lib.length (lib.unique (map (route: route.pathPrefix) app.authenticatedRoutes)) == lib.length app.authenticatedRoutes
            && (app.authenticatedRoutes == [ ] || app.upstream != null);
          message = "Authentication gateway app '${name}' must select exactly one HTTP upstream or authenticated Caddy handler; native-auth paths require a unique, direct Caddy handler and cannot receive browser-auth bypasses.";
        })
        cfg.protectedApps;

      systemd.services = (lib.genAttrs sidecarServices (_: { wantedBy = lib.mkForce [ ]; })) // {
        auth-gateway-router = {
          description = "Route authenticated gateway requests to protected applications";
          wantedBy = [ "multi-user.target" ];
          after = [ "network.target" ];
          serviceConfig = {
            Type = "simple";
            User = "oauth2-proxy";
            Group = "oauth2-proxy";
            ExecStart = "${pkgs.caddy}/bin/caddy run --config ${routerCaddyfile}";
            Restart = "on-failure";
            RestartSec = "5s";
            NoNewPrivileges = true;
            PrivateTmp = true;
          };
        };

        auth-gateway-oauth2-proxy = {
          description = "Shared OAuth2 Proxy authentication gateway";
          wantedBy = [ "multi-user.target" ];
          conflicts = sidecarUnits;
          before = sidecarUnits;
          wants = [ "network-online.target" "kanidm.service" "auth-gateway-router.service" ];
          after = [ "network-online.target" "kanidm.service" "auth-gateway-router.service" ];
          serviceConfig = {
            Type = "simple";
            User = "oauth2-proxy";
            Group = "oauth2-proxy";
            ExecStart = lib.concatStringsSep " " (map lib.escapeShellArg [
              "${pkgs.oauth2-proxy}/bin/oauth2-proxy"
              "--provider=oidc"
              "--oidc-issuer-url=${vars.kanidmIssuer "auth-gateway-web"}"
              "--client-id=auth-gateway-web"
              "--client-secret-file=/run/auth-gateway/client-secret"
              "--cookie-secret-file=/run/auth-gateway/cookie-secret"
              "--cookie-name=__Secure-nixhomeserver_sso"
              "--cookie-domain=.${vars.domain}"
              "--cookie-secure=true"
              "--cookie-httponly=true"
              "--cookie-samesite=lax"
              "--whitelist-domain=.${vars.domain}"
              "--redirect-url=https://${authHost}/oauth2/callback"
              "--http-address=${loopback}:${toString cfg.port}"
              "--upstream=static://202"
              "--scope=openid profile email groups_name"
              "--email-domain=*"
              "--oidc-groups-claim=groups"
              "--pass-user-headers=true"
              "--set-xauthrequest=true"
              "--reverse-proxy=true"
              "--skip-provider-button=true"
              "--skip-auth-preflight=true"
              "--api-route=^/api/"
              "--code-challenge-method=S256"
              "--provider-ca-file=/etc/ssl/certs/ca-bundle.crt"
            ]);
            Restart = "on-failure";
            RestartSec = "5s";
            NoNewPrivileges = true;
            PrivateTmp = true;
            ProtectSystem = "strict";
            ProtectHome = true;
            RuntimeDirectory = "auth-gateway";
            UMask = "0077";
            ExecStartPre = [ prepareClientSecret prepareCookieSecret waitForDiscovery ];
            ReadOnlyPaths = [
              config.age.secrets.oauth2ProxyClientSecret.path
              config.age.secrets.oauth2ProxyCookieSecret.path
            ];
          };
        };
      };

      services.caddy.virtualHosts =
        (lib.mapAttrs'
          (name: app: lib.nameValuePair app.host {
            logFormat = lib.mkForce null;
            useACMEHost = vars.domain;
            extraConfig = lib.mkForce (lib.optionalString (app.host == "files.${vars.domain}") ''
              @download_html_svg path *.html *.svg
              header @download_html_svg Content-Disposition attachment
              header @download_html_svg X-Content-Type-Options nosniff
            '' + mkProtectedProxyConfig name app);
          })
          cfg.protectedApps)
        // {
          ${authHost} = {
            logFormat = lib.mkForce null;
            useACMEHost = vars.domain;
            extraConfig = lib.mkForce authProxyConfig;
          };
        };

      services.unbound.privateHosts.${authHost}.target = "private";
      services.cloudflared.tunnels.${vars.cloudflareTunnelName}.ingress.${authHost} = {
        service = "https://${loopback}:${toString vars.networking.ports.https}";
        originRequest.originServerName = authHost;
      };
    })
  ];
}
