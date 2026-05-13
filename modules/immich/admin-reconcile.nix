{ config, pkgs, vars, ... }:

let
  kanidmPort = 8443;
  kanidmCliUrl = "https://${vars.kanidmDomain}:${toString kanidmPort}";
  immichDbName = config.services.immich.database.name;
  immichDbUser = config.services.immich.database.user;
  immichRuntime = {
    dbUrl = "postgresql:///${immichDbName}?host=/run/postgresql";
    configFile = "/run/immich/config.json";
    mediaLocation = vars.immichManagedRoot;
    redisSocket = "/run/redis-immich/redis.sock";
  };
  immichAdminReconcileInputs = with pkgs; [
    coreutils
    gnugrep
    gnused
    jq
    kanidm_1_9
    postgresql
    util-linux
  ];
  immichAdminReconcile = pkgs.writeShellApplication {
    name = "immich-admin-reconcile";
    runtimeInputs = immichAdminReconcileInputs;
    text = ''
      temp_home="$(mktemp -d)"
      export HOME="$temp_home"
      cleanup() {
        rm -rf "$temp_home"
      }
      trap cleanup EXIT

      export KANIDM_PASSWORD="$(< ${config.age.secrets.kanidmAdminPass.path})"

      kanidm login \
        -H ${kanidmCliUrl} \
        -D idm_admin >/dev/null

      group_member_usernames() {
        local group_name="$1"

        kanidm group get \
          "$group_name" \
          -H ${kanidmCliUrl} \
          -D idm_admin \
          -o json \
          | jq -r '.attrs.member[]? | split("@")[0]' \
          | sed '/^$/d' \
          | sort -u
      }

      mapfile -t desired_admin_emails < <(
        comm -12 \
          <(group_member_usernames "immich-users") \
          <(group_member_usernames "app-admin") \
          | while IFS= read -r username; do
              [[ -n "$username" ]] || continue
              kanidm person get \
                "$username" \
                -H ${kanidmCliUrl} \
                -D idm_admin \
                -o json \
                | jq -r '(.attrs.mail[0] // .attrs.email[0] // empty)'
            done \
          | sed '/^$/d' \
          | sort -u
      )

      mapfile -t current_admin_emails < <(
        runuser -u ${config.services.immich.user} -- \
          psql \
            "dbname=${immichDbName} host=/run/postgresql user=${immichDbUser}" \
            -At \
            -c "select email from users where char_length(\"oauthId\") > 0 and \"isAdmin\" = true order by email;"
      )

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
      OnUnitActiveSec = "15m";
      Unit = "immich-admin-reconcile.service";
    };
  };
}
