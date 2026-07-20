{ config, lib, pkgs, vars, ... }:

let
  stateDir = config.repo.files.paths.stateDir;
  managedDir = "${stateDir}/.nixos-managed";
  secretRuntimeDir = "/run/filestash-secrets";
  secretKeyFile = "${managedDir}/secret-key";
  adminPasswordFile = "${managedDir}/admin-password";
  adminPasswordHashFile = "${managedDir}/admin-password.bcrypt";
  identitySecretStateDir = "/persist/appdata/kanidm-app-secrets";
  oauth2ClientSecretStateFile = "${identitySecretStateDir}/filestash-oauth2-client-secret";
  oauth2CookieSecretStateFile = "${managedDir}/oauth2-cookie-secret";
  sftpClientKeyFile = "${managedDir}/sftp-client-key";
  sftpAuthorizedKeysDir = "/run/files-sftp-authorized-keys";
  sftpUsers =
    lib.unique (
      [ vars.localAdminUser ]
      ++ (vars.kanidmAppUsers or [ ])
      ++ (vars.filesSftpUsers or [ ])
      ++ (vars.kanidmBackupUsers or [ ])
      ++ (vars.fileAccessUsbUsers or [ ])
    );
  oauth2ClientSecretFile = "${secretRuntimeDir}/oauth2-client-secret";
  oauth2ClientSecretKanidmFile = "${secretRuntimeDir}/oauth2-client-secret-kanidm";
  oauth2CookieSecretFile = "${secretRuntimeDir}/oauth2-cookie-secret";
  pythonWithBcrypt = pkgs.python3.withPackages (ps: [ ps.bcrypt ]);
