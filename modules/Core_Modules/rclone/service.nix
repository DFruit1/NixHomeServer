{ config, lib, oauth2Proxy, pkgs, vars, ... }:

let
  serviceUser = "rclone";
  serviceGroup = "rclone";
  loopback = vars.networking.loopbackIPv4;
  rcPort = vars.networking.ports.rcloneRc;
  oauth2Port = vars.networking.ports.oauth2ProxyRclone;
  host = vars.rcloneDomain;
  stateDir = "/var/lib/rclone";
  configDir = "${stateDir}/.config/rclone";
  cacheDir = "${stateDir}/.cache/rclone";
  configFile = "${configDir}/rclone.conf";
  backupRoot = vars.backupRoot or "${vars.dataRoot}/backups";
  backupStorageAccessGroup = vars.backupAccess.storageGroup or "backup-admin";
  backupStorageAccessGid = vars.fileAccessPosixGids.${backupStorageAccessGroup};
  startScript = pkgs.writeShellScript "rclone-rcd-start" ''
    set -euo pipefail

    exec ${pkgs.rclone}/bin/rclone rcd \
      --config ${lib.escapeShellArg configFile} \
      --cache-dir ${lib.escapeShellArg cacheDir} \
      --rc \
      --rc-addr ${lib.escapeShellArg "${loopback}:${toString rcPort}"} \
      --rc-web-gui \
      --rc-web-gui-no-open-browser \
      --rc-user-from-header X-Auth-Request-Preferred-Username
  '';
in
{
  config = lib.mkMerge [
    {
      users.groups.${serviceGroup} = { };
      users.groups.${backupStorageAccessGroup}.gid = lib.mkDefault backupStorageAccessGid;

      users.users.${serviceUser} = {
        isSystemUser = true;
        group = serviceGroup;
        home = stateDir;
        createHome = true;
      };

      environment.systemPackages = [ pkgs.rclone ];

      systemd.tmpfiles.rules = [
        "d ${stateDir} 0700 ${serviceUser} ${serviceGroup} -"
        "d ${configDir} 0700 ${serviceUser} ${serviceGroup} -"
        "d ${cacheDir} 0700 ${serviceUser} ${serviceGroup} -"
      ];

      systemd.services.rclone = {
        description = "Rclone remote-control Web GUI";
        wantedBy = [ "multi-user.target" ];
        wants = [ "network-online.target" ];
        after = [ "network-online.target" ];
        serviceConfig = {
          Type = "simple";
          User = serviceUser;
          Group = serviceGroup;
          SupplementaryGroups = [ backupStorageAccessGroup ];
          Environment = [
            "HOME=${stateDir}"
            "XDG_CONFIG_HOME=${stateDir}/.config"
            "XDG_CACHE_HOME=${stateDir}/.cache"
          ];
          ExecStart = startScript;
          Restart = "on-failure";
          RestartSec = 5;
          NoNewPrivileges = true;
          PrivateTmp = true;
          ProtectSystem = "strict";
          ProtectHome = true;
          ReadWritePaths = [ stateDir ];
          ReadOnlyPaths = [ backupRoot ];
          RestrictAddressFamilies = [
            "AF_INET"
            "AF_INET6"
            "AF_UNIX"
          ];
        };
      };
    }

    (oauth2Proxy.mkSidecarService {
      serviceName = "rclone-oauth2-proxy";
      description = "Dedicated OAuth2 Proxy for Rclone";
      clientId = "rclone-web";
      clientSecretFile = config.age.secrets.rcloneOauth2ProxyClientSecret.path;
      cookieSecretFile = config.age.secrets.rcloneOauth2ProxyCookieSecret.path;
      cookieName = "_oauth2_proxy_rclone";
      domain = host;
      port = oauth2Port;
      upstream = "http://${loopback}:${toString rcPort}";
      allowedGroups = [ vars.backupAccess.adminGroup ];
      serviceDependencies = [
        "caddy.service"
        "rclone.service"
      ];
      upstreamCheck = {
        displayName = "Rclone";
        url = "http://${loopback}:${toString rcPort}/";
        okStatusCodes = [
          "200"
          "401"
        ];
      };
    })
  ];
}
