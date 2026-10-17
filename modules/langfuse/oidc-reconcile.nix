{ config, lib, pkgs, vars, ... }:

let
  cfg = config.repo.langfuse;
  kanidmDb = "/var/lib/kanidm/kanidm.db";
  adminMailAddresses =
    if vars.kanidmAdminMailAddresses != [ ] then
      vars.kanidmAdminMailAddresses
    else
      [ vars.kanidmAdminEmail ];
  managedUsers = vars.kanidmAppUsers or [ ];
  # Langfuse links SSO and password accounts by email address, and signup is
  # disabled, so a Kanidm user can only sign in if their Langfuse account
  # already carries the mail address Kanidm presents. The password owner is
  # created by headless initialization with the local administrator's address;
  # this keeps the two in step, matching the reconcile step other OIDC apps use.
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
      "${lib.escapeShellArg user}) mail=${lib.escapeShellArg email} ;;")
    managedUsers;
in
{
  config = lib.mkIf cfg.enable {
    systemd.services.langfuse-oidc-reconcile = {
      description = "Align Langfuse accounts with Kanidm identities for SSO";
      wantedBy = [ "multi-user.target" ];
      after = [
        "kanidm.service"
        "postgresql.service"
        "langfuse-web.service"
      ];
      wants = [
        "kanidm.service"
        "postgresql.service"
      ];
      path = [
        pkgs.coreutils
        pkgs.gnugrep
        pkgs.sqlite
        pkgs.util-linux
        config.services.postgresql.package
      ];
      serviceConfig = {
        Type = "oneshot";
        Nice = 10;
        CPUWeight = 20;
        IOWeight = 20;
        MemoryHigh = "64M";
        MemoryMax = "128M";
      };
      script = ''
        set -euo pipefail

        kanidm_db=${lib.escapeShellArg kanidmDb}
        if [[ ! -f "$kanidm_db" ]]; then
          echo "Kanidm database not found at $kanidm_db; skipping Langfuse SSO reconciliation" >&2
          exit 0
        fi

        ready="$(
          runuser -u postgres -- psql --no-psqlrc -d langfuse -Atc \
            "select to_regclass('public.users') is not null;" 2>/dev/null || true
        )"
        if [[ "$ready" != "t" ]]; then
          echo "Langfuse users table is not ready; skipping SSO reconciliation" >&2
          exit 0
        fi

        reconcile_user() {
          local username="$1"
          local mail="$2"
          local kanidm_uuid updated username_hex

          [[ -n "$username" && -n "$mail" ]] || return 0

          username_hex="$(printf '%s' "$username" | od -An -tx1 | tr -d ' \n')"
          kanidm_uuid="$(
            sqlite3 -readonly "$kanidm_db" \
              "select uuid from idx_name2uuid where name = cast(X'$username_hex' as text);" \
              2>/dev/null || true
          )"
          [[ -n "$kanidm_uuid" ]] || return 0

          updated="$(
            runuser -u postgres -- \
              psql --no-psqlrc \
                --set=ON_ERROR_STOP=1 \
                --set=mail="$mail" \
                --set=username="$username" \
                -d langfuse -At <<SQL
        with updated as (
          update users
             set email = :'mail',
                 updated_at = now()
           where lower(name) = lower(:'username')
             and email is distinct from :'mail'
           returning id
        )
        select count(*) from updated;
        SQL
          )"

          if [[ "$updated" != "0" ]]; then
            echo "Langfuse SSO reconcile aligned $username"
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

    # The owner row appears only after langfuse-web first runs headless
    # initialization, so converge on boot and then periodically rather than
    # blocking the web service on a row that does not exist yet.
    systemd.timers.langfuse-oidc-reconcile = {
      description = "Periodically align Langfuse accounts with Kanidm identities";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "2m";
        OnUnitActiveSec = "1h";
        Unit = "langfuse-oidc-reconcile.service";
      };
    };
  };
}
