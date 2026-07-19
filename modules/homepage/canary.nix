{ appPackages, config, lib, pkgs, vars, ... }:

let
  canaryUser = "homepage-canary";
  canaryGroup = "homepage-canary";
  stateDir = "/var/lib/homepage-canary";
  credentialStateDir = "/var/lib/homepage-canary-credentials";
  totpSeedPath = "${credentialStateDir}/kanidm-totp-seed";
  caddyHosts = config.services.caddy.virtualHosts;
  offlineMediaEnabled =
    (config.nixhomeserver.modules."offline-music" or false)
    && (vars.offlineMedia.enable or false);
  hostEnabled = host: builtins.hasAttr host caddyHosts;
  mkTarget = { id, name, host, path ? "", coverageMode, expectedPattern, active ? hostEnabled host }: {
    inherit id name host coverageMode expectedPattern active;
    url = "https://${host}${path}";
  };
  allTargets = [
    (mkTarget { id = "homepage"; name = "Homepage"; host = "homepage.${vars.domain}"; coverageMode = "gateway"; expectedPattern = "${lib.escapeRegex vars.brandName}|Homepage sections"; })
    (mkTarget { id = "offline-media"; name = "Offline Media"; host = "homepage.${vars.domain}"; path = "/services/offline-media"; coverageMode = "gateway"; expectedPattern = "Offline Media"; active = offlineMediaEnabled; })
    (mkTarget { id = "photos"; name = "Photos"; host = "photos.${vars.domain}"; coverageMode = "native-oidc"; expectedPattern = "Immich|Photos"; })
    (mkTarget { id = "documents"; name = "Documents"; host = "paperless.${vars.domain}"; coverageMode = "native-oidc"; expectedPattern = "Paperless|Documents"; })
    (mkTarget { id = "files"; name = "Files"; host = "files.${vars.domain}"; coverageMode = "gateway"; expectedPattern = "Filestash|Files"; })
    (mkTarget { id = "audiobooks"; name = "Audiobooks"; host = "audiobooks.${vars.domain}"; path = "/audiobookshelf/"; coverageMode = "native-oidc"; expectedPattern = "Audiobookshelf|Audiobooks"; })
    (mkTarget { id = "videos"; name = "Videos"; host = "videos.${vars.domain}"; coverageMode = "local-boundary"; expectedPattern = "Jellyfin|Videos"; })
    (mkTarget { id = "requests"; name = "Requests"; host = "requests.${vars.domain}"; coverageMode = "gateway"; expectedPattern = "Seerr|Jellyseerr|Requests"; })
    (mkTarget { id = "sonarr"; name = "TV Show Downloads"; host = "sonarr.${vars.domain}"; coverageMode = "gateway"; expectedPattern = "Sonarr|TV Show"; })
    (mkTarget { id = "radarr"; name = "Movie Downloads"; host = "radarr.${vars.domain}"; coverageMode = "gateway"; expectedPattern = "Radarr|Movie"; })
    (mkTarget { id = "prowlarr"; name = "Prowlarr"; host = "prowlarr.${vars.domain}"; coverageMode = "gateway"; expectedPattern = "Prowlarr"; })
    (mkTarget { id = "torrents"; name = "Torrents"; host = "torrents.${vars.domain}"; coverageMode = "gateway"; expectedPattern = "qBittorrent|Torrents"; })
    (mkTarget { id = "books"; name = "Books"; host = "books.${vars.domain}"; coverageMode = "native-oidc"; expectedPattern = "Kavita|Books"; })
    (mkTarget { id = "wiki"; name = "Offline Wiki"; host = "wiki.${vars.domain}"; coverageMode = "gateway"; expectedPattern = "Kiwix|Offline Wiki"; })
    (mkTarget { id = "emails"; name = "Mail Archive"; host = "emails.${vars.domain}"; coverageMode = "gateway"; expectedPattern = "Mail Archive|Emails"; })
    (mkTarget { id = "downloads"; name = "YouTube Downloads"; host = "ytdownload.${vars.domain}"; coverageMode = "gateway"; expectedPattern = "YouTube|Downloads"; })
    (mkTarget { id = "passwords"; name = "Passwords"; host = "passwords.${vars.domain}"; coverageMode = "local-boundary"; expectedPattern = "Vaultwarden|Bitwarden|Passwords"; })
    (mkTarget { id = "backups"; name = "Local Backups"; host = vars.kopiaDomain; coverageMode = "gateway-boundary"; expectedPattern = "Kopia|Backups"; })
    (mkTarget { id = "monitor"; name = "Monitor"; host = vars.monitorDomain; coverageMode = "gateway-boundary"; expectedPattern = "Beszel|Monitor"; })
  ];
  targets = map (target: removeAttrs target [ "host" "active" ]) (builtins.filter (target: target.active && hostEnabled target.host) allTargets);
  canaryConfig = pkgs.writeText "homepage-canary-config.json" (builtins.toJSON {
    schemaVersion = 1;
    username = vars.kanidmCanaryUser;
    homepageUrl = "https://homepage.${vars.domain}";
    kanidmUrl = vars.kanidmBaseUrl;
    authHost = config.repo.authGateway.domain;
    inherit targets;
  });
  runner = pkgs.writeShellApplication {
    name = "homepage-canary-runner";
    runtimeInputs = [ pkgs.chromedriver pkgs.chromium pkgs.nodejs ];
    text = ''
      export CHROMEDRIVER_BIN=${lib.escapeShellArg "${pkgs.chromedriver}/bin/chromedriver"}
      export CHROMIUM_BIN=${lib.escapeShellArg "${pkgs.chromium}/bin/chromium"}
      exec ${pkgs.nodejs}/bin/node ${./canary-runner.mjs}
    '';
  };
  trigger = pkgs.writeShellScript "homepage-canary-trigger" ''
    set -euo pipefail
    if ${pkgs.systemd}/bin/systemctl is-active --quiet homepage-canary.service; then
      echo "canary run already active" >&2
      exit 75
    fi
    exec ${pkgs.systemd}/bin/systemctl start --no-block homepage-canary.service
  '';
  assertLatest = pkgs.writeShellApplication {
    name = "homepage-canary-assert";
    runtimeInputs = [ pkgs.jq ];
    text = ''
      latest=${lib.escapeShellArg "${stateDir}/latest.json"}
      if [[ ! -s "$latest" ]]; then
        echo "blocked: service-access canary has no result" >&2
        exit 1
      fi
      state="$(jq -r '.state // "failed"' "$latest")"
      if [[ "$state" != "passed" ]]; then
        jq -r '.results[]? | select(.status == "failed") | "blocked: \(.name) [\(.phase)] \(.failureCode): \(.message)"' "$latest" >&2
        echo "blocked: service-access canary state is $state" >&2
        exit 1
      fi
      jq -r '"Service-access canary passed for \(.targetCount) target(s)."' "$latest"
    '';
  };
  cleanupRunningState = pkgs.writeShellScript "homepage-canary-clean-running-state" ''
    set -euo pipefail
    rm -f ${lib.escapeShellArg "${stateDir}/running.json"}
  '';
