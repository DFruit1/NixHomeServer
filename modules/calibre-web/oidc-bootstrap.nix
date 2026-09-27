{ config, lib, pkgs, vars, ... }:

let
  cfg = config.repo.calibreWeb;
  usersFile = pkgs.writeText "calibre-web-oidc-users.json"
    (builtins.toJSON vars.kanidmAppUsers);
  bootstrapScript = pkgs.writeText "calibre-web-oidc-account-bootstrap.py" ''
    import hashlib
    import json
    import secrets
    import sqlite3
    import sys

    database_path, users_path = sys.argv[1:]
    with open(users_path, encoding="utf-8") as users_file:
        users = json.load(users_file)

    connection = sqlite3.connect(database_path, timeout=30)
    connection.execute("PRAGMA busy_timeout = 30000")

    try:
        tables = {
            row[0]
            for row in connection.execute(
                "SELECT name FROM sqlite_master WHERE type = 'table'"
            )
        }
        if "user" not in tables:
            raise RuntimeError("Calibre-Web user table is not ready")

        columns = {
            row[1] for row in connection.execute('PRAGMA table_info("user")')
        }
        required = {
            "name", "email", "role", "password", "kindle_mail", "locale",
            "sidebar_view", "default_language", "denied_tags", "allowed_tags",
            "denied_column_value", "allowed_column_value", "view_settings",
            "kobo_only_shelves_sync",
        }
        if not required.issubset(columns):
            missing = ", ".join(sorted(required - columns))
            raise RuntimeError(
                "Unsupported Calibre-Web user schema; missing columns: " + missing
            )

        connection.execute("BEGIN IMMEDIATE")
        created = 0
        seen = set()
        for username in users:
            if not isinstance(username, str) or not username:
                raise RuntimeError("Invalid username in Kanidm app user list")
            normalized_username = username.casefold()
            if normalized_username in seen:
                raise RuntimeError(
                    "Duplicate case-insensitive Kanidm username: " + username
                )
            seen.add(normalized_username)
            if normalized_username == "admin":
                raise RuntimeError(
                    "Kanidm username 'admin' conflicts with Calibre-Web's local admin account"
                )

            existing = connection.execute(
                'SELECT id, role FROM "user" WHERE lower(name) = lower(?)',
                (username,),
            ).fetchone()
            if existing:
                if (existing[1] or 0) & 1:
                    raise RuntimeError(
                        "Managed Calibre-Web account has admin privileges: " + username
                    )
                connection.execute(
                    'UPDATE "user" SET role = 2 WHERE id = ?', (existing[0],)
                )
                continue

            password = secrets.token_urlsafe(48)
            salt = secrets.token_urlsafe(16)
            password_hash = "pbkdf2:sha256:600000$" + salt + "$" + hashlib.pbkdf2_hmac(
                "sha256", password.encode(), salt.encode(), 600000
            ).hex()
            connection.execute(
                """
                INSERT INTO "user" (
                    name, email, role, password, kindle_mail, locale,
                    sidebar_view, default_language, denied_tags, allowed_tags,
                    denied_column_value, allowed_column_value, view_settings,
                    kobo_only_shelves_sync
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    username,
                    None,
                    2,
                    password_hash,
                    "",
                    "en",
                    0,
                    "all",
                    "",
                    "",
                    "",
                    "",
                    "{}",
                    0,
                ),
            )
            created += 1

        connection.commit()
        print(f"Calibre-Web OIDC account bootstrap converged; created {created} account(s)")
    except Exception:
        connection.rollback()
        raise
    finally:
        connection.close()
  '';
in
{
  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = !(lib.any (username: lib.toLower username == "admin") vars.kanidmAppUsers);
        message = "Calibre-Web OIDC account provisioning cannot map the Kanidm username 'admin' because it is reserved for Calibre-Web's local administrator.";
      }
    ];

    systemd.services.calibre-web-oidc-account-bootstrap = {
      description = "Provision Calibre-Web accounts for Kanidm users";
      wantedBy = [ "multi-user.target" ];
      requires = [ "calibre-web.service" ];
      after = [ "calibre-web.service" ];
      before = [ "calibre-web-oauth2-proxy.service" ];
      path = [ pkgs.python3 ];
      script = ''
        set -euo pipefail
        python3 ${bootstrapScript} ${lib.escapeShellArg "${cfg.paths.stateDir}/app.db"} ${usersFile}
      '';
      serviceConfig = {
        Type = "oneshot";
        User = "calibre-web";
        Group = "calibre-web";
        UMask = "0077";
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ReadWritePaths = [ cfg.paths.stateDir ];
      };
    };
  };
}
