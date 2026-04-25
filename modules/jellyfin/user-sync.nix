{ config, pkgs, vars, ... }:

let
  jellyfinPort = 8096;
  kanidmPort = 8443;
  dataDir = "/var/lib/jellyfin";
  dbPath = "${dataDir}/data/jellyfin.db";
  managedDir = "${dataDir}/.nixos-managed";
  desiredPasswordDir = "${managedDir}/desired-password-hashes";
  syncScript = pkgs.writeShellScript "jellyfin-user-sync-v1" ''
    set -euo pipefail

    managed_dir="${managedDir}"
    bootstrap_password_file="$managed_dir/admin-bootstrap-password"

    ${pkgs.coreutils}/bin/install -d -m 0700 "$managed_dir" '${desiredPasswordDir}'

    if [[ ! -f "$bootstrap_password_file" ]]; then
      ${pkgs.python3}/bin/python3 - <<'PY' > "$bootstrap_password_file"
import secrets
print(secrets.token_urlsafe(24))
PY
      chmod 0600 "$bootstrap_password_file"
    fi

    bootstrap_password="$(< "$bootstrap_password_file")"

    ensure_bootstrap_password() {
      local state
      state="$(${pkgs.python3}/bin/python3 - "${dbPath}" '${vars.kanidmAdminUser}' "$bootstrap_password" <<'PY'
import hashlib
import os
import sqlite3
import sys

db_path, username, password = sys.argv[1:]

def hash_password(value: str) -> str:
    salt = os.urandom(16)
    iterations = 210000
    derived = hashlib.pbkdf2_hmac("sha512", value.encode(), salt, iterations)
    return f"$PBKDF2-SHA512$iterations={iterations}''${salt.hex().upper()}''${derived.hex().upper()}"

def verify_password(value: str, stored: str | None) -> bool:
    if not stored or not stored.startswith("$PBKDF2-SHA512$"):
        return False
    parts = stored.split("$")
    if len(parts) != 5 or not parts[2].startswith("iterations="):
        return False
    iterations = int(parts[2].split("=", 1)[1])
    salt = bytes.fromhex(parts[3])
    expected = parts[4].upper()
    actual = hashlib.pbkdf2_hmac("sha512", value.encode(), salt, iterations).hex().upper()
    return actual == expected

connection = sqlite3.connect(db_path)
cursor = connection.cursor()
row = cursor.execute(
    "select Password from Users where Username = ? limit 1",
    (username,),
).fetchone()
if row is None:
    print("missing")
    sys.exit(0)
if verify_password(password, row[0]):
    print("unchanged")
    sys.exit(0)
cursor.execute(
    "update Users set Password = ?, InvalidLoginAttemptCount = 0, MustUpdatePassword = 0 where Username = ?",
    (hash_password(password), username),
)
connection.commit()
print("updated")
PY
)"

      case "$state" in
        unchanged)
          ;;
        updated)
          /run/current-system/sw/bin/systemctl restart jellyfin.service
          ;;
        missing)
          echo "Jellyfin admin user ${vars.kanidmAdminUser} does not exist yet" >&2
          exit 1
          ;;
        *)
          echo "Unexpected Jellyfin bootstrap password state: $state" >&2
          exit 1
          ;;
      esac
    }

    wait_for_jellyfin() {
      local status_json=""
      for _ in $(seq 1 60); do
        status_json="$(${pkgs.curl}/bin/curl --silent --show-error \
          "http://127.0.0.1:${toString jellyfinPort}/System/Info/Public" 2>/dev/null || true)"
        if [[ -n "$status_json" ]] \
          && printf '%s' "$status_json" | ${pkgs.jq}/bin/jq -e '.StartupWizardCompleted != null' >/dev/null 2>&1; then
          return 0
        fi
        sleep 2
      done
      echo "Jellyfin did not become ready in time" >&2
      exit 1
    }

    authenticate_admin() {
      local auth_json=""
      for _ in $(seq 1 60); do
        auth_json="$(${pkgs.curl}/bin/curl --silent --show-error \
          -X POST \
          -H 'Content-Type: application/json' \
          -H 'X-Emby-Authorization: MediaBrowser Client="nixos-jellyfin-user-sync", Device="nixos-jellyfin-user-sync", DeviceId="nixos-jellyfin-user-sync", Version="1.0.0"' \
          --data "$(${pkgs.jq}/bin/jq -cn \
            --arg username '${vars.kanidmAdminUser}' \
            --arg password "$bootstrap_password" \
            '{ Username: $username, Pw: $password }')" \
          "http://127.0.0.1:${toString jellyfinPort}/Users/AuthenticateByName" 2>/dev/null || true)"
        token="$(printf '%s' "$auth_json" | ${pkgs.jq}/bin/jq -r '.AccessToken // empty' 2>/dev/null || true)"
        if [[ -n "$token" ]]; then
          printf '%s\n' "$token"
          return 0
        fi
        sleep 2
      done
      echo "Failed to authenticate the managed Jellyfin admin user" >&2
      exit 1
    }

    ensure_bootstrap_password
    wait_for_jellyfin

    export HOME="$(mktemp -d)"
    trap 'rm -rf "$HOME"' EXIT
    export KANIDM_PASSWORD="$(< ${config.age.secrets.kanidmSysAdminPass.path})"

    login_group_json="$(
      ${pkgs.kanidm_1_9}/bin/kanidm login \
        -H https://localhost:${toString kanidmPort} \
        -D admin \
        --accept-invalid-certs >/dev/null

      ${pkgs.kanidm_1_9}/bin/kanidm group get \
        jellyfin-users \
        -H https://localhost:${toString kanidmPort} \
        -D admin \
        --accept-invalid-certs \
        -o json
    )"

    admin_group_json="$(
      ${pkgs.kanidm_1_9}/bin/kanidm group get \
        jellyfin-admin \
        -H https://localhost:${toString kanidmPort} \
        -D admin \
        --accept-invalid-certs \
        -o json
    )"

    login_users_file="$(mktemp)"
    admin_users_file="$(mktemp)"
    desired_users_file="$(mktemp)"

    printf '%s' "$login_group_json" \
      | ${pkgs.jq}/bin/jq -r '.attrs.member[]? | split("@")[0]' \
      | ${pkgs.coreutils}/bin/sort -u > "$login_users_file"

    printf '%s' "$admin_group_json" \
      | ${pkgs.jq}/bin/jq -r '.attrs.member[]? | split("@")[0]' \
      | ${pkgs.coreutils}/bin/sort -u > "$admin_users_file"

    cat "$login_users_file" "$admin_users_file" | ${pkgs.coreutils}/bin/sort -u > "$desired_users_file"

    token="$(authenticate_admin)"
    auth_header="Authorization: MediaBrowser Token=$token"

    users_json="$(${pkgs.curl}/bin/curl --silent --show-error --fail \
      -H "$auth_header" \
      "http://127.0.0.1:${toString jellyfinPort}/Users")"

    create_user() {
      local username="$1"
      local temp_password
      temp_password="$(${pkgs.python3}/bin/python3 - <<'PY'
import secrets
print(secrets.token_urlsafe(32))
PY
)"
      ${pkgs.curl}/bin/curl --silent --show-error --fail \
        -X POST \
        -H "$auth_header" \
        -H 'Content-Type: application/json' \
        --data "$(${pkgs.jq}/bin/jq -cn \
          --arg username "$username" \
          --arg password "$temp_password" \
          '{ Name: $username, Password: $password }')" \
        "http://127.0.0.1:${toString jellyfinPort}/Users/New" >/dev/null
    }

    set_admin_flag() {
      local user_id="$1"
      local is_admin="$2"
      local user_json
      local policy_json

      user_json="$(${pkgs.curl}/bin/curl --silent --show-error --fail \
        -H "$auth_header" \
        "http://127.0.0.1:${toString jellyfinPort}/Users/$user_id")"

      policy_json="$(
        printf '%s' "$user_json" \
          | ${pkgs.jq}/bin/jq -c --argjson is_admin "$is_admin" '
            .Policy
            | .IsAdministrator = $is_admin
          '
      )"

      ${pkgs.curl}/bin/curl --silent --show-error --fail \
        -X POST \
        -H "$auth_header" \
        -H 'Content-Type: application/json' \
        --data "$policy_json" \
        "http://127.0.0.1:${toString jellyfinPort}/Users/$user_id/Policy" >/dev/null
    }

    while IFS= read -r username; do
      [[ -n "$username" ]] || continue

      current_user="$(
        printf '%s' "$users_json" \
          | ${pkgs.jq}/bin/jq -c --arg username "$username" '.[] | select(.Name == $username)'
      )"

      if [[ -z "$current_user" ]]; then
        create_user "$username"
        users_json="$(${pkgs.curl}/bin/curl --silent --show-error --fail \
          -H "$auth_header" \
          "http://127.0.0.1:${toString jellyfinPort}/Users")"
        current_user="$(
          printf '%s' "$users_json" \
            | ${pkgs.jq}/bin/jq -c --arg username "$username" '.[] | select(.Name == $username)'
        )"
      fi

      [[ -n "$current_user" ]] || {
        echo "Unable to converge Jellyfin user '$username'" >&2
        exit 1
      }

      user_id="$(printf '%s' "$current_user" | ${pkgs.jq}/bin/jq -r '.Id')"
      if ${pkgs.gnugrep}/bin/grep -Fxq "$username" "$admin_users_file"; then
        set_admin_flag "$user_id" true
      else
        set_admin_flag "$user_id" false
      fi
    done < "$desired_users_file"

    ${pkgs.python3}/bin/python3 - "${dbPath}" '${desiredPasswordDir}' <<'PY'
