{ agenix
, impermanence
, filestashNix
, lib
, vars
, pkgs
, appPackages
, sourcePath
, requestedVariants
}:

let
  repo = sourcePath;

  appNames = lib.sort builtins.lessThan (builtins.attrNames (lib.filterAttrs
    (name: type:
      type == "directory"
      && !(builtins.elem name [ "Core_Modules" "Integrations" "power-management" ]))
    (builtins.readDir (repo + "/modules"))));

  integrationNames = lib.sort builtins.lessThan (builtins.attrNames (lib.filterAttrs
    (name: type: type == "regular" && lib.hasSuffix ".nix" name)
    (builtins.readDir (repo + "/modules/Integrations"))));
  integrationModules = map
    (name: repo + "/modules/Integrations/${name}")
    integrationNames;

  hardwareModule =
    if builtins.elem vars.hardwareProfile [ "generated" "existing-server" ] then
      repo + "/hardware-configuration.nix"
    else if vars.hardwareProfile == "generic-uefi" then
      repo + "/hardware/generic-uefi.nix"
    else
      throw "Unsupported system.hardwareProfile '${vars.hardwareProfile}'. Supported values are generated, existing-server, and generic-uefi.";

  mkHost = selectedApps:
    lib.nixosSystem {
      modules = [
        { nixpkgs.hostPlatform = vars.hostPlatform; }
        hardwareModule
        (repo + "/system-resources.nix")
        (repo + "/modules/Core_Modules")
        agenix.nixosModules.default
        impermanence.nixosModules.impermanence
      ]
      ++ map (name: repo + "/modules/${name}") selectedApps
      ++ integrationModules;

      specialArgs = {
        inherit vars appPackages;
        inherit filestashNix;
        oauth2Proxy = import (repo + "/modules/Core_Modules/oauth2-proxy") {
          inherit lib pkgs vars;
        };
      };
    };

  moduleSecrets = {
    audiobookshelf = [ "absBootstrapPass" "absClientSecret" ];
    groundwater-logger = [ "groundwaterAppMqttPassword" "groundwaterLoggerMqttPassword" ];
    homepage = [ "canaryUserPassword" "homepageOauth2ProxyClientSecret" "homepageOauth2ProxyCookieSecret" ];
    immich = [ "immichClientSecret" ];
    kavita = [ "kavitaClientSecret" "kavitaTokenKey" ];
    kiwix = [ "kiwixOauth2ProxyClientSecret" "kiwixOauth2ProxyCookieSecret" ];
    mail-archive-ui = [ "mailArchiveOauth2ProxyClientSecret" "mailArchiveOauth2ProxyCookieSecret" ];
    paperless = [ "paperlessClientSecret" ];
    prowlarr = [ "prowlarrOauth2ProxyClientSecret" "prowlarrOauth2ProxyCookieSecret" ];
    qbittorrent = [ "qbittorrentOauth2ProxyClientSecret" "qbittorrentOauth2ProxyCookieSecret" ];
    radarr = [ "radarrOauth2ProxyClientSecret" "radarrOauth2ProxyCookieSecret" ];
    seerr = [ "seerrOauth2ProxyClientSecret" "seerrOauth2ProxyCookieSecret" ];
    sonarr = [ "sonarrOauth2ProxyClientSecret" "sonarrOauth2ProxyCookieSecret" ];
    vaultwarden = [ "vaultwardenAdminToken" ];
    youtube-downloader = [ "youtubeDownloaderOauth2ProxyClientSecret" "youtubeDownloaderOauth2ProxyCookieSecret" ];
  };

  moduleGuardedServices = {
    immich = [ "immich-storage-layout-v1" "immich-server" ];
    kavita = [ "kavita-storage-layout-v1" "kavita" "kavita-stale-reference-cleanup" ];
    kiwix = [ "kiwix-library-root-layout-v1" "kiwix-library-sync" "kiwix-library-watch" "kiwix-serve" ];
    mail-archive-ui = [ "mail-archive-ui-storage-layout-v1" "mail-archive-ui" "mail-archive-sync" "mail-archive-paperless-tasks" ];
    offline-music = [ "offline-media-reconcile" ];
    paperless = [
      "paperless-storage-layout-v1"
      "paperless-consumer"
      "paperless-scheduler"
      "paperless-task-queue"
      "paperless-web"
      "paperless-exporter"
      "paperless-stale-reference-check"
    ];
    qbittorrent = [ "qbittorrent" "media-automation-bootstrap-qbittorrent" ];
    radarr = [ "radarr" "media-automation-bootstrap-radarr" ];
    sonarr = [ "sonarr" "media-automation-bootstrap-sonarr" ];
  };

  allVariants = [ "core-only" "prowlarr-only" ] ++ map (name: "without-${name}") appNames;
  variants = requestedVariants;

  matrix = lib.genAttrs variants
    (variant:
      let
        removed = lib.removePrefix "without-" variant;
        selectedApps =
          if variant == "core-only" then
            [ ]
          else if variant == "prowlarr-only" then
            [ "prowlarr" ]
          else
            builtins.filter (name: name != removed) appNames;
        host = mkHost selectedApps;
        services = host.config.systemd.services;
        ageSecretNames = builtins.attrNames host.config.age.secrets;
        registry = host.config.nixhomeserver.modules;
        guardedServices = host.config.repo.storage.dataPool.guardedServices;
        expectedRegistry = builtins.listToAttrs (map
          (name: {
            inherit name;
            value = true;
          })
          selectedApps);
        mediaApps = builtins.filter
          (name: builtins.elem name [ "qbittorrent" "radarr" "sonarr" ])
          selectedApps;
        mediaLayoutService = "media-automation-storage-layout-v1";
        mediaLayoutPresent = builtins.hasAttr mediaLayoutService services;
        mediaLayoutScript =
          if mediaLayoutPresent then services.${mediaLayoutService}.script else "";
        appServiceUsesLayout = name:
          let
            service = builtins.getAttr name services;
          in
          builtins.elem "${mediaLayoutService}.service" service.wants
          && builtins.elem "${mediaLayoutService}.service" service.after;
        mediaAutomationSurface = {
          inherit mediaApps mediaLayoutPresent;
          mediaGroupPresent = builtins.hasAttr "media-automation" host.config.users.groups;
          selectedServicesUseLayout = lib.all appServiceUsesLayout mediaApps;
          layoutHasRequiredVideoRoots =
            (!builtins.elem "radarr" mediaApps
            || lib.hasInfix "${vars.sharedRoot}/_Videos/_Movies" mediaLayoutScript)
            && (!builtins.elem "sonarr" mediaApps
            || lib.hasInfix "${vars.sharedRoot}/_Videos/_Shows" mediaLayoutScript);
          layoutHasQbittorrentRoot =
            !builtins.elem "qbittorrent" mediaApps
            || lib.hasInfix "${vars.sharedRoot}/_Downloads/qbittorrent" mediaLayoutScript;
          referencesJellyfinLayout =
            mediaLayoutPresent
            && builtins.elem "jellyfin-storage-layout-v1.service"
              services.${mediaLayoutService}.wants;
        };
        offlineMediaSurface = {
          syncthingEnabled = host.config.services.syncthing.enable;
          gatewayRegistered = builtins.hasAttr "syncthing" host.config.repo.authGateway.protectedApps;
          homepageEnvironmentPresent =
            builtins.elem "homepage" selectedApps
            && builtins.hasAttr "HOMEPAGE_OFFLINE_MEDIA_ENROLL_COMMAND"
              services.homepage.environment;
          disabledCleanupPresent = builtins.hasAttr "offline-media-disabled-cleanup" services;
          dedicatedAccessGroupPresent =
            (vars.offlineMedia.accessGroup or "users") != "users"
            && builtins.hasAttr (vars.offlineMedia.accessGroup or "users")
              host.config.services.kanidm.provision.groups;
          dedicatedGatewayScopePresent =
            (vars.offlineMedia.accessGroup or "users") != "users"
            && builtins.hasAttr (vars.offlineMedia.accessGroup or "users")
              host.config.services.kanidm.provision.systems.oauth2.auth-gateway-web.scopeMaps;
          dedicatedHomepageScopePresent =
            (vars.offlineMedia.accessGroup or "users") != "users"
            && builtins.elem "homepage" selectedApps
            && builtins.hasAttr (vars.offlineMedia.accessGroup or "users")
              host.config.services.kanidm.provision.systems.oauth2.homepage-web.scopeMaps;
        };
        homepageConfigDrv =
          if builtins.elem "homepage" selectedApps then
            builtins.head
              (builtins.attrNames (builtins.getContext
                (toString services.homepage.environment.HOMEPAGE_CONFIG_FILE)))
          else
            null;
        removedOwnedSecretsAbsent = lib.all
          (secret: !(builtins.elem secret ageSecretNames))
          (moduleSecrets.${removed} or [ ]);
        mediaAutomationValid =
          if mediaApps != [ ] then
            mediaAutomationSurface.mediaLayoutPresent
            && mediaAutomationSurface.mediaGroupPresent
            && mediaAutomationSurface.selectedServicesUseLayout
            && mediaAutomationSurface.layoutHasRequiredVideoRoots
            && mediaAutomationSurface.layoutHasQbittorrentRoot
          else
            !mediaAutomationSurface.mediaLayoutPresent
            && !mediaAutomationSurface.mediaGroupPresent;
        jellyfinReferenceValid =
          builtins.elem "jellyfin" selectedApps
          || !mediaAutomationSurface.referencesJellyfinLayout;
        offlineMediaValid =
          variant != "without-offline-music"
          || offlineMediaSurface == {
            syncthingEnabled = false;
            gatewayRegistered = false;
            homepageEnvironmentPresent = false;
            disabledCleanupPresent = true;
            dedicatedAccessGroupPresent = false;
            dedicatedGatewayScopePresent = false;
            dedicatedHomepageScopePresent = false;
          };
        prowlarrOnlyValid =
          variant != "prowlarr-only"
          || (
            host.config.services.prowlarr.enable
            && !(builtins.elem "${mediaLayoutService}.service" services.prowlarr.wants)
          );
        guardedServicesValid = lib.all
          (name:
            let service = services.${name};
            in builtins.elem "data-pool-layout.service" service.requires
              && builtins.elem "data-pool-layout.service" service.after
              && service.unitConfig.ConditionPathIsMountPoint == vars.dataRoot)
          guardedServices;
        removedGuardedServicesAbsent = lib.all
          (name: !(builtins.elem name guardedServices))
          (moduleGuardedServices.${removed} or [ ]);
      in
      {
        drvPath = host.config.system.build.toplevel.drvPath;
        inherit
          registry
          selectedApps
          ageSecretNames
          homepageConfigDrv
          offlineMediaSurface
          mediaAutomationSurface
          removedOwnedSecretsAbsent
          guardedServices
          guardedServicesValid
          removedGuardedServicesAbsent
          ;
        selected = selectedApps;
        caddyHostCount = builtins.length (builtins.attrNames host.config.services.caddy.virtualHosts);
        oauthClientCount = builtins.length (builtins.attrNames host.config.services.kanidm.provision.systems.oauth2);
        valid =
          lib.hasPrefix "/nix/store/" host.config.system.build.toplevel.drvPath
          && registry == expectedRegistry
          && (variant != "core-only" || (selectedApps == [ ] && registry == { }))
          && removedOwnedSecretsAbsent
          && guardedServicesValid
          && removedGuardedServicesAbsent
          && builtins.length (builtins.attrNames host.config.services.caddy.virtualHosts) >= 3
          && builtins.length (builtins.attrNames host.config.services.kanidm.provision.systems.oauth2) >= 3
          && mediaAutomationValid
          && jellyfinReferenceValid
          && offlineMediaValid
          && prowlarrOnlyValid;
      });
in
assert lib.all (variant: builtins.elem variant allVariants) variants;
matrix
