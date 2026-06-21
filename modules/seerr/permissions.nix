{ config, lib, pkgs, vars, ... }:

let
  cfg = config.repo.seerr;
  loopback = vars.networking.loopbackIPv4;
  seerrPort = vars.networking.ports.seerr;
  requestManagers = lib.unique vars.seerrRequestManagers;
  escapeSql = value: "'${lib.replaceStrings [ "'" ] [ "''" ] value}'";
  requestManagersSqlValues = lib.concatMapStringsSep "," escapeSql requestManagers;
  requestOnlyPermission = 32;
  manageRequestsPermission = 16;
  requestManagerPermission = requestOnlyPermission + manageRequestsPermission;
  seerrDb = "/var/lib/seerr/db/db.sqlite3";
  seerrUrl = "http://${loopback}:${toString seerrPort}";
in
{
  config = lib.mkIf cfg.enable {
    systemd.services.seerr-permissions-reconcile = {
      description = "Reconcile Seerr request-manager permissions";
      wantedBy = [ "multi-user.target" ];
      wants = [ "seerr.service" ];
      after = [ "seerr.service" ];
      path = with pkgs; [
        coreutils
        curl
        sqlite
      ];
      script = ''
        set -euo pipefail

        db=${lib.escapeShellArg seerrDb}
        seerr_url=${lib.escapeShellArg seerrUrl}
        sql_values=${lib.escapeShellArg requestManagersSqlValues}
        request_manager_permission=${toString requestManagerPermission}

        for _ in $(seq 1 120); do
          [[ -f "$db" ]] && break
          sleep 1
        done
        [[ -f "$db" ]] || {
          echo "Seerr database not found at $db" >&2
          exit 1
        }

        for _ in $(seq 1 120); do
          if curl --silent --show-error --fail --max-time 5 "$seerr_url/api/v1/settings/public" >/dev/null; then
            break
          fi
          sleep 1
        done
        curl --silent --show-error --fail --max-time 5 "$seerr_url/api/v1/settings/public" >/dev/null || {
          echo "Seerr HTTP endpoint is not ready" >&2
          exit 1
        }

        [[ -n "$sql_values" ]] || {
          echo "No Seerr request managers configured"
          exit 0
        }

        sqlite3 "$db" "
          update user
          set permissions = $request_manager_permission
          where permissions != 2
            and (
              jellyfinUsername in ($sql_values)
              or email in ($sql_values)
              or username in ($sql_values)
            );
        "
      '';
      serviceConfig = {
        Type = "oneshot";
        User = "seerr";
        Group = "seerr";
        Restart = "on-failure";
        RestartSec = "10s";
      };
    };

    systemd.timers.seerr-permissions-reconcile = {
      description = "Periodically reconcile Seerr request-manager permissions";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "2m";
        OnUnitActiveSec = "15m";
        Persistent = true;
        Unit = "seerr-permissions-reconcile.service";
      };
    };
  };
}
