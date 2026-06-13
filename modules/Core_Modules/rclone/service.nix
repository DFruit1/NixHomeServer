{ config, lib, oauth2Proxy, pkgs, vars, ... }:

let
  serviceUser = "rclone";
  serviceGroup = "rclone";
  loopback = vars.networking.loopbackIPv4;
  rcPort = vars.networking.ports.rcloneRc;
  oauth2Port = vars.networking.ports.oauth2ProxyRclone;
  host = vars.rcloneDomain;
  stateDir = "/var/lib/rclone";
  configDir = "${stateDir}/.config/rclone";
  cacheDir = "${stateDir}/.cache/rclone";
  runtimeDir = "/run/rclone";
  configFile = "${runtimeDir}/rclone.conf";
  backupRoot = vars.backupRoot or "${vars.dataRoot}/backups";
  kopiaRepositoryPath = "${backupRoot}/kopia";
  backupStorageAccessGroup = vars.backupAccess.storageGroup or "backup-admin";
  backupStorageAccessGid = vars.fileAccessPosixGids.${backupStorageAccessGroup};
  megaCfg = vars.rcloneMega or { };
  megaEnabled = megaCfg.enable or false;
  megaRemoteName = megaCfg.remoteName or "mega";
  megaEmail = megaCfg.email or "";
  megaSource = megaCfg.sourcePath or kopiaRepositoryPath;
  megaDestination = megaCfg.destination or "${megaRemoteName}:NixHomeServer/kopia";
  megaSyncOnCalendar = megaCfg.syncOnCalendar or "*-*-* 04:30:00";
  megaRandomizedDelaySec = megaCfg.randomizedDelaySec or "30m";
  megaTransfers = megaCfg.transfers or 4;
  megaCheckers = megaCfg.checkers or 8;
  megaConfigCredential = "mega-password";
  rcUrl = "http://${loopback}:${toString rcPort}";
  startScript = pkgs.writeShellScript "rclone-rcd-start" ''
    set -euo pipefail

    exec ${pkgs.rclone}/bin/rclone rcd \
      --config ${lib.escapeShellArg configFile} \
      --cache-dir ${lib.escapeShellArg cacheDir} \
      --rc-addr ${lib.escapeShellArg "${loopback}:${toString rcPort}"} \
      --rc-no-auth \
      --rc-web-gui \
      --rc-web-gui-no-open-browser \
      --fast-list \
      --transfers ${toString megaTransfers} \
      --checkers ${toString megaCheckers} \
      --stats 30s
  '';
