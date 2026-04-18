{ lib, config, pkgs, vars, ... }:

let
  audiobookshelfPort = 13378;
in
{
  services.audiobookshelf = {
    enable = true;
    dataDir = vars.audiobookshelfDataDir;
    port = audiobookshelfPort;
  };

  ## Ensure runtime directory exists and is the service cwd
  systemd.services.audiobookshelf = {
    after = [ "audiobookshelf-storage-migration-v1.service" ];
    wants = [ "audiobookshelf-storage-migration-v1.service" ];
    serviceConfig = {
      WorkingDirectory = lib.mkForce vars.audiobookshelfDataDir;
    };
  };

  systemd.services.audiobookshelf-storage-migration-v1 = {
    description = "Normalize Audiobookshelf storage paths after migration";
    before = [
      "audiobookshelf.service"
      "audiobookshelf-oidc-bootstrap-v1.service"
      "audiobookshelf-root-bootstrap-v1.service"
    ];
    wantedBy = [ "multi-user.target" ];
    path = with pkgs; [
      coreutils
      jq
      sqlite
    ];
    serviceConfig = {
      Type = "oneshot";
      User = "audiobookshelf";
      Group = "audiobookshelf";
    };
    script = ''
      set -euo pipefail

      db="${vars.audiobookshelfConfigDir}/absdatabase.sqlite"
      legacy_root="${vars.dataRoot}/audiobookshelf"
      data_dir="${vars.audiobookshelfDataDir}"
      backup_dir="${vars.audiobookshelfBackupDir}"
      managed_dir="${vars.audiobookshelfDataDir}/.nixos-managed"
      marker_file="$managed_dir/audiobookshelf-storage-migration-v1.done"

      install -d -m 0755 \
        "${vars.audiobookshelfConfigDir}" \
        "${vars.audiobookshelfMetadataDir}" \
        "$backup_dir" \
        "$managed_dir"

      if [[ -f "$marker_file" ]]; then
        echo "Audiobookshelf storage migration v1 already applied"
        exit 0
      fi

      [[ -f "$db" ]] || exit 0

      current="$(${pkgs.sqlite}/bin/sqlite3 -readonly "$db" \
        "select value from settings where key = 'server-settings';")"
      [[ -n "$current" ]] || exit 0

      updated="$(printf '%s' "$current" | ${pkgs.jq}/bin/jq -c \
        --arg legacyRoot "$legacy_root" \
        --arg dataDir "$data_dir" \
        --arg backupDir "$backup_dir" \
        '
          walk(
            if type == "string" then
              gsub($legacyRoot; $dataDir)
            else
              .
            end
          )
          | .backupPath = $backupDir
        ')"

      if [[ "$current" == "$updated" ]]; then
        echo "Audiobookshelf storage migration v1 already converged"
        touch "$marker_file"
        exit 0
      fi

      escaped="$(
        printf '%s' "$updated" |
          ${pkgs.perl}/bin/perl -pe 's/\x27/\x27\x27/g'
      )"

      ${pkgs.sqlite}/bin/sqlite3 "$db" \
        "update settings set value = '$escaped' where key = 'server-settings';"
      ${pkgs.sqlite}/bin/sqlite3 "$db" \
        "update settings set updatedAt = datetime('now') where key = 'server-settings';"

      echo "Audiobookshelf storage migration v1 updated stored paths"
      touch "$marker_file"
    '';
  };

  systemd.services.audiobookshelf-oidc-bootstrap-v1 = {
    description = "Synchronize Audiobookshelf OIDC settings";
    wantedBy = [ "multi-user.target" ];
    after = [
      "audiobookshelf.service"
      "caddy.service"
      "kanidm.service"
    ];
    wants = [
      "audiobookshelf.service"
      "caddy.service"
      "kanidm.service"
    ];
    path = with pkgs; [
      curl
      jq
      sqlite
    ];
    script = ''
      set -euo pipefail

      db="${vars.audiobookshelfDataDir}/config/absdatabase.sqlite"
      managed_dir="${vars.audiobookshelfDataDir}/.nixos-managed"
      marker_file="$managed_dir/audiobookshelf-oidc-bootstrap-v1.done"

      install -d -m 0755 "$managed_dir"

      if [[ -f "$marker_file" ]]; then
        echo "Audiobookshelf OIDC bootstrap v1 already applied"
        exit 0
      fi

      for _ in $(seq 1 30); do
        [[ -f "$db" ]] && break
        sleep 1
      done
      [[ -f "$db" ]] || {
        echo "Audiobookshelf database not found at $db" >&2
        exit 1
      }

      discovery="$(${pkgs.curl}/bin/curl --silent --show-error --fail \
        --resolve '${vars.kanidmDomain}:443:127.0.0.1' \
        '${vars.kanidmDiscoveryUrl "abs-web"}')"
      client_secret="$(< ${config.age.secrets.absClientSecret.path})"
      current="$(${pkgs.sqlite}/bin/sqlite3 -readonly "$db" \
        "select value from settings where key = 'server-settings';")"
      [[ -n "$current" ]] || {
        echo "Audiobookshelf server-settings row is missing" >&2
        exit 1
      }

      updated="$(printf '%s' "$current" | ${pkgs.jq}/bin/jq -c \
        --arg clientId "abs-web" \
        --arg clientSecret "$client_secret" \
        --arg buttonText "Login with Kanidm" \
        --arg subfolder "/audiobookshelf" \
        --argjson discovery "$discovery" \
        '
          .authActiveAuthMethods = (((.authActiveAuthMethods // []) + ["openid"]) | unique)
          | .authOpenIDIssuerURL = $discovery.issuer
          | .authOpenIDAuthorizationURL = $discovery.authorization_endpoint
          | .authOpenIDTokenURL = $discovery.token_endpoint
          | .authOpenIDUserInfoURL = $discovery.userinfo_endpoint
          | .authOpenIDJwksURL = $discovery.jwks_uri
          | .authOpenIDLogoutURL = ($discovery.end_session_endpoint // null)
          | .authOpenIDClientID = $clientId
          | .authOpenIDClientSecret = $clientSecret
          | .authOpenIDTokenSigningAlgorithm = (($discovery.id_token_signing_alg_values_supported // ["ES256"]) | .[0])
          | .authOpenIDButtonText = $buttonText
          | .authOpenIDAutoLaunch = false
          | .authOpenIDAutoRegister = true
          | .authOpenIDMatchExistingBy = "username"
          | .authOpenIDMobileRedirectURIs = ["audiobookshelf://oauth"]
          | .authOpenIDGroupClaim = ""
          | .authOpenIDAdvancedPermsClaim = ""
          | .authOpenIDSubfolderForRedirectURLs = $subfolder
        ')"

      if [[ "$current" == "$updated" ]]; then
        echo "Audiobookshelf OIDC bootstrap v1 already converged"
        touch "$marker_file"
        exit 0
      fi

      escaped="$(printf '%s' "$updated" | ${pkgs.perl}/bin/perl -pe 's/\x27/\x27\x27/g')"
      ${pkgs.sqlite}/bin/sqlite3 "$db" \
        "update settings set value = '$escaped' where key = 'server-settings';"

      echo "Audiobookshelf OIDC bootstrap v1 updated managed auth settings"
      touch "$marker_file"
      /run/current-system/sw/bin/systemctl restart audiobookshelf.service
    '';
  };

  systemd.services.audiobookshelf-root-bootstrap-v1 = {
    description = "Bootstrap Audiobookshelf root account for OIDC linking";
    wantedBy = [ "multi-user.target" ];
    after = [
      "audiobookshelf.service"
      "audiobookshelf-oidc-bootstrap-v1.service"
    ];
    wants = [
      "audiobookshelf.service"
      "audiobookshelf-oidc-bootstrap-v1.service"
    ];
    path = with pkgs; [
      curl
      jq
    ];
    script = ''
      set -euo pipefail

      managed_dir="${vars.audiobookshelfDataDir}/.nixos-managed"
      marker_file="$managed_dir/audiobookshelf-root-bootstrap-v1.done"
      status_json=""

      install -d -m 0755 "$managed_dir"

      if [[ -f "$marker_file" ]]; then
        echo "Audiobookshelf root bootstrap v1 already applied"
        exit 0
      fi

      for _ in $(seq 1 30); do
        if status_json="$(${pkgs.curl}/bin/curl --silent --show-error --fail \
          "http://127.0.0.1:${toString audiobookshelfPort}/status")"; then
          break
        fi
        sleep 1
      done

      [[ -n "$status_json" ]] || {
        echo "Audiobookshelf status endpoint did not become ready" >&2
        exit 1
      }

      if printf '%s' "$status_json" | ${pkgs.jq}/bin/jq -e '.isInit == true' >/dev/null; then
        echo "Audiobookshelf root bootstrap v1 already converged"
        touch "$marker_file"
        exit 0
      fi

      bootstrap_password="$(< ${config.age.secrets.absBootstrapPass.path})"

      ${pkgs.curl}/bin/curl \
        --silent \
        --show-error \
        --fail \
        -X POST \
        -H 'Content-Type: application/json' \
        --data "$(${pkgs.jq}/bin/jq -cn \
          --arg username '${vars.kanidmAdminUser}' \
          --arg password "$bootstrap_password" \
          '{ newRoot: { username: $username, password: $password } }')" \
        "http://127.0.0.1:${toString audiobookshelfPort}/init"

      status_json="$(${pkgs.curl}/bin/curl --silent --show-error --fail \
        "http://127.0.0.1:${toString audiobookshelfPort}/status")"

      printf '%s' "$status_json" | ${pkgs.jq}/bin/jq -e '.isInit == true' >/dev/null || {
        echo "Audiobookshelf root bootstrap did not complete successfully" >&2
        exit 1
      }

      echo "Audiobookshelf root bootstrap v1 initialized the local root record"
      touch "$marker_file"
    '';
  };

  systemd.tmpfiles.rules = [ ];
}
