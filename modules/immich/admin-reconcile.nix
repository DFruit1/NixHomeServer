{ config, pkgs, vars, ... }:

let
  kanidmPort = vars.networking.ports.kanidm;
  kanidmCliUrl = "https://${vars.kanidmDomain}:${toString kanidmPort}";
  immichDbName = config.services.immich.database.name;
  immichDbUser = config.services.immich.database.user;
  immichRuntime = {
    dbUrl = "postgresql:///${immichDbName}?host=/run/postgresql";
    configFile = "/run/immich/config.json";
    mediaLocation = config.repo.immich.paths.managed;
    redisSocket = "/run/redis-immich/redis.sock";
  };
  immichAdminReconcileInputs = with pkgs; [
    coreutils
    gnugrep
    jq
    kanidm_1_10
    postgresql
    util-linux
  ];
  immichAdminReconcile = pkgs.writeShellApplication {
    name = "immich-admin-reconcile";
    runtimeInputs = immichAdminReconcileInputs;
    text = ''
      set -euo pipefail

      temp_home="$(mktemp -d)"
      export HOME="$temp_home"
      cleanup() {
        rm -rf "$temp_home"
      }
      trap cleanup EXIT

      KANIDM_PASSWORD="$(< ${config.age.secrets.kanidmAdminPass.path})"
      export KANIDM_PASSWORD

      kanidm login \
        -H ${kanidmCliUrl} \
        -D idm_admin >/dev/null

      snapshot_group_members() {
        local group_name="$1"
        local output_file="$2"
        local group_json

        if ! group_json="$(
          kanidm group get \
            "$group_name" \
            -H ${kanidmCliUrl} \
            -D idm_admin \
            -o json
        )"; then
          echo "Unable to read Kanidm group '$group_name'; refusing to reconcile Immich admins" >&2
          return 1
        fi
        if ! jq -cer '
          if ((.attrs.member // []) | type) != "array" then
            error("Kanidm group member attribute is not an array")
          else
            [ .attrs.member[]? | strings | split("@")[0] | select(length > 0) ] | unique
          end
        ' <<<"$group_json" >"$output_file"; then
          echo "Kanidm returned an invalid membership document for '$group_name'; refusing to reconcile Immich admins" >&2
          return 1
        fi
      }

      snapshot_person_email() {
        local username="$1"
        local person_json email

        if ! person_json="$(
          kanidm person get \
            "$username" \
            -H ${kanidmCliUrl} \
            -D idm_admin \
            -o json
        )"; then
          echo "Unable to read Kanidm person '$username'; refusing to reconcile Immich admins" >&2
          return 1
        fi
        if ! email="$(
          jq -er '
            (.attrs.mail[0] // .attrs.email[0])
            | select(type == "string" and length > 0)
          ' <<<"$person_json"
        )"; then
          echo "Kanidm person '$username' has no valid mail address; refusing to reconcile Immich admins" >&2
          return 1
        fi

        printf '%s\n' "$email"
      }

      immich_members_file="$temp_home/immich-members.json"
      app_admin_members_file="$temp_home/app-admin-members.json"
      desired_usernames_file="$temp_home/desired-usernames"
      desired_admin_candidates_file="$temp_home/desired-admin-emails.unsorted"
      desired_admin_emails_file="$temp_home/desired-admin-emails"
      current_admin_emails_file="$temp_home/current-admin-emails"

      # Materialize every authoritative snapshot and validate each command
      # status explicitly. Process substitution would hide failures and could
      # otherwise turn an identity outage into an empty desired-admin set.
      snapshot_group_members "immich-users" "$immich_members_file"
      snapshot_group_members "app-admin" "$app_admin_members_file"
      if ! jq -nr \
        --slurpfile immichMembers "$immich_members_file" \
        --slurpfile appAdmins "$app_admin_members_file" \
        '$immichMembers[0][] | select(. as $username | $appAdmins[0] | index($username) != null)' \
        >"$desired_usernames_file"; then
        echo "Unable to intersect Kanidm group snapshots; refusing to reconcile Immich admins" >&2
        exit 1
      fi

      : >"$desired_admin_candidates_file"
      while IFS= read -r username; do
        [[ -n "$username" ]] || continue
        if ! email="$(snapshot_person_email "$username")"; then
          exit 1
        fi
        printf '%s\n' "$email" >>"$desired_admin_candidates_file"
      done <"$desired_usernames_file"
      sort -u "$desired_admin_candidates_file" >"$desired_admin_emails_file"

      if ! runuser -u ${config.services.immich.user} -- \
        psql \
          "dbname=${immichDbName} host=/run/postgresql user=${immichDbUser}" \
          -At \
          -c "select email from \"user\" where \"deletedAt\" is null and char_length(\"oauthId\") > 0 and \"isAdmin\" = true order by email;" \
        >"$current_admin_emails_file"; then
        echo "Unable to read current Immich admins; refusing to change admin privileges" >&2
        exit 1
      fi

      mapfile -t desired_admin_emails <"$desired_admin_emails_file"
      mapfile -t current_admin_emails <"$current_admin_emails_file"

      run_immich_admin() {
        local command="$1"
        local email="$2"

        printf '%s\n' "$email" | runuser -u ${config.services.immich.user} -- \
          env \
            DB_URL=${immichRuntime.dbUrl} \
            IMMICH_CONFIG_FILE=${immichRuntime.configFile} \
            IMMICH_MEDIA_LOCATION=${immichRuntime.mediaLocation} \
            REDIS_SOCKET=${immichRuntime.redisSocket} \
            ${config.services.immich.package}/bin/immich-admin "$command"
      }

      contains_line() {
        local needle="$1"
        shift || true
        printf '%s\n' "$@" | grep -Fxq -- "$needle"
      }

      for email in "''${desired_admin_emails[@]}"; do
        [[ -n "$email" ]] || continue
        if ! contains_line "$email" "''${current_admin_emails[@]}"; then
          if ! run_immich_admin grant-admin "$email" >/dev/null 2>&1; then
            echo "Immich admin grant skipped for $email; user may not exist yet" >&2
          fi
        fi
      done

      for email in "''${current_admin_emails[@]}"; do
        [[ -n "$email" ]] || continue
        if ! contains_line "$email" "''${desired_admin_emails[@]}"; then
          run_immich_admin revoke-admin "$email" >/dev/null
        fi
      done
    '';
  };