in
{
  config = lib.mkMerge [
    {
      users.groups.${serviceGroup} = { };
      users.groups.${backupStorageAccessGroup}.gid = lib.mkDefault backupStorageAccessGid;

      users.users.${serviceUser} = {
        isSystemUser = true;
        group = serviceGroup;
        home = stateDir;
        createHome = true;
      };

      environment.systemPackages = [ pkgs.rclone ];

      systemd.tmpfiles.rules = [
        "d ${stateDir} 0700 ${serviceUser} ${serviceGroup} -"
        "d ${configDir} 0700 ${serviceUser} ${serviceGroup} -"
        "d ${cacheDir} 0700 ${serviceUser} ${serviceGroup} -"
        "d ${runtimeDir} 0750 ${serviceUser} ${serviceGroup} -"
      ];

      systemd.services.rclone = {
        description = "Rclone remote-control Web GUI";
        wantedBy = [ "multi-user.target" ];
        wants = [ "network-online.target" ];
        after = [ "network-online.target" ];
        serviceConfig = {
          Type = "simple";
          User = serviceUser;
          Group = serviceGroup;
          SupplementaryGroups = [ backupStorageAccessGroup ];
          Environment = [
            "HOME=${stateDir}"
            "XDG_CONFIG_HOME=${stateDir}/.config"
            "XDG_CACHE_HOME=${stateDir}/.cache"
          ];
          ExecStart = startScript;
          Restart = "on-failure";
          RestartSec = 5;
          NoNewPrivileges = true;
          PrivateTmp = true;
          ProtectSystem = "strict";
          ProtectHome = true;
          ReadWritePaths = [
            stateDir
            runtimeDir
          ];
          ReadOnlyPaths = [ backupRoot ];
          RestrictAddressFamilies = [
            "AF_INET"
            "AF_INET6"
            "AF_UNIX"
          ];
        };
      };
    }

    (lib.mkIf megaEnabled {
      assertions = [
        {
          assertion = megaEmail != "" && !(lib.hasPrefix "REPLACE_" megaEmail);
          message = "vars.rcloneMega.email must be set to the MEGA account email before enabling declarative MEGA sync.";
        }
      ];

      systemd.services.rclone-mega-config = {
        description = "Render declarative Rclone MEGA configuration";
        before = [ "rclone.service" ];
        wantedBy = [ "multi-user.target" ];
        path = with pkgs; [
          coreutils
          rclone
        ];
        serviceConfig = {
          Type = "oneshot";
          LoadCredential = [
            "${megaConfigCredential}:${config.age.secrets.rcloneMegaPassword.path}"
          ];
          RemainAfterExit = true;
        };
        script = ''
          set -euo pipefail

          password="$(tr -d '\r\n' < "$CREDENTIALS_DIRECTORY/${megaConfigCredential}")"
          obscured_password="$(rclone obscure "$password")"
          temp_config="$(mktemp)"

          {
            printf '[%s]\n' ${lib.escapeShellArg megaRemoteName}
            printf 'type = mega\n'
            printf 'user = %s\n' ${lib.escapeShellArg megaEmail}
            printf 'pass = %s\n' "$obscured_password"
          } > "$temp_config"

          install -d -m 0750 -o ${lib.escapeShellArg serviceUser} -g ${lib.escapeShellArg serviceGroup} ${lib.escapeShellArg runtimeDir}
          install -m 0400 -o ${lib.escapeShellArg serviceUser} -g ${lib.escapeShellArg serviceGroup} "$temp_config" ${lib.escapeShellArg configFile}
          rm -f "$temp_config"
        '';
      };

      systemd.services.rclone = {
        requires = [ "rclone-mega-config.service" ];
        after = [ "rclone-mega-config.service" ];
      };

      systemd.services.rclone-mega-kopia-sync = {
        description = "Sync encrypted Kopia repository to MEGA with Rclone";
        requires = [ "rclone.service" ];
        wants = [
          "kopia-repository-bootstrap.service"
          "network-online.target"
        ];
        after = [
          "rclone.service"
          "kopia-repository-bootstrap.service"
          "network-online.target"
        ];
        path = with pkgs; [
          coreutils
          jq
          rclone
        ];
        serviceConfig = {
          Type = "oneshot";
          User = serviceUser;
          Group = serviceGroup;
          SupplementaryGroups = [ backupStorageAccessGroup ];
          Nice = 10;
          IOSchedulingClass = "best-effort";
          IOSchedulingPriority = 7;
        };
        script = ''
          set -euo pipefail

          for attempt in $(seq 1 30); do
            if rclone rc --url ${lib.escapeShellArg rcUrl} core/version >/dev/null 2>&1; then
              break
            fi
            if [[ "$attempt" -eq 30 ]]; then
              echo "rclone rc endpoint did not become ready" >&2
              exit 1
            fi
            sleep 2
          done

          job_json="$(
            rclone rc --url ${lib.escapeShellArg rcUrl} sync/sync \
              srcFs=${lib.escapeShellArg megaSource} \
              dstFs=${lib.escapeShellArg megaDestination} \
              createEmptySrcDirs=true \
              _async=true
          )"
          job_id="$(jq -r '.jobid' <<<"$job_json")"

          if [[ -z "$job_id" || "$job_id" == "null" ]]; then
            echo "rclone rc did not return a job id: $job_json" >&2
            exit 1
          fi

          while true; do
            status_json="$(rclone rc --url ${lib.escapeShellArg rcUrl} job/status jobid="$job_id")"
            finished="$(jq -r '.finished' <<<"$status_json")"

            if [[ "$finished" == "true" ]]; then
              success="$(jq -r '.success' <<<"$status_json")"
              if [[ "$success" == "true" ]]; then
                exit 0
              fi

              error="$(jq -r '.error // "rclone sync job failed"' <<<"$status_json")"
              echo "$error" >&2
              exit 1
            fi

            sleep 30
          done
        '';
      };

      systemd.timers.rclone-mega-kopia-sync = {
        description = "Regular offsite sync of encrypted Kopia repository to MEGA";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = megaSyncOnCalendar;
          Persistent = true;
          RandomizedDelaySec = megaRandomizedDelaySec;
          Unit = "rclone-mega-kopia-sync.service";
        };
      };
    })

    (oauth2Proxy.mkSidecarService {
      serviceName = "rclone-oauth2-proxy";
      description = "Dedicated OAuth2 Proxy for Rclone";
      clientId = "rclone-web";
      clientSecretFile = config.age.secrets.rcloneOauth2ProxyClientSecret.path;
      cookieSecretFile = config.age.secrets.rcloneOauth2ProxyCookieSecret.path;
      cookieName = "_oauth2_proxy_rclone";
      domain = host;
      port = oauth2Port;
      upstream = "http://${loopback}:${toString rcPort}";
      allowedGroups = [ vars.backupAccess.adminGroup ];
      serviceDependencies = [
        "caddy.service"
        "rclone.service"
      ];
      upstreamCheck = {
        displayName = "Rclone";
        url = "http://${loopback}:${toString rcPort}/";
        okStatusCodes = [
          "200"
        ];
      };
    })
  ];
}
