{ config, lib, oauth2Proxy, pkgs, vars, ... }:

let
  loopback = vars.networking.loopbackIPv4;
  kopiaPort = vars.networking.ports.kopia;
  kopiaAuthProxyPort = kopiaPort + 1;
  oauth2Port = vars.networking.ports.oauth2ProxyKopia;
  host = vars.kopiaDomain;
  stateDir = "/persist/appdata/kopia";
  configFile = "${stateDir}/repository.config";
  cacheDir = "${stateDir}/cache";
  logDir = "${stateDir}/logs";
  uiPreferencesFile = "${stateDir}/ui-preferences.json";
  backupRoot = vars.backupRoot or "${vars.dataRoot}/backups";
  repositoryPath = "${backupRoot}/kopia";
  backupStorageAccessGroup = vars.backupAccess.storageGroup or "admin-backups";
  backupStorageAccessGid = vars.fileAccessPosixGids.${backupStorageAccessGroup};
  credentials = {
    serverPassword = "kopia-server-password";
  };
  commonPath = with pkgs; [
    acl
    coreutils
    findutils
    jq
    kopia
  ];
  kopiaAuthProxyCaddyfile = pkgs.writeText "kopia-auth-proxy.Caddyfile" ''
    {
      admin off
      auto_https off
    }

    http://:${toString kopiaAuthProxyPort} {
      bind ${loopback}
      reverse_proxy ${loopback}:${toString kopiaPort} {
        header_up Authorization "Basic {$KOPIA_BASIC_AUTH}"
      }
    }
  '';
