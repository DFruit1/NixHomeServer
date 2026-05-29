{ config, lib, pkgs, vars, ... }:

let
  kanidmDb = "/var/lib/kanidm/kanidm.db";
  immichDbName = config.services.immich.database.name;
  immichDbUser = config.services.immich.database.user;
  adminMailAddresses =
    if vars.kanidmAdminMailAddresses != [ ] then
      vars.kanidmAdminMailAddresses
    else
      [ vars.kanidmAdminEmail ];
  managedUsers = vars.kanidmAppUsers or [ ];
  userEmailCase = lib.concatMapStringsSep "\n"
    (user:
      let
        email =
          if user == vars.kanidmAdminUser then
            builtins.head adminMailAddresses
          else if builtins.hasAttr user vars.kanidmAppUserEmails then
            vars.kanidmAppUserEmails.${user}
          else
            "";
      in
      "${lib.escapeShellArg user}) mail=${lib.escapeShellArg email} ;;"
    )
    managedUsers;
in
{
  config = {
    systemd.services.immich-oidc-reconcile = {
      description = "Reconcile Immich OIDC links from Kanidm identities";
      wantedBy = [ "multi-user.target" ];
      before = [
        "immich-server.service"
        "immich-admin-reconcile.service"
      ];
      after = [
        "kanidm.service"
        "postgresql.service"
      ];
      wants = [
        "kanidm.service"
        "postgresql.service"
      ];
      path = [
        pkgs.coreutils
        pkgs.postgresql
        pkgs.sqlite
        pkgs.util-linux
      ];
      serviceConfig = {
        Type = "oneshot";
      };
      script = ''
        set -euo pipefail

        kanidm_db=${lib.escapeShellArg kanidmDb}
        if [[ ! -f "$kanidm_db" ]]; then
          echo "Kanidm database not found at $kanidm_db; skipping Immich OIDC reconciliation" >&2
          exit 0
        fi

        table_exists="$(
          runuser -u ${config.services.immich.user} -- \
            psql \
              "dbname=${immichDbName} host=/run/postgresql user=${immichDbUser}" \
              -At \
              -c "select to_regclass('public.\"user\"') is not null;" \
              2>/dev/null || true
        )"
        if [[ "$table_exists" != "t" ]]; then
          echo "Immich user table is not ready; skipping OIDC reconciliation" >&2
          exit 0
        fi

        reconcile_user() {
          local username="$1"
          local mail="$2"
          local kanidm_uuid updated

          [[ -n "$username" && -n "$mail" ]] || return 0

          kanidm_uuid="$(
            sqlite3 -readonly "$kanidm_db" \
              "select uuid from idx_name2uuid where name = '$username';" \
              2>/dev/null || true
          )"
          [[ -n "$kanidm_uuid" ]] || return 0

          updated="$(
            runuser -u ${config.services.immich.user} -- \
              psql \
                "dbname=${immichDbName} host=/run/postgresql user=${immichDbUser}" \
                -At <<SQL
with updated as (
  update "user"
     set "oauthId" = '$kanidm_uuid',
         email = '$mail',
         "updatedAt" = now()
   where "deletedAt" is null
     and (
       lower(email) = lower('$mail')
       or "storageLabel" = '$username'
       or ('$username' = '${vars.kanidmAdminUser}' and "storageLabel" = 'admin')
       or name = '$username'
     )
     and ("oauthId" <> '$kanidm_uuid' or email <> '$mail')
   returning id
)
select count(*) from updated;
SQL
          )"

          if [[ "$updated" != "0" ]]; then
            echo "Immich OIDC reconcile updated $username"
          fi
        }

        for username in ${lib.escapeShellArgs managedUsers}; do
          mail=""
          case "$username" in
            ${userEmailCase}
          esac
          reconcile_user "$username" "$mail"
        done
      '';
    };

    systemd.timers.immich-oidc-reconcile = {
      description = "Periodically reconcile Immich OIDC links from Kanidm";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "2m";
        OnUnitActiveSec = "15m";
        Unit = "immich-oidc-reconcile.service";
      };
    };

    systemd.services.immich-server = {
      wants = [ "immich-oidc-reconcile.service" ];
      after = [ "immich-oidc-reconcile.service" ];
    };
  };
}
