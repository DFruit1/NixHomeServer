{ config, pkgs, vars, ... }:

let
  kanidmPort = 8443;
  kanidmCliUrl = "https://${vars.kanidmDomain}:${toString kanidmPort}";
  immichDbName = config.services.immich.database.name;
  immichDbUser = config.services.immich.database.user;
  immichDbUrl = "postgresql:///${immichDbName}?host=/run/postgresql";
  immichConfigFile = "/run/immich/config.json";
  redisSocket = "/run/redis-immich/redis.sock";
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
    path = with pkgs; [
      coreutils
      gnugrep
      gnused
      jq
      kanidm_1_9
      postgresql
      util-linux
    ];
    serviceConfig.Type = "oneshot";
    script = ''
      set -euo pipefail

      export HOME="$(${pkgs.coreutils}/bin/mktemp -d)"
      trap '${pkgs.coreutils}/bin/rm -rf "$HOME"' EXIT
      export KANIDM_PASSWORD="$(< ${config.age.secrets.kanidmAdminPass.path})"

      ${pkgs.kanidm_1_9}/bin/kanidm login \
        -H ${kanidmCliUrl} \
        -D idm_admin >/dev/null

      mapfile -t desired_admin_emails < <(
        ${pkgs.kanidm_1_9}/bin/kanidm group get \
          app-admin \
          -H ${kanidmCliUrl} \
          -D idm_admin \
          -o json \
          | ${pkgs.jq}/bin/jq -r '.attrs.member[]? | split("@")[0]' \
          | ${pkgs.coreutils}/bin/sort -u \
          | while IFS= read -r username; do
              [[ -n "$username" ]] || continue
              ${pkgs.kanidm_1_9}/bin/kanidm person get \
                "$username" \
                -H ${kanidmCliUrl} \
                -D idm_admin \
                -o json \
                | ${pkgs.jq}/bin/jq -r '(.attrs.mail[0] // .attrs.email[0] // empty)'
            done \
          | ${pkgs.gnused}/bin/sed '/^$/d' \
          | ${pkgs.coreutils}/bin/sort -u
      )

      mapfile -t current_admin_emails < <(
        ${pkgs.util-linux}/bin/runuser -u ${config.services.immich.user} -- \
          ${pkgs.postgresql}/bin/psql \
            "dbname=${immichDbName} host=/run/postgresql user=${immichDbUser}" \
            -At \
            -c "select email from users where char_length(\"oauthId\") > 0 and \"isAdmin\" = true order by email;"
      )

      run_immich_admin() {
        local command="$1"
        local email="$2"

        printf '%s\n' "$email" | ${pkgs.util-linux}/bin/runuser -u ${config.services.immich.user} -- \
          ${pkgs.coreutils}/bin/env \
            DB_URL=${immichDbUrl} \
            IMMICH_CONFIG_FILE=${immichConfigFile} \
            IMMICH_MEDIA_LOCATION=${vars.immichManagedRoot} \
            REDIS_SOCKET=${redisSocket} \
            ${config.services.immich.package}/bin/immich-admin "$command"
      }

      contains_line() {
        local needle="$1"
        shift || true
        printf '%s\n' "$@" | ${pkgs.gnugrep}/bin/grep -Fxq -- "$needle"
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
