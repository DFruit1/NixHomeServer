{ config, lib, pkgs, vars, ... }:

let
  cfg = config.repo.forgejo;
  repoRoot = ../..;
  host = "git.${vars.domain}";
  stateDir = "/var/lib/forgejo";
  mirrorUser = "forgejo-mirror";
  githubTokenEnabled = builtins.pathExists (repoRoot + "/secrets/forgejoGithubToken.age");
  mirrorsFile = pkgs.writeText "forgejo-mirrors.json" (builtins.toJSON cfg.mirrors);
  mirrorCollaborators = lib.unique vars.kanidmAppUsers;
in
{
  options.repo.forgejo = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether to run the private Forgejo git forge, OIDC login, and declared mirrors.";
    };

    mirrors = lib.mkOption {
      type = lib.types.listOf (lib.types.submodule {
        options = {
          url = lib.mkOption {
            type = lib.types.str;
            description = "Upstream HTTPS clone URL, for example https://github.com/owner/repo.git.";
          };
          interval = lib.mkOption {
            type = lib.types.str;
            default = "24h";
            description = "How often Forgejo pulls upstream changes for this mirror.";
          };
          private = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = "Whether the local mirror repository is private.";
          };
          owner = lib.mkOption {
            type = lib.types.str;
            default = mirrorUser;
            description = ''
              Local Forgejo account that owns the mirror. Defaults to the
              dedicated mirror account; set it to a personal account only after
              that account exists from a first Kanidm login.
            '';
          };
        };
      });
      default = vars.forgejo.mirrors or [ ];
      description = ''
        Upstream repositories pulled into Forgejo as declarative pull mirrors.
        Entries are created and kept up to date by a reconciliation service
        rather than by hand in the web UI.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    services.forgejo = {
      enable = true;
      package = pkgs.forgejo;
      stateDir = stateDir;
      database.type = "sqlite3";
      lfs.enable = true;

      settings = {
        DEFAULT.APP_NAME = vars.brandName;

        server = {
          DOMAIN = host;
          ROOT_URL = "https://${host}/";
          HTTP_ADDR = vars.networking.loopbackIPv4;
          HTTP_PORT = vars.networking.ports.forgejo;
          # The built-in SSH server serves git over SSH on the LAN and NetBird
          # interfaces; the host firewall scopes the port accordingly.
          START_SSH_SERVER = true;
          DISABLE_SSH = false;
          SSH_LISTEN_HOST = "0.0.0.0";
          SSH_LISTEN_PORT = vars.networking.ports.forgejoSsh;
          SSH_PORT = vars.networking.ports.forgejoSsh;
          LFS_START_SERVER = true;
        };

        session.COOKIE_SECURE = true;

        service = {
          DISABLE_REGISTRATION = true;
          ALLOW_ONLY_EXTERNAL_REGISTRATION = true;
          SHOW_REGISTRATION_BUTTON = false;
          ENABLE_NOTIFY_MAIL = false;
          DEFAULT_KEEP_EMAIL_PRIVATE = true;
        };

        repository.DEFAULT_PRIVATE = "private";

        # Accounts are created from the Kanidm OIDC source; the preferred_username
        # claim is the short Kanidm name because Forgejo usernames cannot contain "@".
        "oauth2_client" = {
          ENABLE_AUTO_REGISTRATION = true;
          ACCOUNT_LINKING = "login";
          USERNAME = "nickname";
          OPENID_CONNECT_SCOPES = "openid profile email";
        };

        # OpenID (not OAuth2) sign-in is intentionally disabled.
        openid.ENABLE_OPENID_SIGNIN = false;
      };
    };

    # The Forgejo units set ProtectSystem=strict with ReadWritePaths pointing at
    # state subdirectories. Under impermanence /var/lib/forgejo is a bind mount
    # that only materializes during activation, so those subdirectories must be
    # created after the mount is active and before the services start.
    systemd.services.forgejo-storage-layout-v1 = {
      description = "Provision Forgejo state directories";
      wantedBy = [ "multi-user.target" ];
      before = [
        "forgejo-secrets.service"
        "forgejo.service"
        "forgejo-oidc-bootstrap.service"
        "forgejo-mirrors.service"
      ];
      unitConfig.RequiresMountsFor = [ stateDir ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      path = [ pkgs.coreutils ];
      script = ''
        set -euo pipefail
        install -d -m 0750 -o forgejo -g forgejo ${stateDir}
        install -d -m 0750 -o forgejo -g forgejo ${stateDir}/custom
        install -d -m 0750 -o forgejo -g forgejo ${stateDir}/custom/conf
        install -d -m 0750 -o forgejo -g forgejo ${stateDir}/data
        install -d -m 0750 -o forgejo -g forgejo ${stateDir}/data/lfs
        install -d -m 0750 -o forgejo -g forgejo ${stateDir}/dump
        install -d -m 0750 -o forgejo -g forgejo ${stateDir}/log
        install -d -m 0750 -o forgejo -g forgejo ${stateDir}/repositories
        install -d -m 0700 -o forgejo -g forgejo ${stateDir}/.ssh
      '';
    };

    systemd.services.forgejo-secrets = {
      wants = [ "forgejo-storage-layout-v1.service" ];
      after = [ "forgejo-storage-layout-v1.service" ];
      unitConfig.RequiresMountsFor = [ stateDir ];
    };

    systemd.services.forgejo = {
      wants = [
        "network-online.target"
        "unbound.service"
        "forgejo-storage-layout-v1.service"
      ];
      after = [
        "network-online.target"
        "unbound.service"
        "forgejo-storage-layout-v1.service"
      ];
      unitConfig.RequiresMountsFor = [ stateDir ];
    };

    systemd.services.forgejo-mirrors = lib.mkIf (cfg.mirrors != [ ]) (
      {
        description = "Reconcile declarative Forgejo pull mirrors";
        wantedBy = [ "multi-user.target" ];
        wants = [ "network-online.target" ];
        requires = [ "forgejo.service" ];
        after = [
          "network-online.target"
          "forgejo.service"
        ];
        path = with pkgs; [
          config.services.forgejo.package
          coreutils
          curl
          findutils
          gnugrep
          jq
        ];
        environment = {
          USER = "forgejo";
          HOME = stateDir;
          FORGEJO_WORK_DIR = stateDir;
          FORGEJO_CUSTOM = "${stateDir}/custom";
          FORGEJO_API_URL = "http://${vars.networking.loopbackIPv4}:${toString vars.networking.ports.forgejo}";
          FORGEJO_MIRROR_USER = mirrorUser;
          FORGEJO_MIRROR_EMAIL = "${mirrorUser}@${vars.domain}";
          FORGEJO_MIRROR_TOKEN_FILE = "${stateDir}/.nixhomeserver-mirror-token";
          FORGEJO_MIRRORS_FILE = mirrorsFile;
          FORGEJO_MIRROR_COLLABORATORS = lib.concatStringsSep "," mirrorCollaborators;
          FORGEJO_MIRRORS_HAS_GITHUB_TOKEN = if githubTokenEnabled then "1" else "0";
        };
        serviceConfig = {
          Type = "oneshot";
          User = "forgejo";
          Group = "forgejo";
          UMask = "0077";
          ProtectSystem = "strict";
          ProtectHome = true;
          PrivateTmp = true;
          NoNewPrivileges = true;
          RestrictSUIDSGID = true;
          ReadWritePaths = [ stateDir ];
        }
        // lib.optionalAttrs githubTokenEnabled {
          LoadCredential = [ "github-token:${config.age.secrets.forgejoGithubToken.path}" ];
        };
        script = "bash ${./reconcile-mirrors.sh}";
      }
    );

    systemd.timers.forgejo-mirrors = lib.mkIf (cfg.mirrors != [ ]) {
      description = "Periodically reconcile declarative Forgejo pull mirrors";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "10m";
        OnUnitActiveSec = "6h";
        Persistent = true;
        Unit = "forgejo-mirrors.service";
      };
    };
  };
}