in
{
  config = lib.mkMerge [
    {
      systemd.tmpfiles.rules = [
        "d ${stateDir} 0700 root root -"
        "d ${cacheDir} 0700 root root -"
        "d ${logDir} 0700 root root -"
        "d ${backupRoot} 0750 root ${toString backupStorageAccessGid} -"
      ];

      systemd.services.kopia-repository-bootstrap = {
        description = "Create or connect the local encrypted Kopia repository";
        wantedBy = [ "multi-user.target" ];
        wants = [
          "data-pool-layout.service"
          "kanidm-files-posix-groups.service"
        ];
        after = [
          "data-pool-layout.service"
          "kanidm-files-posix-groups.service"
        ];
        path = commonPath;
        serviceConfig = {
          Type = "oneshot";
          LoadCredential = [
            "${credentials.serverPassword}:${config.age.secrets.kopiaServerPassword.path}"
          ];
        };
        script = ''
          set -euo pipefail

          password="$(tr -d '\r\n' < "$CREDENTIALS_DIRECTORY/${credentials.serverPassword}")"
          export KOPIA_CHECK_FOR_UPDATES=false
          export KOPIA_PASSWORD="$password"
          export KOPIA_CONFIG_PATH=${lib.escapeShellArg configFile}
          export KOPIA_CACHE_DIRECTORY=${lib.escapeShellArg cacheDir}

          install -d -m 0700 ${lib.escapeShellArg stateDir} ${lib.escapeShellArg cacheDir} ${lib.escapeShellArg logDir}
          install -d -m 0750 -o root -g ${lib.escapeShellArg (toString backupStorageAccessGid)} ${lib.escapeShellArg backupRoot} ${lib.escapeShellArg repositoryPath}

          if [[ -f ${lib.escapeShellArg configFile} ]]; then
            storage_type="$(jq -r '.storage.type // empty' ${lib.escapeShellArg configFile} 2>/dev/null || true)"
            storage_path="$(jq -r '.storage.config.path // .storage.path // empty' ${lib.escapeShellArg configFile} 2>/dev/null || true)"
            if [[ "$storage_type" != "filesystem" || "$storage_path" != ${lib.escapeShellArg repositoryPath} ]]; then
              mv ${lib.escapeShellArg configFile} ${lib.escapeShellArg configFile}."legacy-$(date -u +%Y%m%dT%H%M%SZ)"
            fi
          fi

          if [[ ! -f ${lib.escapeShellArg configFile} ]]; then
            if [[ -f ${lib.escapeShellArg repositoryPath}/kopia.repository.f ]]; then
              kopia repository connect filesystem \
                --path=${lib.escapeShellArg repositoryPath} \
                --config-file=${lib.escapeShellArg configFile} \
                --cache-directory=${lib.escapeShellArg cacheDir} \
                --password="$password" \
                --persist-credentials \
                --no-use-keyring
            else
              kopia repository create filesystem \
                --path=${lib.escapeShellArg repositoryPath} \
                --config-file=${lib.escapeShellArg configFile} \
                --cache-directory=${lib.escapeShellArg cacheDir} \
                --password="$password" \
                --persist-credentials \
                --no-use-keyring \
                --description="NixHomeServer /persist backup repository" \
                --owner-uid=0 \
                --owner-gid=${lib.escapeShellArg (toString backupStorageAccessGid)} \
                --file-mode=0640 \
                --dir-mode=0750
            fi
          fi

          chown -R root:${lib.escapeShellArg (toString backupStorageAccessGid)} ${lib.escapeShellArg backupRoot}
          chmod 0750 ${lib.escapeShellArg backupRoot} ${lib.escapeShellArg repositoryPath}
          setfacl -R -m g:${lib.escapeShellArg (toString backupStorageAccessGid)}:r-X ${lib.escapeShellArg backupRoot}
          find ${lib.escapeShellArg backupRoot} -type d -exec setfacl -m d:g:${lib.escapeShellArg (toString backupStorageAccessGid)}:r-x '{}' +
        '';
      };

      systemd.services.kopia = {
        description = "Kopia backup-management web UI";
        wantedBy = [ "multi-user.target" ];
        requires = [ "kopia-repository-bootstrap.service" ];
        wants = [
          "kopia-repository-bootstrap.service"
          "network-online.target"
        ];
        after = [
          "kopia-repository-bootstrap.service"
          "network-online.target"
        ];
        path = commonPath;
        serviceConfig = {
          Type = "simple";
          LoadCredential = [
            "${credentials.serverPassword}:${config.age.secrets.kopiaServerPassword.path}"
          ];
          ExecStart = pkgs.writeShellScript "kopia-server-start" ''
            set -euo pipefail

            export KOPIA_CHECK_FOR_UPDATES=false
            export KOPIA_SERVER_USERNAME=kopia-admin
            export KOPIA_SERVER_PASSWORD="$(tr -d '\r\n' < "$CREDENTIALS_DIRECTORY/${credentials.serverPassword}")"
            export KOPIA_PASSWORD="$KOPIA_SERVER_PASSWORD"
            export KOPIA_CONFIG_PATH=${lib.escapeShellArg configFile}
            export KOPIA_CACHE_DIRECTORY=${lib.escapeShellArg cacheDir}

            install -d -m 0700 ${lib.escapeShellArg stateDir} ${lib.escapeShellArg cacheDir} ${lib.escapeShellArg logDir}

            exec ${pkgs.kopia}/bin/kopia server start \
              --insecure \
              --ui \
              --address=http://${loopback}:${toString kopiaPort} \
              --log-dir=${lib.escapeShellArg logDir} \
              --ui-preferences-file=${lib.escapeShellArg uiPreferencesFile}
          '';
          Restart = "on-failure";
          RestartSec = 5;
          NoNewPrivileges = true;
          PrivateTmp = true;
          RestrictAddressFamilies = [
            "AF_INET"
            "AF_INET6"
            "AF_UNIX"
          ];
        };
      };

      systemd.services.kopia-persist-snapshot = {
        description = "Create an encrypted Kopia snapshot of /persist";
        wants = [ "kopia-repository-bootstrap.service" ];
        after = [ "kopia-repository-bootstrap.service" ];
        path = commonPath;
        serviceConfig = {
          Type = "oneshot";
          LoadCredential = [
            "${credentials.serverPassword}:${config.age.secrets.kopiaServerPassword.path}"
          ];
          Nice = 10;
          IOSchedulingClass = "best-effort";
          IOSchedulingPriority = 7;
        };
        script = ''
          set -euo pipefail

          password="$(tr -d '\r\n' < "$CREDENTIALS_DIRECTORY/${credentials.serverPassword}")"
          export KOPIA_CHECK_FOR_UPDATES=false
          export KOPIA_PASSWORD="$password"
          export KOPIA_CONFIG_PATH=${lib.escapeShellArg configFile}
          export KOPIA_CACHE_DIRECTORY=${lib.escapeShellArg cacheDir}

          kopia snapshot create \
            --no-progress \
            --description="/persist automatic snapshot" \
            --tags=source:persist \
            /persist

          setfacl -R -m g:${lib.escapeShellArg (toString backupStorageAccessGid)}:r-X ${lib.escapeShellArg backupRoot}
          find ${lib.escapeShellArg backupRoot} -type d -exec setfacl -m d:g:${lib.escapeShellArg (toString backupStorageAccessGid)}:r-x '{}' +
        '';
      };

      systemd.timers.kopia-persist-snapshot = {
        description = "Daily encrypted Kopia snapshot of /persist";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = "*-*-* 03:15:00";
          Persistent = true;
          RandomizedDelaySec = "30m";
          Unit = "kopia-persist-snapshot.service";
        };
      };

      systemd.services.kopia-auth-proxy = {
        description = "Local Kopia Basic Auth injection proxy";
        wantedBy = [ "multi-user.target" ];
        requires = [ "kopia.service" ];
        after = [ "kopia.service" ];
        serviceConfig = {
          Type = "simple";
          LoadCredential = [
            "${credentials.serverPassword}:${config.age.secrets.kopiaServerPassword.path}"
          ];
          ExecStart = pkgs.writeShellScript "kopia-auth-proxy-start" ''
            set -euo pipefail

            password="$(tr -d '\r\n' < "$CREDENTIALS_DIRECTORY/${credentials.serverPassword}")"
            export KOPIA_BASIC_AUTH="$(printf 'kopia-admin:%s' "$password" | ${pkgs.coreutils}/bin/base64 --wrap=0)"

            exec ${pkgs.caddy}/bin/caddy run --config ${kopiaAuthProxyCaddyfile}
          '';
          Restart = "on-failure";
          RestartSec = 5;
          NoNewPrivileges = true;
          PrivateTmp = true;
          RestrictAddressFamilies = [
            "AF_INET"
            "AF_INET6"
            "AF_UNIX"
          ];
        };
      };
    }

    (oauth2Proxy.mkSidecarService {
      serviceName = "kopia-oauth2-proxy";
      description = "Dedicated OAuth2 Proxy for Kopia";
      clientId = "kopia-web";
      clientSecretFile = config.age.secrets.kopiaOauth2ProxyClientSecret.path;
      cookieSecretFile = config.age.secrets.kopiaOauth2ProxyCookieSecret.path;
      cookieName = "_oauth2_proxy_kopia";
      domain = host;
      port = oauth2Port;
      upstream = "http://${loopback}:${toString kopiaAuthProxyPort}";
      allowedGroups = [ vars.backupAccess.adminGroup ];
      serviceDependencies = [
        "caddy.service"
        "kopia.service"
        "kopia-auth-proxy.service"
      ];
      upstreamCheck = {
        displayName = "Kopia";
        url = "http://${loopback}:${toString kopiaAuthProxyPort}/";
        okStatusCodes = [
          "200"
        ];
      };
    })
  ];
}
