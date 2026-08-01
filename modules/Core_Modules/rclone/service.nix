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
  megaSyncOnCalendar = megaCfg.syncOnCalendar or "*-*-* 04,16:30:00";
  megaRandomizedDelaySec = megaCfg.randomizedDelaySec or "30m";
  megaTransfersRaw = megaCfg.transfers or 4;
  megaTransfers = if builtins.isInt megaTransfersRaw then megaTransfersRaw else 0;
  megaCheckersRaw = megaCfg.checkers or 8;
  megaCheckers = if builtins.isInt megaCheckersRaw then megaCheckersRaw else 0;
  megaWarnPercentRaw = megaCfg.warnPercent or 80;
  megaWarnPercent = if builtins.isInt megaWarnPercentRaw then megaWarnPercentRaw else 0;
  megaCriticalPercentRaw = megaCfg.criticalPercent or 90;
  megaCriticalPercent = if builtins.isInt megaCriticalPercentRaw then megaCriticalPercentRaw else 0;
  megaRepositoryLimitBytesRaw = megaCfg.repositoryLimitBytes or (19 * 1024 * 1024 * 1024);
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
  megaPreflight = pkgs.writeShellScript "rclone-mega-preflight"
    (builtins.readFile ../../../scripts/helpers/rclone-mega-preflight.sh);
  megaStatusEvent = pkgs.writeShellScript "rclone-mega-status-event"
    (builtins.readFile ../../../scripts/helpers/rclone-mega-status-event.sh);
  megaCapacityCheck = pkgs.writeShellScript "rclone-mega-capacity-check-helper"
    (builtins.readFile ../../../scripts/helpers/rclone-mega-capacity-check.sh);
  megaAlwaysTransferFiles = pkgs.writeText "kopia-mega-always-transfer-files" ''
    .shards
    kopia.blobcfg.f
    kopia.maintenance.f
    kopia.repository.f
  '';
  repositoryOwnershipMarker = "${backupRoot}/.nixhomeserver-kopia-repository.json";
  remoteOwnershipMarkerName = ".nixhomeserver-rclone-owner.json";
  syncSuccessMarker = "${stateDir}/last-mega-sync-success.json";
  syncStatusFile = "${stateDir}/last-mega-sync-status.json";
  capacityStatusFile = "${stateDir}/last-mega-capacity.json";
  capacityAlertStateFile = "${stateDir}/mega-capacity-alert.timestamp";
  preflightResultFile = "${runtimeDir}/mega-preflight-result.json";
  capacityCheck = pkgs.writeShellScript "rclone-mega-capacity-check" ''
    set -euo pipefail
    event_json=""
    helper_exit=0
    set +e
    event_json="$(
      RCLONE_BIN=${lib.escapeShellArg "${pkgs.rclone}/bin/rclone"} \
      JQ_BIN=${lib.escapeShellArg "${pkgs.jq}/bin/jq"} \
      DU_BIN=${lib.escapeShellArg "${pkgs.coreutils}/bin/du"} \
      DATE_BIN=${lib.escapeShellArg "${pkgs.coreutils}/bin/date"} \
      MKTEMP_BIN=${lib.escapeShellArg "${pkgs.coreutils}/bin/mktemp"} \
      MV_BIN=${lib.escapeShellArg "${pkgs.coreutils}/bin/mv"} \
      CHMOD_BIN=${lib.escapeShellArg "${pkgs.coreutils}/bin/chmod"} \
      RM_BIN=${lib.escapeShellArg "${pkgs.coreutils}/bin/rm"} \
        ${megaCapacityCheck} \
          --config ${lib.escapeShellArg configFile} \
          --remote ${lib.escapeShellArg "${megaRemoteName}:"} \
          --source ${lib.escapeShellArg megaSource} \
          --status-file ${lib.escapeShellArg capacityStatusFile} \
          --alert-state-file ${lib.escapeShellArg capacityAlertStateFile} \
          --sync-status-file ${lib.escapeShellArg syncStatusFile} \
          --warn-percent ${toString megaWarnPercent} \
          --critical-percent ${toString megaCriticalPercent} \
          --limit-bytes ${toString megaRepositoryLimitBytes} \
          --cooldown-seconds 86400
    )"
    helper_exit=$?
    set -e

    state="$(${pkgs.jq}/bin/jq -r '.state // "failed"' <<<"$event_json" 2>/dev/null || printf failed)"
    case "$state" in
      ok) priority=info ;;
      warning) priority=warning ;;
      critical|blocked|failed) priority=err ;;
      *) priority=err ;;
    esac
    if [[ -n "$event_json" ]]; then
      printf '%s\n' "$event_json" \
        | ${pkgs.systemd}/bin/systemd-cat --identifier=backup-capacity --priority="$priority"
      printf '%s\n' "$event_json"
    else
      ${pkgs.systemd}/bin/systemd-cat --identifier=backup-capacity --priority=err \
        <<<"MEGA capacity checker stopped without a structured result."
    fi
    exit "$helper_exit"
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
          assertion =
            builtins.isString megaEmailRaw
            && megaEmailRaw != ""
            && !(lib.hasPrefix "REPLACE_" megaEmailRaw)
            && !(lib.hasInfix "\n" megaEmailRaw)
            && !(lib.hasInfix "\r" megaEmailRaw)
            && builtins.match "^[^ @]+@[^ @]+$" megaEmailRaw != null;
          message = "vars.rcloneMega.email must be a single-line email address before enabling MEGA sync.";
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
          OnFailure = [ config.repo.monitoring.failureAlerts.targetUnit ];
          OnFailureJobMode = "replace-irreversibly";
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
          Type = "exec";
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
          # Intermediate retry failures stay out of OnFailure. Capacity blocks
          # are a clean degraded outcome, while safety/repository failures stop
          # immediately and retain the ordinary actionable alert path.
          RestartMode = "direct";
          SuccessExitStatus = [ 76 ];
          RestartPreventExitStatus = [ 64 76 77 78 ];
          ExecStartPre = "+${pkgs.systemd}/bin/systemctl stop kopia.service";
          ExecStopPost = "+${pkgs.systemd}/bin/systemctl start kopia.service";
        };
        script = ''
          set -euo pipefail

          attempt_id="sync-$(date +%s)-$$"
          repository_bytes=0
          status_state=running
          status_class=none
          status_reason=sync_started
          status_message="MEGA Kopia mirror attempt started."
          status_retryable=false
          status_operator_action=false

          set_status() {
            status_state="$1"
            status_class="$2"
            status_reason="$3"
            status_message="$4"
            status_retryable="$5"
            status_operator_action="$6"
          }

          emit_status() {
            local event_json helper_exit priority
            helper_exit=0
            set +e
            event_json="$(
              JQ_BIN=${lib.escapeShellArg "${pkgs.jq}/bin/jq"} \
              DATE_BIN=${lib.escapeShellArg "${pkgs.coreutils}/bin/date"} \
              MKTEMP_BIN=${lib.escapeShellArg "${pkgs.coreutils}/bin/mktemp"} \
              MV_BIN=${lib.escapeShellArg "${pkgs.coreutils}/bin/mv"} \
              CHMOD_BIN=${lib.escapeShellArg "${pkgs.coreutils}/bin/chmod"} \
              RM_BIN=${lib.escapeShellArg "${pkgs.coreutils}/bin/rm"} \
                ${megaStatusEvent} \
                  --status-file ${lib.escapeShellArg syncStatusFile} \
                  --attempt-id "$attempt_id" \
                  --state "$status_state" \
                  --failure-class "$status_class" \
                  --reason "$status_reason" \
                  --message "$status_message" \
                  --retryable "$status_retryable" \
                  --operator-action-required "$status_operator_action" \
                  --repository-bytes "$repository_bytes" \
                  --limit-bytes ${toString megaRepositoryLimitBytes}
            )"
            helper_exit=$?
            set -e
            if (( helper_exit != 0 )); then
              echo "Could not persist the structured MEGA sync status event" >&2
              return 64
            fi
            case "$status_state" in
              success|running) priority=info ;;
              blocked|retrying) priority=warning ;;
              failed) priority=err ;;
            esac
            printf '%s\n' "$event_json" \
              | ${pkgs.systemd}/bin/systemd-cat --identifier=backup-offsite --priority="$priority" \
              || echo "Could not publish the persisted MEGA sync status to the journal" >&2
          }

          finalize_status() {
            local exit_code=$?
            local status_exit=0
            trap - EXIT
            if (( exit_code == 0 )) && [[ "$status_state" == running ]]; then
              set_status success none mirror_verified \
                "MEGA Kopia mirror completed and verified." false false
            elif (( exit_code != 0 )) && [[ "$status_state" == running ]]; then
              set_status failed repository unexpected_sync_failure \
                "MEGA Kopia mirror stopped without a classified result." false true
            fi
            emit_status || status_exit=$?
            if (( status_exit != 0 )); then
              case "$exit_code" in
                77|78) ;;
                *) exit_code=64 ;;
              esac
            fi
            exit "$exit_code"
          }
          trap finalize_status EXIT
          emit_status || exit 64

          ${lib.optionalString vars.dataRootIsMountPoint ''
            if ! ${pkgs.util-linux}/bin/mountpoint -q ${lib.escapeShellArg vars.dataRoot}; then
              echo "Refusing offsite sync because ${vars.dataRoot} is not a mounted data pool" >&2
              set_status failed repository data_root_unmounted \
                "The persistent data pool is not mounted." false true
              exit 78
            fi
          ''}
          exec 9>${lib.escapeShellArg maintenanceLock}
          ${pkgs.util-linux}/bin/flock -n 9 || {
            set_status retrying transient maintenance_lock_busy \
              "Another backup maintenance operation is active; retrying later." true false
            exit 75
          }

          expected_source=${lib.escapeShellArg megaSource}
          ownership_marker=${lib.escapeShellArg repositoryOwnershipMarker}
          [[ -f ${lib.escapeShellArg "${megaSource}/kopia.repository.f"} ]] || {
            echo "Managed Kopia repository marker is missing from $expected_source; refusing destructive offsite sync" >&2
            set_status failed repository local_repository_marker_missing \
              "Managed Kopia repository identity is missing." false true
            exit 78
          }
          [[ -s "$ownership_marker" ]] || {
            echo "Kopia ownership marker is missing; refusing destructive offsite sync" >&2
            set_status failed repository local_ownership_marker_missing \
              "Root-owned Kopia repository marker is missing." false true
            exit 78
          }
          expected_fingerprint="$(${pkgs.jq}/bin/jq -er \
            --arg source "$expected_source" \
            'select(.schemaVersion == 1 and .repositoryPath == $source and (.repositoryFingerprint | test("^[0-9a-f]{64}$"))) | .repositoryFingerprint' \
            "$ownership_marker")" || {
            echo "Kopia ownership marker does not identify the managed repository; refusing sync" >&2
            set_status failed repository local_ownership_marker_invalid \
              "Root-owned Kopia repository marker is invalid." false true
            exit 78
          }
          actual_fingerprint="$(${pkgs.coreutils}/bin/sha256sum ${lib.escapeShellArg "${megaSource}/kopia.repository.f"} \
            | ${pkgs.coreutils}/bin/cut -d ' ' -f 1)"
          [[ "$actual_fingerprint" == "$expected_fingerprint" ]] || {
            echo "Kopia repository identity differs from its root-owned marker; refusing sync" >&2
            set_status failed safety local_repository_identity_mismatch \
              "Local Kopia repository identity does not match its ownership marker." false true
            exit 77
          }
          success_marker=${lib.escapeShellArg snapshotSuccessMarker}
          [[ -s "$success_marker" ]] || {
            echo "No successful Kopia snapshot marker; refusing MEGA sync" >&2
            set_status failed repository snapshot_success_marker_missing \
              "No successful Kopia snapshot marker is available." false true
            exit 78
          }
          FRESHNESS_MARKER_JQ_BIN=${lib.escapeShellArg "${pkgs.jq}/bin/jq"} \
            FRESHNESS_MARKER_DATE_BIN=${lib.escapeShellArg "${pkgs.coreutils}/bin/date"} \
            ${freshnessMarkerCheck} \
              --marker "$success_marker" \
              --max-age-seconds ${toString snapshotHealthMaxAgeSeconds} \
              >/dev/null || {
            echo "Latest successful Kopia snapshot marker is invalid, stale, or future-dated; refusing MEGA sync" >&2
            set_status failed repository snapshot_success_marker_stale \
              "Latest successful Kopia snapshot marker is invalid or stale." false true
            exit 78
          }
          repository_bytes="$(${pkgs.coreutils}/bin/du --summarize --bytes ${lib.escapeShellArg megaSource} | ${pkgs.coreutils}/bin/cut -f1)"
          preflight_exit=0
          ${pkgs.coreutils}/bin/rm -f ${lib.escapeShellArg preflightResultFile}
          set +e
          RCLONE_BIN=${lib.escapeShellArg "${pkgs.rclone}/bin/rclone"} \
          JQ_BIN=${lib.escapeShellArg "${pkgs.jq}/bin/jq"} \
          SHA256SUM_BIN=${lib.escapeShellArg "${pkgs.coreutils}/bin/sha256sum"} \
          CUT_BIN=${lib.escapeShellArg "${pkgs.coreutils}/bin/cut"} \
          MKTEMP_BIN=${lib.escapeShellArg "${pkgs.coreutils}/bin/mktemp"} \
          MV_BIN=${lib.escapeShellArg "${pkgs.coreutils}/bin/mv"} \
          CHMOD_BIN=${lib.escapeShellArg "${pkgs.coreutils}/bin/chmod"} \
          RM_BIN=${lib.escapeShellArg "${pkgs.coreutils}/bin/rm"} \
            ${megaPreflight} \
              --config ${lib.escapeShellArg configFile} \
              --source ${lib.escapeShellArg megaSource} \
              --cache-dir ${lib.escapeShellArg cacheDir} \
              --checkers ${toString megaCheckers} \
              --always-transfer-from ${lib.escapeShellArg megaAlwaysTransferFiles} \
              --remote-root ${lib.escapeShellArg "${megaRemoteName}:"} \
              --destination ${lib.escapeShellArg megaDestination} \
              --marker-name ${lib.escapeShellArg remoteOwnershipMarkerName} \
              --expected-fingerprint "$expected_fingerprint" \
              --repository-bytes "$repository_bytes" \
              --limit-bytes ${toString megaRepositoryLimitBytes} \
              --control-reserve-bytes 1048576 \
              --result-file ${lib.escapeShellArg preflightResultFile} \
              --state-dir ${lib.escapeShellArg stateDir}
          preflight_exit=$?
          set -e

          if (( preflight_exit != 0 )); then
            case "$preflight_exit" in
              75|76|77|78) ;;
              *)
                set_status failed repository preflight_helper_failed \
                  "MEGA preflight stopped without a supported classified result." false true
                exit 64
                ;;
            esac
            if [[ -s ${lib.escapeShellArg preflightResultFile} ]] \
              && status_class="$(${pkgs.jq}/bin/jq -er '.failureClass | select(type == "string")' ${lib.escapeShellArg preflightResultFile})" \
              && status_reason="$(${pkgs.jq}/bin/jq -er '.reason | select(type == "string")' ${lib.escapeShellArg preflightResultFile})" \
              && status_message="$(${pkgs.jq}/bin/jq -er '.message | select(type == "string")' ${lib.escapeShellArg preflightResultFile})" \
              && status_retryable="$(${pkgs.jq}/bin/jq -er '.retryable | select(type == "boolean")' ${lib.escapeShellArg preflightResultFile})" \
              && status_operator_action="$(${pkgs.jq}/bin/jq -er '.operatorActionRequired | select(type == "boolean")' ${lib.escapeShellArg preflightResultFile})"; then
              case "$preflight_exit" in
                75) status_state=retrying ;;
                76) status_state=blocked ;;
                77|78) status_state=failed ;;
              esac
              exit "$preflight_exit"
            fi
            set_status failed repository preflight_result_invalid \
              "MEGA preflight did not return a valid classified result." false true
            exit 64
          fi

          run_rclone_phase() {
            local phase="$1"
            local description="$2"
            local rclone_exit
            shift 2
            set +e
            "$@"
            rclone_exit=$?
            set -e
            (( rclone_exit != 0 )) || return 0
            case "$rclone_exit" in
              3|4|5)
                set_status retrying transient "''${phase}_temporary" \
                  "$description encountered a temporary MEGA error; retrying later." true false
                return 75
                ;;
              *)
                set_status failed remote "''${phase}_failed" \
                  "$description failed with a non-retryable rclone result." false true
                return 78
                ;;
            esac
          }

          run_rclone_phase mirror_sync "Encrypted repository mirror" \
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
            ${lib.escapeShellArg megaDestination} || exit $?

          # MEGA exposes neither hashes nor modification times, so rclone's
          # normal equality check falls back to size. Force-copy the small
          # fixed-name Kopia control objects; bulk packs and indexes have
          # immutable unique names and remain on the efficient sync path.
          run_rclone_phase control_refresh "Mutable Kopia control refresh" \
            ${pkgs.rclone}/bin/rclone copy \
            --config ${lib.escapeShellArg configFile} \
            --cache-dir ${lib.escapeShellArg cacheDir} \
            --files-from ${lib.escapeShellArg megaAlwaysTransferFiles} \
            --ignore-times \
            --no-traverse \
            --mega-hard-delete \
            --transfers ${toString megaTransfers} \
            --checkers ${toString megaCheckers} \
            ${lib.escapeShellArg megaSource} \
            ${lib.escapeShellArg megaDestination} || exit $?

          # Independently compare every source object with its destination after
          # the mirror completes before publishing the success marker.
          run_rclone_phase bulk_verify "Encrypted repository verification" \
            ${pkgs.rclone}/bin/rclone check \
            --config ${lib.escapeShellArg configFile} \
            --cache-dir ${lib.escapeShellArg cacheDir} \
            --one-way \
            --exclude ${lib.escapeShellArg "/${remoteOwnershipMarkerName}"} \
            --checkers ${toString megaCheckers} \
            ${lib.escapeShellArg megaSource} \
            ${lib.escapeShellArg megaDestination} || exit $?

          # Byte-compare the same small mutable control set because the MEGA
          # backend cannot provide a server-side checksum.
          run_rclone_phase control_verify "Mutable Kopia control verification" \
            ${pkgs.rclone}/bin/rclone check \
            --config ${lib.escapeShellArg configFile} \
            --cache-dir ${lib.escapeShellArg cacheDir} \
            --download \
            --one-way \
            --files-from ${lib.escapeShellArg megaAlwaysTransferFiles} \
            --checkers ${toString megaCheckers} \
            ${lib.escapeShellArg megaSource} \
            ${lib.escapeShellArg megaDestination} || exit $?

          set_status failed repository success_marker_write_failed \
            "Verified mirror succeeded but its local success marker could not be written." false true
          marker_tmp=${lib.escapeShellArg syncSuccessMarker}.tmp
          ${pkgs.jq}/bin/jq -n \
            --arg completedAt "$(date --utc --iso-8601=seconds)" \
            --arg destination ${lib.escapeShellArg megaDestination} \
            --argjson repositoryBytes "$repository_bytes" \
            '{schemaVersion: 1, completedAt: $completedAt, destination: $destination, repositoryBytes: $repositoryBytes, verified: true}' \
            > "$marker_tmp"
          chmod 0600 "$marker_tmp"
          mv -f "$marker_tmp" ${lib.escapeShellArg syncSuccessMarker}
          set_status success none mirror_verified \
            "MEGA Kopia mirror completed and verified." false false
        '';
      };

      systemd.services.rclone-mega-capacity-check = {
        description = "Check MEGA quota and local Kopia repository budget";
        unitConfig = {
          OnFailure = [ config.repo.monitoring.failureAlerts.targetUnit ];
          OnFailureJobMode = "replace-irreversibly";
        };
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
