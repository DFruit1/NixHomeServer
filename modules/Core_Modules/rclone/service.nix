{ config, lib, pkgs, vars, ... }:

let
  serviceUser = "rclone";
  serviceGroup = "rclone";
  stateDir = "/var/lib/rclone";
  cacheDir = "${stateDir}/.cache/rclone";
  runtimeDir = "/run/rclone";
  configFile = "${runtimeDir}/rclone.conf";
  backupRoot = vars.backupRoot or "${vars.dataRoot}/backups";
  backupStorageAccessGroup = vars.backupStorageGroup;
  backupStorageAccessGid = vars.fileAccessPosixGids.${backupStorageAccessGroup};
  megaCfgRaw = vars.rcloneMega or { };
  megaCfg = if builtins.isAttrs megaCfgRaw then megaCfgRaw else { };
  rcloneValidation = import ../../../lib/rclone-validation.nix { inherit lib; };
  megaEnabledRaw = megaCfg.enable or false;
  megaEnabled = builtins.isBool megaEnabledRaw && megaEnabledRaw;
  megaRemoteNameRaw = megaCfg.remoteName or "mega";
  megaRemoteName = if builtins.isString megaRemoteNameRaw then megaRemoteNameRaw else "invalid";
  megaEmailRaw = megaCfg.email or "";
  megaEmail = if builtins.isString megaEmailRaw then megaEmailRaw else "";
  megaSourceRaw = megaCfg.sourcePath or "${backupRoot}/kopia";
  megaSource = if builtins.isString megaSourceRaw then megaSourceRaw else "${backupRoot}/kopia";
  megaDestinationRaw = megaCfg.destination or "${megaRemoteName}:NixHomeServer/kopia";
  megaDestination =
    if builtins.isString megaDestinationRaw
    then megaDestinationRaw
    else "${megaRemoteName}:invalid";
  megaSyncOnCalendar = megaCfg.syncOnCalendar or "*-*-* 04:30:00";
  megaRandomizedDelaySec = megaCfg.randomizedDelaySec or "30m";
  megaTransfersRaw = megaCfg.transfers or 4;
  megaTransfers = if builtins.isInt megaTransfersRaw then megaTransfersRaw else 0;
  megaCheckersRaw = megaCfg.checkers or 8;
  megaCheckers = if builtins.isInt megaCheckersRaw then megaCheckersRaw else 0;
  megaWarnPercentRaw = megaCfg.warnPercent or 80;
  megaWarnPercent = if builtins.isInt megaWarnPercentRaw then megaWarnPercentRaw else 0;
  megaCriticalPercentRaw = megaCfg.criticalPercent or 90;
  megaCriticalPercent = if builtins.isInt megaCriticalPercentRaw then megaCriticalPercentRaw else 0;
  megaRepositoryLimitBytesRaw = megaCfg.repositoryLimitBytes or 19327352832;
  megaRepositoryLimitBytes =
    if builtins.isInt megaRepositoryLimitBytesRaw
    then megaRepositoryLimitBytesRaw
    else 0;
  megaConfigCredential = "mega-password";
  maintenanceLock = config.repo.backups.maintenanceLock;
  maintenanceGroup = config.repo.backups.maintenanceGroup;
  snapshotSuccessMarker = "${backupRoot}/.kopia-last-snapshot-success.json";
  snapshotHealthMaxAgeSeconds = config.repo.backups.kopiaSnapshotHealthMaxAgeSeconds;
  freshnessMarkerCheck = pkgs.writeShellScript "check-freshness-marker"
    (builtins.readFile ../../../scripts/helpers/check-freshness-marker.sh);
  repositoryOwnershipMarker = "${backupRoot}/.nixhomeserver-kopia-repository.json";
  remoteOwnershipMarkerName = ".nixhomeserver-rclone-owner.json";
  remoteOwnershipMarker = "${megaDestination}/${remoteOwnershipMarkerName}";
  syncSuccessMarker = "${stateDir}/last-mega-sync-success.json";
  requireDataRoot = lib.optionalString vars.dataRootIsMountPoint ''
    if ! ${pkgs.util-linux}/bin/mountpoint -q ${lib.escapeShellArg vars.dataRoot}; then
      echo "Refusing offsite sync because ${vars.dataRoot} is not a mounted data pool" >&2
      exit 1
    fi
  '';
  capacityCheck = pkgs.writeShellScript "rclone-mega-capacity-check" ''
    set -euo pipefail
    quota="$(${pkgs.rclone}/bin/rclone about \
      --config ${lib.escapeShellArg configFile} \
      --json ${lib.escapeShellArg "${megaRemoteName}:"})"
    total="$(${pkgs.jq}/bin/jq -r '.total // 0' <<<"$quota")"
    used="$(${pkgs.jq}/bin/jq -r '.used // 0' <<<"$quota")"
    free="$(${pkgs.jq}/bin/jq -r '.free // 0' <<<"$quota")"
    repository_bytes="$(${pkgs.coreutils}/bin/du --summarize --bytes ${lib.escapeShellArg megaSource} | ${pkgs.coreutils}/bin/cut -f1)"
    (( total > 0 )) || { echo "MEGA did not report a usable quota" >&2; exit 1; }
    used_percent=$(( used * 100 / total ))
    message="MEGA quota: $used_percent% used ($used/$total bytes, $free free); local Kopia repository: $repository_bytes bytes"
    if (( used_percent >= ${toString megaCriticalPercent} || repository_bytes >= ${toString megaRepositoryLimitBytes} )); then
      ${pkgs.systemd}/bin/systemd-cat --identifier=backup-capacity --priority=err <<<"CRITICAL: $message"
      echo "CRITICAL: $message" >&2
      exit 1
    fi
    if (( used_percent >= ${toString megaWarnPercent} )); then
      ${pkgs.systemd}/bin/systemd-cat --identifier=backup-capacity --priority=warning <<<"WARNING: $message"
    else
      echo "$message"
    fi
  '';
