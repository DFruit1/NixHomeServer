{ config, lib, pkgs, vars, ... }:

let
  cfg = config.repo.authGateway;
  loopback = vars.networking.loopbackIPv4;
  authHost = cfg.domain;
  sidecarServices = [
    "filestash-oauth2-proxy"
    "homepage-oauth2-proxy"
    "kiwix-oauth2-proxy"
    "kopia-oauth2-proxy"
    "mail-archive-oauth2-proxy"
    "monitor-oauth2-proxy"
    "prowlarr-oauth2-proxy"
    "qbittorrent-oauth2-proxy"
    "radarr-oauth2-proxy"
    "seerr-oauth2-proxy"
    "sonarr-oauth2-proxy"
    "youtube-downloader-oauth2-proxy"
  ];
  sidecarUnits = map (name: "${name}.service") sidecarServices;
  mkApp = host: upstream: allowedGroups: {
    inherit host upstream allowedGroups;
  };
  defaultApps = {
    homepage = mkApp "homepage.${vars.domain}" "http://${loopback}:${toString vars.networking.ports.homepage}" [ "users" ];
    files = (mkApp "files.${vars.domain}" "http://${loopback}:${toString vars.networking.ports.filestash}" [
      vars.fileAccess.webAccessGroup
      vars.fileAccess.usbAccessGroup
      vars.backupAccess.storageGroup
    ]) // {
      skipAuthPreflight = true;
    };
    mail = mkApp "emails.${vars.domain}" "http://${loopback}:${toString vars.networking.ports.mailArchiveUi}" [ "mail-archive-users" ];
    kiwix = mkApp "wiki.${vars.domain}" "http://${loopback}:${toString vars.networking.ports.kiwix}" [ "kiwix-users" ];
    downloads = mkApp "ytdownload.${vars.domain}" "http://${loopback}:${toString vars.networking.ports.youtubeDownloader}" [ "downloads-users" ];
    monitor = mkApp vars.monitorDomain "http://${loopback}:${toString vars.networking.ports.beszelHub}" [ "app-admin" ];
    kopia = mkApp vars.kopiaDomain "http://${loopback}:${toString (vars.networking.ports.kopia + 1)}" [ vars.backupAccess.adminGroup ];
    seerr = mkApp "requests.${vars.domain}" "http://${loopback}:${toString vars.networking.ports.seerr}" [ "media-automation-users" ];
    sonarr = mkApp "sonarr.${vars.domain}" "http://${loopback}:${toString vars.networking.ports.sonarr}" [ "media-automation-users" ];
    radarr = mkApp "radarr.${vars.domain}" "http://${loopback}:${toString vars.networking.ports.radarr}" [ "media-automation-users" ];
    prowlarr = mkApp "prowlarr.${vars.domain}" "http://${loopback}:${toString vars.networking.ports.prowlarr}" [ "media-automation-users" ];
    qbittorrent = mkApp "torrents.${vars.domain}" "http://${loopback}:${toString vars.networking.ports.qbittorrentWeb}" [ "media-automation-users" ];
  };
  matcherName = name: lib.replaceStrings [ "-" "." ] [ "_" "_" ] name;
  mkRouterBlock = name: app:
    let
      matcher = matcherName name;
      groups = lib.concatStringsSep "|" (map lib.escapeRegex app.allowedGroups);
    in
    ''
      @host_${matcher} header X-Forwarded-Host ${app.host}
      handle @host_${matcher} {
        @denied_${matcher} not header_regexp X-Forwarded-Groups "(?i)(^|,)[[:space:]]*(${groups})[[:space:]]*(,|$)"
        respond @denied_${matcher} "Forbidden" 403
        reverse_proxy ${app.upstream} {
          header_up -X-Auth-Request-User
          header_up -X-Auth-Request-Email
          header_up -X-Auth-Request-Groups
          header_up -X-Auth-Request-Preferred-Username
          header_up X-Forwarded-User {http.request.header.X-Forwarded-User}
          header_up X-Forwarded-Email {http.request.header.X-Forwarded-Email}
          header_up X-Forwarded-Groups {http.request.header.X-Forwarded-Groups}
          header_up X-Forwarded-Preferred-Username {http.request.header.X-Forwarded-Preferred-Username}
        }
      }
    '';
  routerCaddyfile = pkgs.writeText "auth-gateway-router.Caddyfile" ''
    {
      admin off
      auto_https off
    }
    http://${loopback}:${toString cfg.internalPort} {
      ${lib.concatStringsSep "\n" (lib.mapAttrsToList mkRouterBlock cfg.protectedApps)}
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
      ${lib.optionalString app.skipAuthPreflight ''
        @preflight_${matcherName name} method OPTIONS
        handle @preflight_${matcherName name} {
          reverse_proxy ${app.upstream}
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
        ${routerProxy}
      }
    }
  '';
  authProxyConfig = ''
    ${commonAccessLog}
    reverse_proxy http://${loopback}:${toString cfg.port} {
      header_up X-Forwarded-Proto https
      header_up X-Forwarded-Host {host}
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
          upstream = lib.mkOption { type = lib.types.str; };
          allowedGroups = lib.mkOption { type = lib.types.listOf lib.types.str; };
          skipAuthPreflight = lib.mkOption { type = lib.types.bool; default = false; };
          apiUnauthenticated401 = lib.mkOption { type = lib.types.bool; default = true; };
          upstreamTimeout = lib.mkOption { type = lib.types.nullOr lib.types.str; default = null; };
        };
      });
      default = defaultApps;
    };
  };

  config = lib.mkIf (cfg.enable && cfg.mode == "gateway") {
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
  };
}
