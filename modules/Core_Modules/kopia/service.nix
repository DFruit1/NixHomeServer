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
  credentials = {
    serverPassword = "kopia-server-password";
  };
  commonPath = with pkgs; [
    coreutils
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
      ];

      systemd.services.kopia = {
        description = "Kopia backup-management web UI";
        wantedBy = [ "multi-user.target" ];
        wants = [ "network-online.target" ];
        after = [ "network-online.target" ];
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
