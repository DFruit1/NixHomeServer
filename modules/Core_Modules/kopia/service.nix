{ config, lib, oauth2Proxy, pkgs, vars, ... }:

let
  loopback = vars.networking.loopbackIPv4;
  kopiaPort = vars.networking.ports.kopia;
  kopiaAuthProxyPort = kopiaPort + 1;
  oauth2Port = vars.networking.ports.oauth2ProxyKopia;
  host = vars.kopiaDomain;
  stateDir = "/persist/appdata/kopia";
  configFile = "${stateDir}/repository.config";
  cacheDir = "${stateDir}/cache";
  logDir = "${stateDir}/logs";
  uiPreferencesFile = "${stateDir}/ui-preferences.json";
  backupRoot = vars.backupRoot or "${vars.dataRoot}/backups";
  repositoryPath = "${backupRoot}/kopia";
  snapshotSuccessMarker = "${backupRoot}/.kopia-last-snapshot-success.json";
  maintenanceLock = config.repo.backups.maintenanceLock;
  snapshotRoots = config.repo.backups.snapshotRoots;
  snapshotCommands = lib.concatMapStringsSep "\n"
    (root: ''
      kopia snapshot create \
        --no-progress \
        --description=${lib.escapeShellArg "${root} automatic snapshot"} \
        --tags=${lib.escapeShellArg "source:${lib.removePrefix "/" (lib.replaceStrings [ "/" ] [ "-" ] root)}"} \
        ${lib.escapeShellArg root}
    '')
    snapshotRoots;
  backupStorageAccessGroup = vars.backupAccess.storageGroup or "backup-admin";
  backupStorageAccessGid = vars.fileAccessPosixGids.${backupStorageAccessGroup};
  credentials = {
    serverPassword = "kopia-server-password";
  };
  commonPath = with pkgs; [
    acl
    coreutils
    findutils
    jq
    kopia
    util-linux
  ];
  kopiaAuthProxyCaddyfile = pkgs.writeText "kopia-auth-proxy.Caddyfile" ''
    {
      admin off
      auto_https off
    }

    http://:${toString kopiaAuthProxyPort} {
      bind ${loopback}
      reverse_proxy ${loopback}:${toString kopiaPort} {
        header_up Authorization "Basic {$KOPIA_BASIC_AUTH}"
      }
    }
  '';