import pathlib
import sqlite3
import sys

db_path = sys.argv[1]
password_dir = pathlib.Path(sys.argv[2])

connection = sqlite3.connect(db_path)
cursor = connection.cursor()

for path in sorted(password_dir.glob("*.pbkdf2")):
    username = path.stem
    password_hash = path.read_text(encoding="utf-8").strip()
    cursor.execute(
        "update Users set Password = ?, InvalidLoginAttemptCount = 0, MustUpdatePassword = 0 where Username = ?",
        (password_hash, username),
    )

connection.commit()
PY
  '';
in
{
  systemd.services.jellyfin-user-sync-v1 = {
    description = "Synchronize Jellyfin managed local users";
    wantedBy = [ "multi-user.target" ];
    wants = [
      "jellyfin.service"
      "data-pool-layout.service"
      "kanidm.service"
    ];
    after = [
      "jellyfin.service"
      "data-pool-layout.service"
      "kanidm.service"
    ];
    unitConfig.ConditionPathIsMountPoint = vars.dataRoot;
    serviceConfig = {
      Type = "oneshot";
      WorkingDirectory = dataDir;
    };
    script = ''
      ${syncScript}
    '';
  };

  systemd.timers.jellyfin-user-sync-v1 = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* *:*:00";
      Persistent = true;
    };
  };
}