in
{
  config = {
    systemd.services.immich-refresh-collation = {
      description = "Guarded Immich PostgreSQL collation refresh";
      after = [ "postgresql.service" "backup-prepare.service" ];
      requires = [ "postgresql.service" "backup-prepare.service" ];
      path = [ pkgs.coreutils pkgs.postgresql pkgs.systemd pkgs.util-linux ];
      serviceConfig = {
        Type = "oneshot";
        TimeoutStartSec = "2h";
      };
      script = ''
        set -euo pipefail
        units=(immich-machine-learning.service immich-server.service)
        restart_immich() { systemctl start "''${units[@]}"; }
        trap restart_immich EXIT
        systemctl stop "''${units[@]}"
        runuser -u ${config.services.immich.user} -- \
          psql "dbname=${config.services.immich.database.name} host=/run/postgresql user=${config.services.immich.database.user}" \
          --set ON_ERROR_STOP=1 \
          --command 'REINDEX DATABASE "${config.services.immich.database.name}";' \
          --command 'ALTER DATABASE "${config.services.immich.database.name}" REFRESH COLLATION VERSION;'
      '';
    };

    systemd.services.immich-admin-reconcile = {
      description = "Reconcile Immich admin users from Kanidm group membership";
      wantedBy = [ "multi-user.target" ];
      after = [
        "immich-server.service"
        "kanidm.service"
        "postgresql.service"
        "redis-immich.service"
      ];
      wants = [
        "immich-server.service"
        "kanidm.service"
        "postgresql.service"
        "redis-immich.service"
      ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${immichAdminReconcile}/bin/immich-admin-reconcile";
      };
    };

    systemd.timers.immich-admin-reconcile = {
      description = "Periodically reconcile Immich admin users from Kanidm";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "5m";
        OnUnitActiveSec = "1h";
        Unit = "immich-admin-reconcile.service";
      };
    };
  };
}