in
{
  users.groups.${canaryGroup} = { };
  users.users.${canaryUser} = {
    isSystemUser = true;
    group = canaryGroup;
    home = stateDir;
  };
  users.users.homepage.extraGroups = [ canaryGroup ];

  environment.systemPackages = [ assertLatest ];

  systemd.services.kanidm-canary-bootstrap = {
    description = "Provision and verify the synthetic Kanidm canary credentials";
    wantedBy = [ "multi-user.target" ];
    after = [ "kanidm.service" ];
    wants = [ "kanidm.service" ];
    before = [ "homepage-canary.service" ];
    restartTriggers = [ config.age.secrets.canaryUserPassword.file ];
    environment = {
      KANIDM_URL = vars.kanidmBaseUrl;
      KANIDM_ADMIN_USERNAME = "idm_admin";
      CANARY_USERNAME = vars.kanidmCanaryUser;
      CANARY_TOTP_SEED_FILE = totpSeedPath;
    };
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${appPackages.kanidm-canary-bootstrap}/bin/kanidm-canary-bootstrap";
      LoadCredential = [
        "idm-admin-password:${config.age.secrets.kanidmAdminPass.path}"
        "canary-password:${config.age.secrets.canaryUserPassword.path}"
      ];
      StateDirectory = "homepage-canary-credentials";
      StateDirectoryMode = "0700";
      Restart = "on-failure";
      RestartSec = "5s";
      TimeoutStartSec = "2min";
      PrivateTmp = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      NoNewPrivileges = true;
      RestrictSUIDSGID = true;
      UMask = "0077";
      ReadWritePaths = [ credentialStateDir ];
    };
  };

  systemd.services.homepage-canary = {
    description = "Headless browser service-access canary";
    after = [ "network-online.target" "kanidm-canary-bootstrap.service" "caddy.service" "homepage.service" ];
    wants = [ "network-online.target" "caddy.service" "homepage.service" ];
    requires = [ "kanidm-canary-bootstrap.service" ];
    environment = {
      CANARY_CONFIG_FILE = canaryConfig;
      CANARY_STATE_DIR = stateDir;
      HOME = stateDir;
    };
    serviceConfig = {
      Type = "oneshot";
      User = canaryUser;
      Group = canaryGroup;
      ExecStartPre = cleanupRunningState;
      ExecStart = "${pkgs.util-linux}/bin/flock --nonblock /run/homepage-canary/run.lock ${runner}/bin/homepage-canary-runner";
      ExecStopPost = cleanupRunningState;
      LoadCredential = [
        "kanidm-password:${config.age.secrets.canaryUserPassword.path}"
        "kanidm-totp-seed:${totpSeedPath}"
      ];
      StateDirectory = "homepage-canary";
      StateDirectoryMode = "0750";
      RuntimeDirectory = "homepage-canary";
      RuntimeDirectoryMode = "0750";
      TimeoutStartSec = "12min";
      PrivateTmp = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      NoNewPrivileges = true;
      RestrictSUIDSGID = true;
      UMask = "0027";
      ReadOnlyPaths = [
        canaryConfig
        config.age.secrets.canaryUserPassword.path
        totpSeedPath
      ];
      ReadWritePaths = [ stateDir ];
    };
  };

  systemd.timers.homepage-canary = {
    description = "Periodically verify authenticated service access";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "15min";
      OnUnitActiveSec = "6h";
      RandomizedDelaySec = "15min";
      Persistent = true;
      Unit = "homepage-canary.service";
    };
  };

  systemd.tmpfiles.rules = [
    "d ${stateDir} 0750 ${canaryUser} ${canaryGroup} -"
    "d ${stateDir}/failures 0750 ${canaryUser} ${canaryGroup} 14d"
  ];

  security.sudo.extraRules = [
    {
      users = [ "homepage" ];
      commands = [{ command = "${trigger}"; options = [ "NOPASSWD" ]; }];
    }
  ];

  systemd.services.homepage.environment = {
    HOMEPAGE_CANARY_ADMIN_USER = vars.kanidmAdminUser;
    HOMEPAGE_CANARY_STATE_DIR = stateDir;
    HOMEPAGE_CANARY_TRIGGER_COMMAND = "${trigger}";
  };
  systemd.services.homepage.serviceConfig.ReadOnlyPaths = [ stateDir ];

}
