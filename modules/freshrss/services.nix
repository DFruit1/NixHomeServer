{ config, lib, pkgs, vars, ... }:

let
  cfg = config.repo.freshrss;
  host = "rss.${vars.domain}";
  username = import ./username.nix;
  invalidFreshRSSUsers = builtins.filter (value: !username.valid value) vars.kanidmAppUsers;
  reconcileHttpAuthConfig = pkgs.writeText "freshrss-reconcile-http-auth.php"
    (builtins.readFile ./reconcile-http-auth.php);
  securityHeaders = ''
    header {
      -Server
      ?Strict-Transport-Security "max-age=31536000"
      ?X-Content-Type-Options "nosniff"
      ?X-Frame-Options "DENY"
      ?Referrer-Policy "same-origin"
      ?Permissions-Policy "camera=(), geolocation=(), microphone=()"
    }
  '';
  mkCaddyConfig = { authenticated, noStore ? false }: ''
    root * ${cfg.package}/p
    ${securityHeaders}
    ${lib.optionalString noStore ''header >Cache-Control "no-store"''}
    php_fastcgi unix/${config.services.phpfpm.pools.freshrss.socket} {
      env FRESHRSS_DATA_PATH ${cfg.stateDir}
      ${lib.optionalString authenticated ''env REMOTE_USER {http.request.header.X-Auth-Request-Preferred-Username}''}
      capture_stderr
    }
    file_server
  '';
in
{
  options.repo.freshrss = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether to run the private FreshRSS feed reader.";
    };

    package = lib.mkPackageOption pkgs "freshrss" { };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = invalidFreshRSSUsers == [ ];
        message = "FreshRSS OIDC usernames must match FreshRSS's 1-39 character account format; incompatible Kanidm app users: ${lib.concatStringsSep ", " invalidFreshRSSUsers}";
      }
    ];

    services.freshrss = {
      enable = true;
      package = cfg.package;
      defaultUser = vars.kanidmAdminUser;
      baseUrl = "https://${host}";
      dataDir = cfg.stateDir;
      database.type = "sqlite";
      webserver = "caddy";
      virtualHost = host;
      authType = "http_auth";
      api.enable = true;
    };

    # Serve FreshRSS inside the already-authenticated public Caddy request.
    # PHP-FPM's 0600 socket is owned by Caddy, so an unrelated local service
    # cannot reach the FastCGI boundary and forge REMOTE_USER.
    repo.authGateway.protectedApps.freshrss = {
      authenticatedCaddyConfig = mkCaddyConfig { authenticated = true; };
      nativeAuthPaths = [ "/api/greader.php" "/api/greader.php/*" ];
      nativeAuthCaddyConfig = mkCaddyConfig {
        authenticated = false;
        noStore = true;
      };
    };

    systemd.services.freshrss-config = {
      wants = [ "local-fs.target" ];
      after = [ "local-fs.target" ];
      script = lib.mkAfter ''
        FRESHRSS_DATA_PATH=${lib.escapeShellArg cfg.stateDir} \
          ${config.services.phpfpm.phpPackage}/bin/php ${reconcileHttpAuthConfig}
      '';
    };
  };
}
