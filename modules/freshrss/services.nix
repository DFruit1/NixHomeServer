{ config, lib, pkgs, vars, ... }:

let
  cfg = config.repo.freshrss;
  host = "rss.${vars.domain}";
  username = import ./username.nix;
  invalidFreshRSSUsers = builtins.filter (value: !username.valid value) vars.kanidmAppUsers;
  reconcileHttpAuthConfig = pkgs.writeText "freshrss-reconcile-http-auth.php"
    (builtins.readFile ./reconcile-http-auth.php);
  allowedUsersFile = pkgs.writeText "freshrss-allowed-users"
    (builtins.concatStringsSep "\n" (lib.unique (vars.kanidmAppUsers ++ [ vars.kanidmAdminUser ])));
  egressPolicy = pkgs.writeShellScript "freshrss-egress-policy" ''
    set -euo pipefail

    freshrss_uid="$(${pkgs.coreutils}/bin/id -u freshrss)"
    ${pkgs.nftables}/bin/nft delete table inet freshrss_egress 2>/dev/null || true
    ${pkgs.nftables}/bin/nft -f - <<EOF
    table inet freshrss_egress {
      chain output {
        type filter hook output priority filter; policy accept;
        meta skuid $freshrss_uid ip daddr { ${vars.networking.loopbackIPv4Cidr}, ${vars.networking.lan.gateway}/32 } meta l4proto { tcp, udp } th dport 53 accept
        meta skuid $freshrss_uid fib daddr type local reject
        meta skuid $freshrss_uid ip daddr { 0.0.0.0/8, 10.0.0.0/8, 100.64.0.0/10, 127.0.0.0/8, 169.254.0.0/16, 172.16.0.0/12, 192.0.0.0/24, 192.0.2.0/24, 192.168.0.0/16, 198.18.0.0/15, 198.51.100.0/24, 203.0.113.0/24, 224.0.0.0/4, 240.0.0.0/4 } reject with icmp type admin-prohibited
        meta skuid $freshrss_uid ip6 daddr { ::/128, ::1/128, ::ffff:0:0/96, 64:ff9b::/96, 100::/64, 2001:db8::/32, fc00::/7, fe80::/10, ff00::/8 } reject with icmpv6 type admin-prohibited
      }
    }
    EOF
  '';
  removeEgressPolicy = pkgs.writeShellScript "freshrss-remove-egress-policy" ''
    ${pkgs.nftables}/bin/nft delete table inet freshrss_egress 2>/dev/null || true
  '';
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

    extensions = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [ ];
      description = "FreshRSS extensions passed through to services.freshrss.extensions.";
    };
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
      extensions = cfg.extensions;
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

    # Feed fetching is server-side, so the freshrss user must not reach
    # private or local destinations. DNS still resolves through the local
    # resolver so public feeds remain reachable. Both the PHP-FPM pool and the
    # periodic updater run as the freshrss user and inherit this restriction.
    systemd.services.freshrss-egress-policy = {
      description = "Block FreshRSS feed-fetch access to private network ranges";
      wantedBy = [ "multi-user.target" ];
      before = [ "freshrss-updater.service" "phpfpm-freshrss.service" ];
      after = [ "systemd-sysusers.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = egressPolicy;
        ExecStop = removeEgressPolicy;
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ProtectKernelModules = true;
        ProtectKernelTunables = true;
        RestrictAddressFamilies = [ "AF_NETLINK" ];
      };
    };

    # Removing a Kanidm user from freshrss-users does not revoke an existing
    # GReader API password, so the local account must be retired once the
    # gateway no longer authorizes its owner. Accounts are moved out of
    # users/ (stopping login and API access) into a retained state so a
    # mistake or later re-addition never destroys feed history.
    systemd.services.freshrss-account-reconcile = {
      description = "Retire FreshRSS accounts for users removed from freshrss-users";
      wants = [ "local-fs.target" ];
      after = [ "local-fs.target" "freshrss-config.service" ];
      path = with pkgs; [ bash coreutils findutils ];
      environment = {
        FRESHRSS_DATA_PATH = cfg.stateDir;
        FRESHRSS_ALLOWED_USERS_FILE = allowedUsersFile;
        FRESHRSS_USERNAME_PATTERN = username.shellPattern;
      };
      serviceConfig = {
        Type = "oneshot";
        User = "freshrss";
        Group = "freshrss";
      };
      script = ''
        bash ${./reconcile-accounts.sh}
      '';
    };

    systemd.timers.freshrss-account-reconcile = {
      description = "Periodically retire FreshRSS accounts for removed users";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "2m";
        OnUnitActiveSec = "1h";
        Persistent = true;
        Unit = "freshrss-account-reconcile.service";
      };
    };
  };
}
