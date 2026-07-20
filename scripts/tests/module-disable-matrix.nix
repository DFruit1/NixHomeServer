let
  flake = builtins.getFlake (builtins.getEnv "NIXHOMESERVER_FLAKE_REF_FOR_EVAL");
  inherit (flake.inputs.nixpkgs) lib;
  hostName = builtins.getEnv "NIXHOMESERVER_TEST_HOST";
  baseHost = builtins.getAttr hostName flake.nixosConfigurations;
  vars = builtins.getAttr hostName flake.lib.nixhomeserverSettings;

  cases = {
    groundwater-logger = {
      disable = { repo.groundwaterLogger.enable = lib.mkForce false; };
      registryName = "groundwater-logger";
      services = [ "groundwater-logger" ];
      timers = [ ];
      hosts = [ "groundwater" ];
      gatewayApps = [ "groundwater" ];
      oauthClients = [ ];
      kanidmGroups = [ ];
      users = [ "groundwater-logger" ];
      groups = [ "groundwater-logger" ];
      secrets = [ "groundwaterAppMqttPassword" "groundwaterLoggerMqttPassword" ];
      backupApps = [ "groundwater-logger" ];
      guardedServices = [ ];
      persistencePaths = [ "/var/lib/groundwater-logger" "/var/lib/groundwater-mosquitto" ];
    };
    mail-archive-ui = {
      disable = { services.mail-archive-ui.enable = lib.mkForce false; };
      registryName = "mail-archive-ui";
      services = [
        "mail-archive-oauth2-proxy"
        "mail-archive-paperless-tasks"
        "mail-archive-sync"
        "mail-archive-ui"
        "mail-archive-ui-paperless-db-acl"
        "mail-archive-ui-storage-layout-v1"
      ];
      timers = [ "mail-archive-paperless-tasks" "mail-archive-sync" ];
      hosts = [ "emails" ];
      gatewayApps = [ "mail" ];
      oauthClients = [ "mail-archive-web" ];
      kanidmGroups = [ "mail-archive-users" ];
      users = [ "mail-archive-ui" ];
      groups = [ "mail-archive-ui" ];
      secrets = [ "mailArchiveOauth2ProxyClientSecret" "mailArchiveOauth2ProxyCookieSecret" ];
      backupApps = [ "mail-archive-ui" ];
      guardedServices = [
        "mail-archive-paperless-tasks"
        "mail-archive-sync"
        "mail-archive-ui"
        "mail-archive-ui-storage-layout-v1"
      ];
      persistencePaths = [ ];
    };
    media-automation-all = {
      disable = {
        repo.prowlarr.enable = lib.mkForce false;
        repo.qbittorrent.enable = lib.mkForce false;
        repo.radarr.enable = lib.mkForce false;
        repo.seerr.enable = lib.mkForce false;
        repo.sonarr.enable = lib.mkForce false;
      };
      registryName = "prowlarr";
      services = [
        "media-automation-bootstrap-prowlarr"
        "media-automation-bootstrap-prowlarr-qbittorrent"
        "media-automation-bootstrap-qbittorrent"
        "media-automation-bootstrap-radarr"
        "media-automation-bootstrap-sonarr"
        "media-automation-storage-layout-v1"
        "prowlarr"
        "prowlarr-oauth2-proxy"
        "qbittorrent"
        "qbittorrent-oauth2-proxy"
        "radarr"
        "radarr-oauth2-proxy"
        "seerr"
        "seerr-oauth2-proxy"
        "seerr-permissions-reconcile"
        "sonarr"
        "sonarr-oauth2-proxy"
      ];
      timers = [ "seerr-permissions-reconcile" ];
      hosts = [ "prowlarr" "requests" "sonarr" "radarr" "torrents" ];
      gatewayApps = [ "prowlarr" "qbittorrent" "radarr" "seerr" "sonarr" ];
      oauthClients = [ "prowlarr-web" "qbittorrent-web" "radarr-web" "seerr-web" "sonarr-web" ];
      kanidmGroups = [ "media-automation-users" vars.seerrRequestManagerGroup ];
      users = [ "prowlarr" "qbittorrent" "radarr" "seerr" "sonarr" ];
      groups = [ "media-automation" "prowlarr" "qbittorrent" "radarr" "seerr" "sonarr" ];
      secrets = [
        "prowlarrOauth2ProxyClientSecret"
        "prowlarrOauth2ProxyCookieSecret"
        "qbittorrentOauth2ProxyClientSecret"
        "qbittorrentOauth2ProxyCookieSecret"
        "radarrOauth2ProxyClientSecret"
        "radarrOauth2ProxyCookieSecret"
        "seerrOauth2ProxyClientSecret"
        "seerrOauth2ProxyCookieSecret"
        "sonarrOauth2ProxyClientSecret"
        "sonarrOauth2ProxyCookieSecret"
      ];
      backupApps = [ "prowlarr" "qbittorrent" "radarr" "seerr" "sonarr" ];
      guardedServices = [
        "media-automation-bootstrap-prowlarr"
        "media-automation-bootstrap-prowlarr-qbittorrent"
        "media-automation-bootstrap-qbittorrent"
        "media-automation-bootstrap-radarr"
        "media-automation-bootstrap-sonarr"
        "media-automation-storage-layout-v1"
        "qbittorrent"
        "radarr"
        "sonarr"
      ];
      persistencePaths = [ "/var/lib/prowlarr" "/var/lib/radarr" "/var/lib/seerr" "/var/lib/sonarr" ];
    };
    prowlarr = {
      disable = { repo.prowlarr.enable = lib.mkForce false; };
      registryName = "prowlarr";
      services = [ "prowlarr" "prowlarr-oauth2-proxy" ];
      timers = [ ];
      hosts = [ "prowlarr" ];
      gatewayApps = [ "prowlarr" ];
      oauthClients = [ "prowlarr-web" ];
      kanidmGroups = [ ];
      users = [ "prowlarr" ];
      groups = [ "prowlarr" ];
      secrets = [ "prowlarrOauth2ProxyClientSecret" "prowlarrOauth2ProxyCookieSecret" ];
      backupApps = [ "prowlarr" ];
      guardedServices = [ "media-automation-bootstrap-prowlarr" "media-automation-bootstrap-prowlarr-qbittorrent" ];
      persistencePaths = [ "/var/lib/prowlarr" ];
    };
    qbittorrent = {
      disable = { repo.qbittorrent.enable = lib.mkForce false; };
      registryName = "qbittorrent";
      services = [ "qbittorrent" "qbittorrent-oauth2-proxy" "media-automation-bootstrap-qbittorrent" ];
      timers = [ ];
      hosts = [ "torrents" ];
      gatewayApps = [ "qbittorrent" ];
      oauthClients = [ "qbittorrent-web" ];
      kanidmGroups = [ ];
      users = [ "qbittorrent" ];
      groups = [ "qbittorrent" ];
      secrets = [ "qbittorrentOauth2ProxyClientSecret" "qbittorrentOauth2ProxyCookieSecret" ];
      backupApps = [ "qbittorrent" ];
      guardedServices = [ "qbittorrent" "media-automation-bootstrap-qbittorrent" ];
      persistencePaths = [ ];
    };
    radarr = {
      disable = { repo.radarr.enable = lib.mkForce false; };
      registryName = "radarr";
      services = [ "radarr" "radarr-oauth2-proxy" "media-automation-bootstrap-radarr" ];
      timers = [ ];
      hosts = [ "radarr" ];
      gatewayApps = [ "radarr" ];
      oauthClients = [ "radarr-web" ];
      kanidmGroups = [ ];
      users = [ "radarr" ];
      groups = [ "radarr" ];
      secrets = [ "radarrOauth2ProxyClientSecret" "radarrOauth2ProxyCookieSecret" ];
      backupApps = [ "radarr" ];
      guardedServices = [ "radarr" "media-automation-bootstrap-radarr" ];
      persistencePaths = [ "/var/lib/radarr" ];
    };
    seerr = {
      disable = { repo.seerr.enable = lib.mkForce false; };
      registryName = "seerr";
      services = [ "seerr" "seerr-oauth2-proxy" "seerr-permissions-reconcile" ];
      timers = [ "seerr-permissions-reconcile" ];
      hosts = [ "requests" ];
      gatewayApps = [ "seerr" ];
      oauthClients = [ "seerr-web" ];
      kanidmGroups = [ vars.seerrRequestManagerGroup ];
      users = [ "seerr" ];
      groups = [ "seerr" ];
      secrets = [ "seerrOauth2ProxyClientSecret" "seerrOauth2ProxyCookieSecret" ];
      backupApps = [ "seerr" ];
      guardedServices = [ ];
      persistencePaths = [ "/var/lib/seerr" ];
    };
    sonarr = {
      disable = { repo.sonarr.enable = lib.mkForce false; };
      registryName = "sonarr";
      services = [ "sonarr" "sonarr-oauth2-proxy" "media-automation-bootstrap-sonarr" ];
      timers = [ ];
      hosts = [ "sonarr" ];
      gatewayApps = [ "sonarr" ];
      oauthClients = [ "sonarr-web" ];
      kanidmGroups = [ ];
      users = [ "sonarr" ];
      groups = [ "sonarr" ];
      secrets = [ "sonarrOauth2ProxyClientSecret" "sonarrOauth2ProxyCookieSecret" ];
      backupApps = [ "sonarr" ];
      guardedServices = [ "sonarr" "media-automation-bootstrap-sonarr" ];
      persistencePaths = [ "/var/lib/sonarr" ];
    };
  };

  requestedCaseNames = lib.splitString "," (builtins.getEnv "NIXHOMESERVER_DISABLE_CASES");
  selectedCases = lib.filterAttrs (name: _: builtins.elem name requestedCaseNames) cases;

  evaluate = _name: case:
    let
      host = baseHost.extendModules { modules = [ case.disable ]; };
      cfg = host.config;
      fullHosts = map (short: "${short}.${vars.domain}") case.hosts;
      shortHosts = map (short: "http://${short}") case.hosts;
      lanHosts = map (short: "http://${short}.${vars.networking.dns.lanDomain}") case.hosts;
      privateHosts = fullHosts
        ++ case.hosts
        ++ map (short: "${short}.${vars.networking.dns.lanDomain}") case.hosts;
      present = attrs: names: builtins.filter (name: builtins.hasAttr name attrs) names;
      presentServices = present cfg.systemd.services case.services;
      presentTimers = present cfg.systemd.timers case.timers;
      presentCaddyHosts = present cfg.services.caddy.virtualHosts (fullHosts ++ shortHosts ++ lanHosts);
      presentPrivateHosts = present cfg.services.unbound.privateHosts privateHosts;
      presentGatewayApps = present cfg.repo.authGateway.protectedApps case.gatewayApps;
      presentOauthClients = present cfg.services.kanidm.provision.systems.oauth2 case.oauthClients;
      presentKanidmGroups = present cfg.services.kanidm.provision.groups case.kanidmGroups;
      presentUsers = present cfg.users.users case.users;
      presentGroups = present cfg.users.groups case.groups;
      presentSecrets = present cfg.age.secrets case.secrets;
      presentBackupApps = builtins.filter
        (name: builtins.any (entry: entry.app == name) cfg.repo.backups.appStateEntries)
        case.backupApps;
      presentGuardedServices = builtins.filter
        (name: builtins.elem name cfg.repo.storage.dataPool.guardedServices)
        case.guardedServices;
      missingPersistence = builtins.filter
        (path: !(builtins.elem path cfg.repo.impermanence.inventory.persistenceDirectories))
        case.persistencePaths;
    in
    {
      drvPath = cfg.system.build.toplevel.drvPath;
      registryPresent = cfg.nixhomeserver.modules.${case.registryName} or false;
      inherit
        missingPersistence
        presentBackupApps
        presentCaddyHosts
        presentGatewayApps
        presentGroups
        presentGuardedServices
        presentKanidmGroups
        presentOauthClients
        presentPrivateHosts
        presentSecrets
        presentServices
        presentTimers
        presentUsers
        ;
      valid =
        lib.hasPrefix "/nix/store/" cfg.system.build.toplevel.drvPath
        && (cfg.nixhomeserver.modules.${case.registryName} or false)
        && presentServices == [ ]
        && presentTimers == [ ]
        && presentCaddyHosts == [ ]
        && presentPrivateHosts == [ ]
        && presentGatewayApps == [ ]
        && presentOauthClients == [ ]
        && presentKanidmGroups == [ ]
        && presentUsers == [ ]
        && presentGroups == [ ]
        && presentSecrets == [ ]
        && presentBackupApps == [ ]
        && presentGuardedServices == [ ]
        && missingPersistence == [ ];
    };
in
assert requestedCaseNames != [ "" ];
assert lib.all (name: builtins.hasAttr name cases) requestedCaseNames;
lib.mapAttrs evaluate selectedCases