in
{
  config = {
    systemd.services.filestash-identity-secret-materialize = {
      description = "Materialize the Filestash OAuth identity secret independently of application state";
      wantedBy = [ "multi-user.target" ];
      before = [
        "filestash-secret-materialize.service"
        "kanidm.service"
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        Restart = "on-failure";
        RestartSec = "10s";
      };
      path = [ pkgs.coreutils pkgs.openssl ];
      script = ''
        set -euo pipefail

        install -d -m 0700 -o root -g root ${lib.escapeShellArg identitySecretStateDir}
        install -d -m 0755 -o root -g root ${lib.escapeShellArg secretRuntimeDir}
        if [[ ! -s ${lib.escapeShellArg oauth2ClientSecretStateFile} ]]; then
          umask 0077
          openssl rand -hex 32 | tr -d '\n' > ${lib.escapeShellArg oauth2ClientSecretStateFile}
        fi

        normalized="$(tr -d '\r\n' < ${lib.escapeShellArg oauth2ClientSecretStateFile})"
        [[ -n "$normalized" ]] || {
          echo "Filestash OAuth client secret is empty" >&2
          exit 1
        }
        umask 0077
        printf '%s' "$normalized" > ${lib.escapeShellArg oauth2ClientSecretStateFile}
        install -m 0440 -o root -g oauth2-proxy ${lib.escapeShellArg oauth2ClientSecretStateFile} ${lib.escapeShellArg oauth2ClientSecretFile}
        install -m 0440 -o root -g kanidm ${lib.escapeShellArg oauth2ClientSecretStateFile} ${lib.escapeShellArg oauth2ClientSecretKanidmFile}
      '';
    };

    systemd.services.filestash-secret-materialize = {
      description = "Materialize Filestash runtime secrets";
      wantedBy = [ "multi-user.target" ];
      before = [
        "filestash.service"
        "filestash-oauth2-proxy.service"
      ];
      requires = [ "filestash-identity-secret-materialize.service" ];
      after = [ "filestash-identity-secret-materialize.service" ];
      serviceConfig = {
        Type = "oneshot";
        Restart = "on-failure";
        RestartSec = "10s";
      };
      path = [
        pkgs.coreutils
        pkgs.openssh
        pkgs.openssl
        pythonWithBcrypt
      ];
      script = ''
        set -euo pipefail

        install -d -m 0750 -o root -g filestash ${lib.escapeShellArg managedDir}
        install -d -m 0755 -o root -g root ${lib.escapeShellArg secretRuntimeDir}
        install -d -m 0755 -o root -g root ${lib.escapeShellArg sftpAuthorizedKeysDir}

        generate_secret() {
          local path="$1"
          local generator="$2"
          if [ ! -s "$path" ]; then
            umask 0077
            eval "$generator" > "$path"
          fi
        }

        generate_secret ${lib.escapeShellArg secretKeyFile} \
          "${pythonWithBcrypt}/bin/python -c 'import secrets,string; alphabet = string.ascii_letters + string.digits; print(\"\".join(secrets.choice(alphabet) for _ in range(16)))'"
        generate_secret ${lib.escapeShellArg adminPasswordFile} "openssl rand -base64 24"
        generate_secret ${lib.escapeShellArg oauth2CookieSecretStateFile} "openssl rand -hex 16 | tr -d '\n'"
        if [ ! -s ${lib.escapeShellArg sftpClientKeyFile} ]; then
          umask 0077
          ssh-keygen -q -t ed25519 -N "" -C "filestash-sftp" -f ${lib.escapeShellArg sftpClientKeyFile}
        fi

        cookie_secret_size="$(wc -c < ${lib.escapeShellArg oauth2CookieSecretStateFile})"
        case "$cookie_secret_size" in
          16|24|32) ;;
          *)
            umask 0077
            openssl rand -hex 16 | tr -d '\n' > ${lib.escapeShellArg oauth2CookieSecretStateFile}
            ;;
        esac

        ${pythonWithBcrypt}/bin/python - <<'PY'
        from pathlib import Path
        import bcrypt

        password = Path(${builtins.toJSON adminPasswordFile}).read_bytes().strip()
        hash_path = Path(${builtins.toJSON adminPasswordHashFile})
        hash_path.write_text(bcrypt.hashpw(password, bcrypt.gensalt(rounds=12)).decode() + "\n")
        PY

        chown root:root ${lib.escapeShellArg adminPasswordFile}
        chmod 0400 ${lib.escapeShellArg adminPasswordFile}
        chown root:filestash ${lib.escapeShellArg secretKeyFile} ${lib.escapeShellArg adminPasswordHashFile} ${lib.escapeShellArg sftpClientKeyFile}
        chmod 0440 ${lib.escapeShellArg secretKeyFile} ${lib.escapeShellArg adminPasswordHashFile} ${lib.escapeShellArg sftpClientKeyFile}
        chown root:root ${lib.escapeShellArg sftpClientKeyFile}.pub
        chmod 0444 ${lib.escapeShellArg sftpClientKeyFile}.pub
        rm -f ${lib.escapeShellArg sftpAuthorizedKeysDir}/*
        install -m 0644 -o root -g root ${lib.escapeShellArg sftpClientKeyFile}.pub \
          ${lib.escapeShellArg sftpAuthorizedKeysDir}/.filestash
        for user in ${lib.escapeShellArgs sftpUsers}; do
          install -m 0644 -o root -g root ${lib.escapeShellArg sftpClientKeyFile}.pub "${sftpAuthorizedKeysDir}/$user"
        done
        chown root:root ${lib.escapeShellArg oauth2CookieSecretStateFile}
        chmod 0400 ${lib.escapeShellArg oauth2CookieSecretStateFile}

        install -m 0440 -o root -g oauth2-proxy ${lib.escapeShellArg oauth2CookieSecretStateFile} ${lib.escapeShellArg oauth2CookieSecretFile}

      '';
    };

    systemd.services.kanidm = {
      requires = [ "filestash-identity-secret-materialize.service" ];
      after = [ "filestash-identity-secret-materialize.service" ];
    };

    systemd.services.filestash-oauth2-proxy = {
      requires = [ "filestash-secret-materialize.service" ];
      after = [ "filestash-secret-materialize.service" ];
    };
  };
}
