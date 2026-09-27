{ config, lib, pkgs, vars, ... }:

let
  stateDir = config.repo.fdroid.paths.stateDir;
  credentialsFile = "${stateDir}/credentials.env";
  mirrorConfig = lib.optionalString (config.repo.fdroid.mirrorUrls != [ ]) (
    "mirrors:\n"
    + lib.concatMapStrings (url: "  - ${url}\n") config.repo.fdroid.mirrorUrls
  );
  configFile = pkgs.writeText "fdroidserver-config.yml" ''
    repo_url: https://fdroid.${vars.domain}/fdroid/repo
    repo_name: Sydney Basin Apps
    repo_description: >-
      Privately hosted Android apps for the Sydney Basin home server.
    java_paths:
      "${lib.versions.major pkgs.jdk.version}": ${pkgs.jdk}
    repo_maxage: 0
    keystore: ${stateDir}/repo-signing-key.jks
    keystorepass: {env: FDROID_KEYSTOREPASS}
    keypass: {env: FDROID_KEYPASS}
    repo_keyalias: fdroid-repo
    keydname: CN=fdroid.${vars.domain}, O=Sydney Basin Services
    archive_older: 0
    ${mirrorConfig}
  '';
  initialize = pkgs.writeShellScript "fdroidserver-initialize" ''
    set -euo pipefail
    umask 077

    if [[ ! -f ${lib.escapeShellArg credentialsFile} ]]; then
      key_store_password="$(${pkgs.openssl}/bin/openssl rand -hex 32)"
      key_password="$(${pkgs.openssl}/bin/openssl rand -hex 32)"
      temp_credentials="$(${pkgs.coreutils}/bin/mktemp ${lib.escapeShellArg "${stateDir}/.credentials.XXXXXX"})"
      printf 'FDROID_KEYSTOREPASS=%s\nFDROID_KEYPASS=%s\n' \
        "$key_store_password" "$key_password" >"$temp_credentials"
      ${pkgs.coreutils}/bin/chmod 0600 "$temp_credentials"
      ${pkgs.coreutils}/bin/mv "$temp_credentials" ${lib.escapeShellArg credentialsFile}
    fi

    ${pkgs.coreutils}/bin/ln -sfn ${lib.escapeShellArg configFile} ${lib.escapeShellArg "${stateDir}/config.yml"}

    if [[ ! -f ${lib.escapeShellArg "${stateDir}/repo-signing-key.jks"} ]]; then
      set -a
      source ${lib.escapeShellArg credentialsFile}
      set +a
      ${pkgs.jdk}/bin/keytool -genkeypair \
        -keystore ${lib.escapeShellArg "${stateDir}/repo-signing-key.jks"} \
        -storetype JKS \
        -storepass "$FDROID_KEYSTOREPASS" \
        -keypass "$FDROID_KEYPASS" \
        -alias fdroid-repo \
        -keyalg RSA -keysize 3072 -validity 10000 \
        -dname ${lib.escapeShellArg "CN=fdroid.${vars.domain}, O=Sydney Basin Services"} \
        -noprompt >/dev/null
      ${pkgs.coreutils}/bin/chmod 0600 ${lib.escapeShellArg "${stateDir}/repo-signing-key.jks"}
    fi
  '';
  publisher = pkgs.writeShellApplication {
    name = "fdroid-publish";
    runtimeInputs = [ pkgs.coreutils pkgs.systemd pkgs.util-linux ];
    text = ''
      set -euo pipefail
      usage() {
        echo "Usage: sudo fdroid-publish <application-id> <signed.apk>" >&2
        exit 2
      }
      [[ "$#" == 2 ]] || usage
      app_id="$1"
      apk_path="$2"
      [[ "$app_id" =~ ^[A-Za-z0-9_]+(\.[A-Za-z0-9_]+)+$ ]] || usage
      [[ -f "$apk_path" && "$apk_path" == *.apk ]] || {
        echo "APK path must name an existing .apk file" >&2
        exit 2
      }
      [[ -r ${lib.escapeShellArg credentialsFile} ]] || {
        echo "F-Droid repository is not initialized yet" >&2
        exit 1
      }

      exec 9>/run/lock/fdroid-publish.lock
      flock 9
      temp_apk="${stateDir}/repo/.''${app_id}.apk.tmp"
      install -m 0644 "$apk_path" "$temp_apk"
      mv -f "$temp_apk" "${stateDir}/repo/''${app_id}.apk"
      systemctl start fdroid-reindex.service
    '';
  };
in
{
  environment.etc."fdroidserver/config.yml".source = configFile;
  environment.systemPackages = [ publisher ];

  systemd.services.fdroid-repository-init = {
    description = "Initialize the private F-Droid repository signing key";
    wantedBy = [ "multi-user.target" ];
    before = [ "fdroid-reindex.service" ];
    serviceConfig = {
      Type = "oneshot";
      User = "fdroidserver";
      Group = "fdroidserver";
      StateDirectory = "fdroidserver";
      StateDirectoryMode = "0755";
      UMask = "0022";
      ExecStart = initialize;
      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      ReadWritePaths = [ stateDir ];
    };
  };

  systemd.services.fdroid-reindex = {
    description = "Refresh and sign the F-Droid repository index";
    wantedBy = [ "multi-user.target" ];
    requires = [ "fdroid-repository-init.service" ];
    after = [ "fdroid-repository-init.service" ];
    path = [ pkgs.jdk ];
    serviceConfig = {
      Type = "oneshot";
      User = "fdroidserver";
      Group = "fdroidserver";
      WorkingDirectory = stateDir;
      EnvironmentFile = credentialsFile;
      ExecStart = "${pkgs.fdroidserver}/bin/fdroid update --create-metadata";
      UMask = "0022";
      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      ReadWritePaths = [ stateDir ];
    };
  };
}
