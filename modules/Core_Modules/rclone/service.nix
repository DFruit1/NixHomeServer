{ config, lib, pkgs, vars, ... }:

let
  serviceUser = "rclone";
  serviceGroup = "rclone";
  stateDir = "/var/lib/rclone";
  cacheDir = "${stateDir}/.cache/rclone";
  runtimeDir = "/run/rclone";
  configFile = "${runtimeDir}/rclone.conf";
  backupRoot = vars.backupRoot or "${vars.dataRoot}/backups";
  backupStorageAccessGroup = vars.backupAccess.storageGroup or "backup-admin";
  backupStorageAccessGid = vars.fileAccessPosixGids.${backupStorageAccessGroup};
  megaCfg = vars.rcloneMega or { };
  megaEnabled = megaCfg.enable or false;
  megaRemoteName = megaCfg.remoteName or "mega";
  megaEmail = megaCfg.email or "";
  megaSource = megaCfg.sourcePath or "${backupRoot}/kopia";
  megaDestination = megaCfg.destination or "${megaRemoteName}:NixHomeServer/kopia";
  megaSyncOnCalendar = megaCfg.syncOnCalendar or "*-*-* 04:30:00";
  megaRandomizedDelaySec = megaCfg.randomizedDelaySec or "30m";
  megaTransfers = megaCfg.transfers or 4;
  megaCheckers = megaCfg.checkers or 8;
  megaWarnPercent = megaCfg.warnPercent or 80;
  megaCriticalPercent = megaCfg.criticalPercent or 90;
  megaRepositoryLimitBytes = megaCfg.repositoryLimitBytes or 19327352832;
  megaConfigCredential = "mega-password";
  maintenanceLock = config.repo.backups.maintenanceLock;
  snapshotSuccessMarker = "${backupRoot}/.kopia-last-snapshot-success.json";
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
  config = lib.mkIf megaEnabled {
    assertions = [
      {
        assertion = megaEmail != "" && !(lib.hasPrefix "REPLACE_" megaEmail);
        message = "vars.rcloneMega.email must be set before enabling MEGA sync.";
      }
    ];

    users.groups.${serviceGroup} = { };
    users.groups.${backupStorageAccessGroup}.gid = lib.mkDefault backupStorageAccessGid;
    users.users.${serviceUser} = {
      isSystemUser = true;
      group = serviceGroup;
      extraGroups = [ backupStorageAccessGroup ];
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
      unitConfig.OnSuccess = [ "rclone-mega-capacity-check.service" ];
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
        SupplementaryGroups = [ backupStorageAccessGroup ];
        Environment = [ "HOME=${stateDir}" "XDG_CACHE_HOME=${stateDir}/.cache" ];
        Nice = 10;
        CPUWeight = 20;
        IOWeight = 20;
        IOSchedulingClass = "best-effort";
        IOSchedulingPriority = 7;
        TimeoutStartSec = "12h";
        ExecStartPre = "+${pkgs.systemd}/bin/systemctl stop kopia.service";
        ExecStopPost = "+${pkgs.systemd}/bin/systemctl start kopia.service";
      };
      script = ''
        set -euo pipefail
        ${requireDataRoot}
        success_marker=${lib.escapeShellArg snapshotSuccessMarker}
        [[ -s "$success_marker" ]] || { echo "No successful Kopia snapshot marker; refusing MEGA sync" >&2; exit 1; }
        marker_age=$(( $(date +%s) - $(stat -c %Y "$success_marker") ))
        (( marker_age <= 129600 )) || { echo "Latest successful Kopia snapshot is older than 36 hours; refusing MEGA sync" >&2; exit 1; }
        repository_bytes="$(${pkgs.coreutils}/bin/du --summarize --bytes ${lib.escapeShellArg megaSource} | ${pkgs.coreutils}/bin/cut -f1)"
        if (( repository_bytes >= ${toString megaRepositoryLimitBytes} )); then
          echo "Local Kopia repository is $repository_bytes bytes; refusing MEGA upload at the ${toString megaRepositoryLimitBytes}-byte safety ceiling" >&2
          exit 1
        fi
        exec 9>${lib.escapeShellArg maintenanceLock}
        ${pkgs.util-linux}/bin/flock -n 9 || { echo "Another maintenance job is active" >&2; exit 75; }
        ${pkgs.rclone}/bin/rclone sync \
          --config ${lib.escapeShellArg configFile} \
          --cache-dir ${lib.escapeShellArg cacheDir} \
          --fast-list \
          --check-first \
          --delete-before \
          --mega-hard-delete \
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
  };
}
