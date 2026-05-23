{ config, lib, vars, ... }:

let
  proxyUser = "immich-public-proxy";
  proxyGroup = "immich-public-proxy";
  proxyUid = 3001;
  proxyGid = 3001;
  proxySubIdStart = 400000;
  proxySubIdCount = 65536;
in

{
  config = lib.mkIf config.nixhomeserver.apps.immich.enable {
    assertions = [
      {
        assertion = config.age.secrets ? immichClientSecret;
        message = "Missing immichClientSecret secret; run scripts/generate-all-secrets.sh";
      }
    ];

    users.manageLingering = true;

    users.groups.${proxyGroup} = {
      gid = proxyGid;
    };

    users.users.${proxyUser} = {
      isSystemUser = true;
      uid = proxyUid;
      group = proxyGroup;
      home = "/var/lib/immich-public-proxy";
      createHome = true;
      linger = true;
      subUidRanges = [
        {
          startUid = proxySubIdStart;
          count = proxySubIdCount;
        }
      ];
      subGidRanges = [
        {
          startGid = proxySubIdStart;
          count = proxySubIdCount;
        }
      ];
    };

    repo.identity = {
      groups."immich-users" = {
        owner = "immich";
        members = [ vars.kanidmAdminUser ];
      };

      oauth2Clients.immich-web = {
        owner = "immich";
        displayName = "Photos";
        imageFile = ../Core_Modules/kanidm/assets/photos.svg;
        originUrl = [
          "https://${vars.photosDomain}/auth/login"
          "https://${vars.photosDomain}/user-settings"
          "https://${vars.photosDomain}/api/oauth/mobile-redirect"
        ];
        originLanding = "https://${vars.photosDomain}";
        basicSecretFile = config.age.secrets.immichClientSecret.path;
        preferShortUsername = true;
        scopeMaps."immich-users" = [ "openid" "profile" "email" "immich_role" ];
        supplementaryScopeMaps."app-admin" = [ "immich_role" ];
        claimMaps.immich_role.valuesByGroup."app-admin" = [ "admin" ];
      };
    };
  };
}
