{ config, lib, oauth2Proxy, pkgs, vars, ... }:

let
  loopback = vars.networking.loopbackIPv4;
  kopiaPortRaw = vars.networking.ports.kopia;
  kopiaPort = if builtins.isInt kopiaPortRaw then kopiaPortRaw else -1;
  # Keep module evaluation total for malformed user input so the central
  # validation module can report the actionable port-range/type assertion.
  kopiaAuthProxyPort = if builtins.isInt kopiaPortRaw then kopiaPortRaw + 1 else -1;
  oauth2Port = vars.networking.ports.oauth2ProxyKopia;
  host = vars.kopiaDomain;
  stateDir = "/persist/appdata/kopia";
  configFile = "${stateDir}/repository.config";
  cacheDir = "${stateDir}/cache";
  logDir = "${stateDir}/logs";
  uiPreferencesFile = "${stateDir}/ui-preferences.json";
  backupRoot = vars.backupRoot or "${vars.dataRoot}/backups";
  repositoryPath = "${backupRoot}/kopia";
  repositoryOwnershipMarker = "${backupRoot}/.nixhomeserver-kopia-repository.json";
  snapshotSuccessMarker = "${backupRoot}/.kopia-last-snapshot-success.json";
  snapshotHealthMaxAgeSeconds = config.repo.backups.kopiaSnapshotHealthMaxAgeSeconds;
  freshnessMarkerCheck = pkgs.writeShellScript "check-freshness-marker"
    (builtins.readFile ../../../scripts/helpers/check-freshness-marker.sh);
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
  backupStorageAccessGroup = vars.backupStorageGroup;
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
  kopiaCliWrapper = pkgs.writeShellScript "nixhomeserver-kopia" ''
    set -euo pipefail

    if (( EUID != 0 )); then
      echo "nixhomeserver-kopia must be run as root (for example, with sudo)." >&2
      exit 77
    fi

    secret_file=${lib.escapeShellArg config.age.secrets.kopiaServerPassword.path}
    config_file=${lib.escapeShellArg configFile}
    cache_dir=${lib.escapeShellArg cacheDir}
    [[ -r "$secret_file" ]] || { echo "Kopia password secret is unavailable at $secret_file" >&2; exit 1; }
    [[ -s "$config_file" ]] || { echo "Managed Kopia repository config is unavailable at $config_file" >&2; exit 1; }

    umask 0077
    export KOPIA_CHECK_FOR_UPDATES=false
    KOPIA_PASSWORD="$(tr -d '\r\n' < "$secret_file")"
    export KOPIA_PASSWORD
    export KOPIA_CONFIG_PATH="$config_file"
    export KOPIA_CACHE_DIRECTORY="$cache_dir"
    exec ${pkgs.kopia}/bin/kopia "$@"
  '';
  requireDataRoot = lib.optionalString vars.dataRootIsMountPoint ''
    if ! ${pkgs.util-linux}/bin/mountpoint -q ${lib.escapeShellArg vars.dataRoot}; then
      echo "Refusing backup operation because ${vars.dataRoot} is not a mounted data pool" >&2
      exit 1
    fi
  '';
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
  options.repo.backups.kopiaSnapshotHealthMaxAgeSeconds = lib.mkOption {
    type = lib.types.ints.positive;
    default = 36 * 60 * 60;
    description = "Maximum age of the last successful encrypted Kopia snapshot before health checks fail.";
  };

  config = lib.mkMerge [
    {
      security.wrappers.nixhomeserver-kopia = {
        source = kopiaCliWrapper;
        owner = "root";
        group = "root";
        permissions = "0500";
      };

      systemd.tmpfiles.rules = [
        "d ${stateDir} 0700 root root -"
        "d ${cacheDir} 0700 root root -"
        "d ${logDir} 0700 root root 14d"
        "d ${backupRoot} 0750 root ${toString backupStorageAccessGid} -"
      ];

      systemd.services.kopia-repository-bootstrap = {
        description = "Create or connect the local encrypted Kopia repository";
        wantedBy = [ "multi-user.target" ];
        requires = [ "data-pool-layout.service" ];
        wants = [ "kanidm-files-posix-groups.service" ];
        after = [
          "data-pool-layout.service"
          "kanidm-files-posix-groups.service"
        ];
        path = commonPath;
        serviceConfig = {
          Type = "oneshot";
          Restart = "on-failure";
          RestartSec = "30s";
          LoadCredential = [
            "${credentials.serverPassword}:${config.age.secrets.kopiaServerPassword.path}"
          ];
        };
        script = ''
          set -euo pipefail
          ${requireDataRoot}

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
                --persist-credentials \
                --no-use-keyring
            else
              kopia repository create filesystem \
                --path=${lib.escapeShellArg repositoryPath} \
                --config-file=${lib.escapeShellArg configFile} \
                --cache-directory=${lib.escapeShellArg cacheDir} \
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

          ownership_marker_tmp=${lib.escapeShellArg repositoryOwnershipMarker}.tmp
          repository_fingerprint="$(sha256sum ${lib.escapeShellArg "${repositoryPath}/kopia.repository.f"} | cut -d ' ' -f 1)"
          jq -n \
            --arg repositoryFingerprint "$repository_fingerprint" \
            --arg repositoryPath ${lib.escapeShellArg repositoryPath} \
            '{schemaVersion: 1, repositoryFingerprint: $repositoryFingerprint, repositoryPath: $repositoryPath}' \
            > "$ownership_marker_tmp"
          chown root:${lib.escapeShellArg (toString backupStorageAccessGid)} "$ownership_marker_tmp"
          chmod 0640 "$ownership_marker_tmp"
          mv -f "$ownership_marker_tmp" ${lib.escapeShellArg repositoryOwnershipMarker}

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
        requires = [
          "backup-prepare.service"
          "data-pool-layout.service"
          "kopia-repository-bootstrap.service"
        ];
        after = [
          "backup-prepare.service"
          "data-pool-layout.service"
          "kopia-repository-bootstrap.service"
        ];
        unitConfig = {
          StartLimitIntervalSec = "2h";
          StartLimitBurst = 3;
        };
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
          TimeoutStartSec = "12h";
          Restart = "on-failure";
          RestartSec = "15min";
        };
        script = ''
          set -euo pipefail
          ${requireDataRoot}

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
          snapshot_marker_tmp="$(mktemp ${lib.escapeShellArg "${snapshotSuccessMarker}.XXXXXX"})"
          trap 'rm -f "$snapshot_marker_tmp"' EXIT
          jq -n --arg completedAt "$(date --utc --iso-8601=seconds)" \
            '{schemaVersion:1,completedAt:$completedAt}' > "$snapshot_marker_tmp"
          chown root:${lib.escapeShellArg (toString backupStorageAccessGid)} "$snapshot_marker_tmp"
          chmod 0640 "$snapshot_marker_tmp"
          mv -f "$snapshot_marker_tmp" ${lib.escapeShellArg snapshotSuccessMarker}
          trap - EXIT
        '';
      };

      systemd.services.kopia-snapshot-health = {
        description = "Verify encrypted Kopia snapshot freshness";
        requires = [
          "data-pool-layout.service"
          "kopia-repository-bootstrap.service"
        ];
        after = [
          "data-pool-layout.service"
          "kopia-persist-snapshot.service"
          "kopia-repository-bootstrap.service"
        ];
        unitConfig = lib.mkIf vars.dataRootIsMountPoint {
          ConditionPathIsMountPoint = vars.dataRoot;
        };
        path = [ pkgs.coreutils pkgs.jq ];
        serviceConfig.Type = "oneshot";
        script = ''
          set -euo pipefail
          ${requireDataRoot}
          now="$(date +%s)"
          marker=${lib.escapeShellArg snapshotSuccessMarker}
          repository_config=${lib.escapeShellArg configFile}
          age=-1
          state=missing
          fresh=false

          if [[ -s "$marker" ]]; then
            marker_health="$(
              FRESHNESS_MARKER_JQ_BIN=${lib.escapeShellArg "${pkgs.jq}/bin/jq"} \
                FRESHNESS_MARKER_DATE_BIN=${lib.escapeShellArg "${pkgs.coreutils}/bin/date"} \
                ${freshnessMarkerCheck} \
                  --marker "$marker" \
                  --max-age-seconds ${toString snapshotHealthMaxAgeSeconds}
            )" || {
              echo "Kopia snapshot success marker is invalid, stale, or future-dated: $marker" >&2
              exit 1
            }
            age="$(jq -er '.ageSeconds' <<<"$marker_health")"
            state=fresh
            fresh=true
          elif [[ -s "$repository_config" ]]; then
            repository_age=$((now - $(stat -c %Y "$repository_config")))
            if ((repository_age >= 0 && repository_age <= ${toString snapshotHealthMaxAgeSeconds})); then
              state=initializing
              fresh=true
            fi
          fi

          jq -n \
            --arg state "$state" \
            --arg marker "$marker" \
            --argjson ageSeconds "$age" \
            --argjson maxAgeSeconds ${toString snapshotHealthMaxAgeSeconds} \
            --argjson fresh "$fresh" \
            '{state:$state,marker:$marker,ageSeconds:$ageSeconds,maxAgeSeconds:$maxAgeSeconds,fresh:$fresh}'
          [[ "$fresh" == true ]]
        '';
      };

      systemd.timers.kopia-snapshot-health = {
        description = "Regularly verify encrypted Kopia snapshot freshness";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = "20min";
          OnUnitActiveSec = "1h";
          Persistent = true;
          Unit = "kopia-snapshot-health.service";
        };
      };

      systemd.services.kopia-full-maintenance = {
        description = "Run weekly full Kopia repository maintenance";
        requires = [ "kopia-repository-bootstrap.service" ];
        after = [ "kopia-repository-bootstrap.service" ];
        unitConfig = {
          StartLimitIntervalSec = "4h";
          StartLimitBurst = 3;
        };
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
          TimeoutStartSec = "12h";
          Restart = "on-failure";
          RestartSec = "30min";
        };
        script = ''
          set -euo pipefail
          ${requireDataRoot}
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
      allowedGroups = [ vars.backupAdminGroup ];
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