in
{
  config = lib.mkMerge [
    {
      assertions = [
        {
          assertion = builtins.isAttrs megaCfgRaw;
          message = "vars.rcloneMega must be an attribute set.";
        }
        {
          assertion = builtins.isBool megaEnabledRaw;
          message = "vars.rcloneMega.enable must be true or false.";
        }
      ];
    }
    (lib.mkIf megaEnabled {
      assertions = [
        {
          assertion = builtins.isString megaEmailRaw && megaEmailRaw != "" && !(lib.hasPrefix "REPLACE_" megaEmailRaw);
          message = "vars.rcloneMega.email must be set before enabling MEGA sync.";
        }
        {
          assertion = rcloneValidation.validRemoteName megaRemoteNameRaw;
          message = "vars.rcloneMega.remoteName must be a simple Rclone remote name.";
        }
        {
          assertion = rcloneValidation.validDestination megaRemoteNameRaw megaDestinationRaw;
          message = "vars.rcloneMega.destination must be a non-root path below the configured MEGA remote without dot segments.";
        }
        {
          assertion = builtins.isString megaSourceRaw && megaSourceRaw == "${backupRoot}/kopia";
          message = "vars.rcloneMega.sourcePath must remain the managed encrypted Kopia repository at ${backupRoot}/kopia.";
        }
        {
          assertion =
            builtins.isInt megaTransfersRaw
            && megaTransfersRaw > 0
            && megaTransfersRaw <= 32
            && builtins.isInt megaCheckersRaw
            && megaCheckersRaw > 0
            && megaCheckersRaw <= 64;
          message = "vars.rcloneMega transfers/checkers must be positive and no greater than 32/64 respectively.";
        }
        {
          assertion =
            builtins.isInt megaWarnPercentRaw
            && megaWarnPercentRaw > 0
            && builtins.isInt megaCriticalPercentRaw
            && megaWarnPercentRaw < megaCriticalPercentRaw
            && megaCriticalPercentRaw <= 100
            && builtins.isInt megaRepositoryLimitBytesRaw
            && megaRepositoryLimitBytesRaw > 0;
          message = "vars.rcloneMega quota thresholds and repositoryLimitBytes must be positive, ordered, and bounded.";
        }
      ];

      users.groups.${serviceGroup} = { };
      users.groups.${backupStorageAccessGroup}.gid = lib.mkDefault backupStorageAccessGid;
      users.users.${serviceUser} = {
        isSystemUser = true;
        group = serviceGroup;
        extraGroups = [
          backupStorageAccessGroup
          maintenanceGroup
        ];
        home = stateDir;
        createHome = true;
      };

      environment.systemPackages = [ pkgs.rclone ];
      systemd.tmpfiles.rules = [
        "d ${stateDir} 0700 ${serviceUser} ${serviceGroup} -"
        "d ${cacheDir} 0700 ${serviceUser} ${serviceGroup} -"
        "d ${runtimeDir} 0750 ${serviceUser} ${serviceGroup} -"
      ];

      systemd.services.rclone-mega-config = {
        description = "Render declarative Rclone MEGA configuration";
        wantedBy = [ "multi-user.target" ];
        path = with pkgs; [ coreutils rclone ];
        serviceConfig = {
          Type = "oneshot";
          LoadCredential = [ "${megaConfigCredential}:${config.age.secrets.rcloneMegaPassword.path}" ];
          RemainAfterExit = true;
        };
        script = ''
          set -euo pipefail
          password="$(tr -d '\r\n' < "$CREDENTIALS_DIRECTORY/${megaConfigCredential}")"
          obscured_password="$(rclone obscure --config /dev/null "$password")"
          temp_config="$(mktemp)"
          trap 'rm -f "$temp_config"' EXIT
          {
            printf '[%s]\n' ${lib.escapeShellArg megaRemoteName}
            printf 'type = mega\n'
            printf 'user = %s\n' ${lib.escapeShellArg megaEmail}
            printf 'pass = %s\n' "$obscured_password"
          } > "$temp_config"
          install -d -m 0750 -o ${serviceUser} -g ${serviceGroup} ${runtimeDir}
          install -m 0400 -o ${serviceUser} -g ${serviceGroup} "$temp_config" ${configFile}
        '';
      };

      systemd.services.rclone-mega-kopia-sync = {
        description = "Sync encrypted Kopia repository to MEGA with Rclone";
        unitConfig = {
          OnSuccess = [ "rclone-mega-capacity-check.service" ];
          StartLimitIntervalSec = "6h";
          StartLimitBurst = 6;
        };
        requires = [
          "data-pool-layout.service"
          "kopia-repository-bootstrap.service"
          "rclone-mega-config.service"
        ];
        wants = [ "network-online.target" ];
        after = [
          "data-pool-layout.service"
          "kopia-full-maintenance.service"
          "kopia-persist-snapshot.service"
          "kopia-repository-bootstrap.service"
          "network-online.target"
          "rclone-mega-config.service"
        ];
        serviceConfig = {
          Type = "oneshot";
          User = serviceUser;
          Group = serviceGroup;
          SupplementaryGroups = [
            backupStorageAccessGroup
            maintenanceGroup
          ];
          Environment = [ "HOME=${stateDir}" "XDG_CACHE_HOME=${stateDir}/.cache" ];
          Nice = 10;
          CPUWeight = 20;
          IOWeight = 20;
          IOSchedulingClass = "best-effort";
          IOSchedulingPriority = 7;
          TimeoutStartSec = "12h";
          Restart = "on-failure";
          RestartSec = "30min";
          ExecStartPre = "+${pkgs.systemd}/bin/systemctl stop kopia.service";
          ExecStopPost = "+${pkgs.systemd}/bin/systemctl start kopia.service";
        };
        script = ''
          set -euo pipefail
          ${requireDataRoot}
          expected_source=${lib.escapeShellArg megaSource}
          ownership_marker=${lib.escapeShellArg repositoryOwnershipMarker}
          [[ -f ${lib.escapeShellArg "${megaSource}/kopia.repository.f"} ]] || {
            echo "Managed Kopia repository marker is missing from $expected_source; refusing destructive offsite sync" >&2
            exit 1
          }
          [[ -s "$ownership_marker" ]] || {
            echo "Kopia ownership marker is missing; refusing destructive offsite sync" >&2
            exit 1
          }
          expected_fingerprint="$(${pkgs.jq}/bin/jq -er \
            --arg source "$expected_source" \
            'select(.schemaVersion == 1 and .repositoryPath == $source and (.repositoryFingerprint | test("^[0-9a-f]{64}$"))) | .repositoryFingerprint' \
            "$ownership_marker")" || {
            echo "Kopia ownership marker does not identify the managed repository; refusing sync" >&2
            exit 1
          }
          actual_fingerprint="$(${pkgs.coreutils}/bin/sha256sum ${lib.escapeShellArg "${megaSource}/kopia.repository.f"} \
            | ${pkgs.coreutils}/bin/cut -d ' ' -f 1)"
          [[ "$actual_fingerprint" == "$expected_fingerprint" ]] || {
            echo "Kopia repository identity differs from its root-owned marker; refusing sync" >&2
            exit 1
          }
          success_marker=${lib.escapeShellArg snapshotSuccessMarker}
          [[ -s "$success_marker" ]] || { echo "No successful Kopia snapshot marker; refusing MEGA sync" >&2; exit 1; }
          FRESHNESS_MARKER_JQ_BIN=${lib.escapeShellArg "${pkgs.jq}/bin/jq"} \
            FRESHNESS_MARKER_DATE_BIN=${lib.escapeShellArg "${pkgs.coreutils}/bin/date"} \
            ${freshnessMarkerCheck} \
              --marker "$success_marker" \
              --max-age-seconds ${toString snapshotHealthMaxAgeSeconds} \
              >/dev/null || {
            echo "Latest successful Kopia snapshot marker is invalid, stale, or future-dated; refusing MEGA sync" >&2
            exit 1
          }
          repository_bytes="$(${pkgs.coreutils}/bin/du --summarize --bytes ${lib.escapeShellArg megaSource} | ${pkgs.coreutils}/bin/cut -f1)"
          if (( repository_bytes >= ${toString megaRepositoryLimitBytes} )); then
            echo "Local Kopia repository is $repository_bytes bytes; refusing MEGA upload at the ${toString megaRepositoryLimitBytes}-byte safety ceiling" >&2
            exit 1
          fi
          exec 9>${lib.escapeShellArg maintenanceLock}
          ${pkgs.util-linux}/bin/flock -n 9 || { echo "Another maintenance job is active" >&2; exit 75; }

          remote_marker_json="$(${pkgs.rclone}/bin/rclone cat \
            --config ${lib.escapeShellArg configFile} \
            ${lib.escapeShellArg remoteOwnershipMarker} 2>/dev/null || true)"
          if [[ -n "$remote_marker_json" ]]; then
            ${pkgs.jq}/bin/jq -e \
              --arg repositoryFingerprint "$expected_fingerprint" \
              --arg destination ${lib.escapeShellArg megaDestination} \
              '.schemaVersion == 1 and .repositoryFingerprint == $repositoryFingerprint and .destination == $destination' \
              <<<"$remote_marker_json" >/dev/null || {
              echo "Remote ownership marker does not identify this repository and destination; refusing sync" >&2
              exit 1
            }
          else
            ${pkgs.rclone}/bin/rclone mkdir \
              --config ${lib.escapeShellArg configFile} \
              ${lib.escapeShellArg megaDestination}
            remote_listing="$(${pkgs.rclone}/bin/rclone lsf \
              --config ${lib.escapeShellArg configFile} \
              --max-depth 1 \
              ${lib.escapeShellArg megaDestination})"
            if [[ -n "$remote_listing" ]]; then
              echo "Remote destination has no ownership marker; verifying its immutable Kopia repository identity before one-time adoption" >&2
              remote_fingerprint="$(${pkgs.rclone}/bin/rclone cat \
                --config ${lib.escapeShellArg configFile} \
                ${lib.escapeShellArg "${megaDestination}/kopia.repository.f"} \
                | ${pkgs.coreutils}/bin/sha256sum \
                | ${pkgs.coreutils}/bin/cut -d ' ' -f 1)" || {
                echo "Existing remote destination has no readable Kopia repository identity; refusing ownership adoption" >&2
                exit 1
              }
              [[ "$remote_fingerprint" == "$expected_fingerprint" ]] || {
                echo "Existing remote destination belongs to a different Kopia repository; refusing ownership adoption and destructive sync" >&2
                exit 1
              }
            fi
            remote_marker_tmp="$(${pkgs.coreutils}/bin/mktemp ${lib.escapeShellArg stateDir}/.remote-owner.XXXXXX)"
            trap 'rm -f "$remote_marker_tmp"' EXIT
            ${pkgs.jq}/bin/jq -n \
              --arg repositoryFingerprint "$expected_fingerprint" \
              --arg destination ${lib.escapeShellArg megaDestination} \
              '{schemaVersion: 1, repositoryFingerprint: $repositoryFingerprint, destination: $destination}' \
              > "$remote_marker_tmp"
            ${pkgs.rclone}/bin/rclone copyto \
              --config ${lib.escapeShellArg configFile} \
              "$remote_marker_tmp" \
              ${lib.escapeShellArg remoteOwnershipMarker}
            rm -f "$remote_marker_tmp"
            trap - EXIT
          fi

          ${pkgs.rclone}/bin/rclone sync \
            --config ${lib.escapeShellArg configFile} \
            --cache-dir ${lib.escapeShellArg cacheDir} \
            --fast-list \
            --check-first \
            --delete-before \
            --mega-hard-delete \
            --exclude ${lib.escapeShellArg "/${remoteOwnershipMarkerName}"} \
            --create-empty-src-dirs \
            --transfers ${toString megaTransfers} \
            --checkers ${toString megaCheckers} \
            --stats 30s \
            ${lib.escapeShellArg megaSource} \
            ${lib.escapeShellArg megaDestination}

          # Independently compare every source object with its destination after
          # the mirror completes before publishing the success marker.
          ${pkgs.rclone}/bin/rclone check \
            --config ${lib.escapeShellArg configFile} \
            --cache-dir ${lib.escapeShellArg cacheDir} \
            --one-way \
            --exclude ${lib.escapeShellArg "/${remoteOwnershipMarkerName}"} \
            --checkers ${toString megaCheckers} \
            ${lib.escapeShellArg megaSource} \
            ${lib.escapeShellArg megaDestination}

          marker_tmp=${lib.escapeShellArg syncSuccessMarker}.tmp
          ${pkgs.jq}/bin/jq -n \
            --arg completedAt "$(date --utc --iso-8601=seconds)" \
            --arg destination ${lib.escapeShellArg megaDestination} \
            --argjson repositoryBytes "$repository_bytes" \
            '{schemaVersion: 1, completedAt: $completedAt, destination: $destination, repositoryBytes: $repositoryBytes, verified: true}' \
            > "$marker_tmp"
          chmod 0600 "$marker_tmp"
          mv -f "$marker_tmp" ${lib.escapeShellArg syncSuccessMarker}
        '';
      };

      systemd.services.rclone-mega-capacity-check = {
        description = "Check MEGA quota and local Kopia repository budget";
        requires = [ "rclone-mega-config.service" ];
        after = [ "rclone-mega-config.service" "rclone-mega-kopia-sync.service" ];
        path = with pkgs; [ coreutils jq rclone systemd ];
        serviceConfig = {
          Type = "oneshot";
          User = serviceUser;
          Group = serviceGroup;
          SupplementaryGroups = [ backupStorageAccessGroup ];
          Environment = [ "HOME=${stateDir}" "XDG_CACHE_HOME=${stateDir}/.cache" ];
          ExecStart = capacityCheck;
        };
      };

      systemd.timers.rclone-mega-capacity-check = {
        description = "Regular MEGA and Kopia capacity warning";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = "15m";
          OnUnitActiveSec = "6h";
          Persistent = true;
          RandomizedDelaySec = "15m";
          Unit = "rclone-mega-capacity-check.service";
        };
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
  ];
}
