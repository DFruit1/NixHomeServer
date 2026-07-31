{ config, lib, pkgs, vars, ... }:

let
  cfg = config.repo.seerr;
  loopback = vars.networking.loopbackIPv4;
  seerrPort = vars.networking.ports.seerr;
  kanidmCliUrl = "https://${vars.kanidmDomain}:${toString vars.networking.ports.kanidm}";
  requestManagerGroup = vars.seerrRequestManagerGroup;
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
      wants = [
        "kanidm.service"
        "seerr.service"
      ];
      after = [
        "kanidm.service"
        "seerr.service"
      ];
      path = with pkgs; [
        coreutils
        curl
        jq
        kanidm_1_10
        sqlite
      ];
      script = ''
        set -euo pipefail

        db=${lib.escapeShellArg seerrDb}
        seerr_url=${lib.escapeShellArg seerrUrl}
        kanidm_url=${lib.escapeShellArg kanidmCliUrl}
        request_manager_group=${lib.escapeShellArg requestManagerGroup}
        request_manager_permission=${toString requestManagerPermission}
        request_only_permission=${toString requestOnlyPermission}

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

        export HOME="$(mktemp -d)"
        trap 'rm -rf "$HOME"' EXIT
        KANIDM_PASSWORD="$(< "$CREDENTIALS_DIRECTORY/idm-admin-password")"
        export KANIDM_PASSWORD

        kanidm login \
          -H "$kanidm_url" \
          -D idm_admin >/dev/null

        if ! group_json="$(
          kanidm group get \
            "$request_manager_group" \
            -H "$kanidm_url" \
            -D idm_admin \
            -o json
        )"; then
          echo "Unable to read Kanidm group '$request_manager_group'; refusing to reconcile Seerr permissions" >&2
          exit 1
        fi

        if ! request_managers="$(
          jq -er '
            if ((.attrs.member // []) | type) != "array" then
              error("Kanidm group member attribute is not an array")
            elif any(.attrs.member[]?; type != "string") then
              error("Kanidm group member attribute contains a non-string value")
            else
              [
                .attrs.member[]?
                | split("@")[0]
                | select(test("^[a-z][a-z0-9._-]{0,63}$"))
              ]
              | unique
              | join("\n")
            end
          ' <<<"$group_json"
        )"; then
          echo "Kanidm returned invalid membership for '$request_manager_group'; refusing to reconcile Seerr permissions" >&2
          exit 1
        fi

        sql_values=""
        while IFS= read -r username; do
          [[ -n "$username" ]] || continue
          if [[ -n "$sql_values" ]]; then
            sql_values+=","
          fi
          sql_values+="'$username'"
        done <<<"$request_managers"

        if [[ -z "$sql_values" ]]; then
          sqlite3 "$db" "
            update user
            set permissions = $request_only_permission
            where permissions = $request_manager_permission;
          "
          exit 0
        fi

        sqlite3 "$db" "
          update user
          set permissions = $request_only_permission
          where permissions = $request_manager_permission
            and (jellyfinUsername is null or jellyfinUsername not in ($sql_values))
            and (username is null or username not in ($sql_values));

          update user
          set permissions = $request_manager_permission
          where permissions != 2
            and (
              jellyfinUsername in ($sql_values)
              or username in ($sql_values)
            );
        "
      '';
      serviceConfig = {
        Type = "oneshot";
        User = "seerr";
        Group = "seerr";
        LoadCredential = [
          "idm-admin-password:${config.age.secrets.kanidmAdminPass.path}"
        ];
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