in
{
  config = lib.mkMerge [
    {
      systemd.tmpfiles.rules = [
        "d ${stateDir} 0700 root root -"
        "d ${cacheDir} 0700 root root -"
        "d ${logDir} 0700 root root 14d"
        "d ${backupRoot} 0750 root ${toString backupStorageAccessGid} -"
      ];

      systemd.services.kopia-repository-bootstrap = {
        description = "Create or connect the local encrypted Kopia repository";
        wantedBy = [ "multi-user.target" ];
        wants = [
          "data-pool-layout.service"
          "kanidm-files-posix-groups.service"
        ];
        after = [
          "data-pool-layout.service"
          "kanidm-files-posix-groups.service"
        ];
        path = commonPath;
        serviceConfig = {
          Type = "oneshot";
          LoadCredential = [
            "${credentials.serverPassword}:${config.age.secrets.kopiaServerPassword.path}"
          ];
        };
        script = ''
          set -euo pipefail

          password="$(tr -d '\r\n' < "$CREDENTIALS_DIRECTORY/${credentials.serverPassword}")"
          export KOPIA_CHECK_FOR_UPDATES=false
          export KOPIA_PASSWORD="$password"
          export KOPIA_CONFIG_PATH=${lib.escapeShellArg configFile}
          export KOPIA_CACHE_DIRECTORY=${lib.escapeShellArg cacheDir}

          install -d -m 0700 ${lib.escapeShellArg stateDir} ${lib.escapeShellArg cacheDir} ${lib.escapeShellArg logDir}
          install -d -m 0750 -o root -g ${lib.escapeShellArg (toString backupStorageAccessGid)} ${lib.escapeShellArg backupRoot} ${lib.escapeShellArg repositoryPath}

          if [[ -f ${lib.escapeShellArg configFile} ]]; then
            storage_type="$(jq -r '.storage.type // empty' ${lib.escapeShellArg configFile} 2>/dev/null || true)"
            storage_path="$(jq -r '.storage.config.path // .storage.path // empty' ${lib.escapeShellArg configFile} 2>/dev/null || true)"
            if [[ "$storage_type" != "filesystem" || "$storage_path" != ${lib.escapeShellArg repositoryPath} ]]; then
              mv ${lib.escapeShellArg configFile} ${lib.escapeShellArg configFile}."legacy-$(date -u +%Y%m%dT%H%M%SZ)"
            fi
          fi

          if [[ ! -f ${lib.escapeShellArg configFile} ]]; then
            if [[ -f ${lib.escapeShellArg repositoryPath}/kopia.repository.f ]]; then
              kopia repository connect filesystem \
                --path=${lib.escapeShellArg repositoryPath} \
                --config-file=${lib.escapeShellArg configFile} \
                --cache-directory=${lib.escapeShellArg cacheDir} \
                --password="$password" \
                --persist-credentials \
                --no-use-keyring
            else
              kopia repository create filesystem \
                --path=${lib.escapeShellArg repositoryPath} \
                --config-file=${lib.escapeShellArg configFile} \
                --cache-directory=${lib.escapeShellArg cacheDir} \
                --password="$password" \
                --persist-credentials \
                --no-use-keyring \
                --description="NixHomeServer /persist backup repository" \
                --owner-uid=0 \
                --owner-gid=${lib.escapeShellArg (toString backupStorageAccessGid)} \
                --file-mode=0640 \
                --dir-mode=0750
            fi
          fi

          chown root:${lib.escapeShellArg (toString backupStorageAccessGid)} ${lib.escapeShellArg backupRoot} ${lib.escapeShellArg repositoryPath}
          chmod 0750 ${lib.escapeShellArg backupRoot} ${lib.escapeShellArg repositoryPath}
          setfacl -m g:${lib.escapeShellArg (toString backupStorageAccessGid)}:r-x,d:g:${lib.escapeShellArg (toString backupStorageAccessGid)}:r-x ${lib.escapeShellArg backupRoot} ${lib.escapeShellArg repositoryPath}

          kopia policy set --global \
            --keep-latest=7 \
            --keep-hourly=0 \
            --keep-daily=14 \
            --keep-weekly=4 \
            --keep-monthly=2 \
            --keep-annual=0 \
            --ignore-cache-dirs=true \
            --add-ignore='appdata/kopia/cache' \
            --add-ignore='appdata/kopia/logs' \
            --add-ignore='appdata/system-state-backup' \
            --add-ignore='backups/pool-migration' \
            --add-ignore='backups/restic' \
            --add-ignore='home/*/.cache' \
            --add-ignore='var/cache' \
            --add-ignore='var/lib/immich-public-proxy' \
            --add-ignore='var/lib/jellyfin/log' \
            --add-ignore='var/lib/kavita/config/logs' \
            --add-ignore='var/lib/metube' \
            --add-ignore='var/lib/paperless/log' \
            --add-ignore='var/lib/seerr/logs' \
            --add-ignore='var/log'
        '';
      };

      systemd.services.kopia = {
        description = "Kopia backup-management web UI";
        wantedBy = [ "multi-user.target" ];
        requires = [ "kopia-repository-bootstrap.service" ];
        wants = [
          "kopia-repository-bootstrap.service"
          "network-online.target"
        ];
        after = [
          "kopia-repository-bootstrap.service"
          "network-online.target"
        ];
        path = commonPath;
        serviceConfig = {
          Type = "simple";
          LoadCredential = [
            "${credentials.serverPassword}:${config.age.secrets.kopiaServerPassword.path}"
          ];
          ExecStart = pkgs.writeShellScript "kopia-server-start" ''
            set -euo pipefail

            export KOPIA_CHECK_FOR_UPDATES=false
            export KOPIA_SERVER_USERNAME=kopia-admin
            export KOPIA_SERVER_PASSWORD="$(tr -d '\r\n' < "$CREDENTIALS_DIRECTORY/${credentials.serverPassword}")"
            export KOPIA_PASSWORD="$KOPIA_SERVER_PASSWORD"
            export KOPIA_CONFIG_PATH=${lib.escapeShellArg configFile}
            export KOPIA_CACHE_DIRECTORY=${lib.escapeShellArg cacheDir}

            install -d -m 0700 ${lib.escapeShellArg stateDir} ${lib.escapeShellArg cacheDir} ${lib.escapeShellArg logDir}

            exec ${pkgs.kopia}/bin/kopia server start \
              --insecure \
              --ui \
              --address=http://${loopback}:${toString kopiaPort} \
              --log-dir=${lib.escapeShellArg logDir} \
              --ui-preferences-file=${lib.escapeShellArg uiPreferencesFile}
          '';
          Restart = "on-failure";
          RestartSec = 5;
          NoNewPrivileges = true;
          PrivateTmp = true;
          RestrictAddressFamilies = [
            "AF_INET"
            "AF_INET6"
            "AF_UNIX"
          ];
        };
      };

      systemd.services.kopia-persist-snapshot = {
        description = "Prepare data and create encrypted Kopia snapshots";
        requires = [ "backup-prepare.service" ];
        wants = [ "kopia-repository-bootstrap.service" ];
        after = [ "backup-prepare.service" "kopia-repository-bootstrap.service" ];
        path = commonPath;
        serviceConfig = {
          Type = "oneshot";
          LoadCredential = [
            "${credentials.serverPassword}:${config.age.secrets.kopiaServerPassword.path}"
          ];
          MemoryHigh = "1G";
          MemoryMax = "2G";
          CPUWeight = 20;
          IOWeight = 20;
          Nice = 10;
          IOSchedulingClass = "best-effort";
          IOSchedulingPriority = 7;
        };
        script = ''
          set -euo pipefail

          password="$(tr -d '\r\n' < "$CREDENTIALS_DIRECTORY/${credentials.serverPassword}")"
          export KOPIA_CHECK_FOR_UPDATES=false
          export KOPIA_PASSWORD="$password"
          export KOPIA_CONFIG_PATH=${lib.escapeShellArg configFile}
          export KOPIA_CACHE_DIRECTORY=${lib.escapeShellArg cacheDir}

          exec 9>${lib.escapeShellArg maintenanceLock}
          flock -n 9 || { echo "Another maintenance job is active" >&2; exit 75; }
          manifest=${lib.escapeShellArg config.repo.backups.successfulStagingRoot}/metadata/manifest.json
          [[ -s "$manifest" ]] || { echo "Backup preparation manifest is missing" >&2; exit 1; }
          ${snapshotCommands}
          printf '{"completedAt":"%s"}\n' "$(date --utc --iso-8601=seconds)" \
            > ${lib.escapeShellArg snapshotSuccessMarker}
          chown root:${lib.escapeShellArg (toString backupStorageAccessGid)} ${lib.escapeShellArg snapshotSuccessMarker}
          chmod 0640 ${lib.escapeShellArg snapshotSuccessMarker}
        '';
      };

      systemd.services.kopia-full-maintenance = {
        description = "Run weekly full Kopia repository maintenance";
        wants = [ "kopia-repository-bootstrap.service" ];
        after = [ "kopia-repository-bootstrap.service" ];
        path = commonPath;
        serviceConfig = {
          Type = "oneshot";
          LoadCredential = [ "${credentials.serverPassword}:${config.age.secrets.kopiaServerPassword.path}" ];
          MemoryHigh = "1G";
          MemoryMax = "2G";
          Nice = 15;
          CPUWeight = 10;
          IOWeight = 10;
          IOSchedulingClass = "best-effort";
          IOSchedulingPriority = 7;
        };
        script = ''
          set -euo pipefail
          export KOPIA_CHECK_FOR_UPDATES=false
          export KOPIA_PASSWORD="$(tr -d '\r\n' < "$CREDENTIALS_DIRECTORY/${credentials.serverPassword}")"
          export KOPIA_CONFIG_PATH=${lib.escapeShellArg configFile}
          export KOPIA_CACHE_DIRECTORY=${lib.escapeShellArg cacheDir}
          exec 9>${lib.escapeShellArg maintenanceLock}
          flock -n 9 || { echo "Another maintenance job is active" >&2; exit 75; }
          exec kopia maintenance run --full --no-progress
        '';
      };

      systemd.timers.kopia-full-maintenance = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = "Sun *-*-* 01:00:00";
          Persistent = true;
          RandomizedDelaySec = "1h";
          Unit = "kopia-full-maintenance.service";
        };
      };

      systemd.timers.kopia-persist-snapshot = {
        description = "Daily encrypted Kopia snapshot of /persist";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = "*-*-* 03:15:00";
          Persistent = true;
          RandomizedDelaySec = "30m";
          Unit = "kopia-persist-snapshot.service";
        };
      };

      systemd.services.kopia-auth-proxy = {
        description = "Local Kopia Basic Auth injection proxy";
        wantedBy = [ "multi-user.target" ];
        requires = [ "kopia.service" ];
        after = [ "kopia.service" ];
        serviceConfig = {
          Type = "simple";
          LoadCredential = [
            "${credentials.serverPassword}:${config.age.secrets.kopiaServerPassword.path}"
          ];
          ExecStart = pkgs.writeShellScript "kopia-auth-proxy-start" ''
            set -euo pipefail

            password="$(tr -d '\r\n' < "$CREDENTIALS_DIRECTORY/${credentials.serverPassword}")"
            export KOPIA_BASIC_AUTH="$(printf 'kopia-admin:%s' "$password" | ${pkgs.coreutils}/bin/base64 --wrap=0)"

            exec ${pkgs.caddy}/bin/caddy run --config ${kopiaAuthProxyCaddyfile}
          '';
          Restart = "on-failure";
          RestartSec = 5;
          NoNewPrivileges = true;
          PrivateTmp = true;
          RestrictAddressFamilies = [
            "AF_INET"
            "AF_INET6"
            "AF_UNIX"
          ];
        };
      };
    }

    (oauth2Proxy.mkSidecarService {
      serviceName = "kopia-oauth2-proxy";
      description = "Dedicated OAuth2 Proxy for Kopia";
      clientId = "kopia-web";
      clientSecretFile = config.age.secrets.kopiaOauth2ProxyClientSecret.path;
      cookieSecretFile = config.age.secrets.kopiaOauth2ProxyCookieSecret.path;
      cookieName = "_oauth2_proxy_kopia";
      domain = host;
      port = oauth2Port;
      upstream = "http://${loopback}:${toString kopiaAuthProxyPort}";
      allowedGroups = [ vars.backupAccess.adminGroup ];
      serviceDependencies = [
        "caddy.service"
        "kopia.service"
        "kopia-auth-proxy.service"
      ];
      upstreamCheck = {
        displayName = "Kopia";
        url = "http://${loopback}:${toString kopiaAuthProxyPort}/";
        okStatusCodes = [
          "200"
        ];
      };
    })
  ];
}
