{ config, lib, vars, ... }:

let
  proxyUser = "immich-public-proxy";
  proxyGroup = "immich-public-proxy";
  proxyUid = 3001;
  proxyGid = 3001;
  proxySubIdStart = 400000;
  proxySubIdCount = 65536;
  host = "photos.${vars.domain}";
in

{
  config = {
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

    services.kanidm.provision = {
      groups."immich-users".members = [ vars.kanidmAdminUser ];

      systems.oauth2.immich-web = {
        displayName = "Photos";
        imageFile = ../Core_Modules/kanidm/assets/photos.svg;
        originUrl = [
          "https://${host}/auth/login"
          "https://${host}/user-settings"
          "https://${host}/api/oauth/mobile-redirect"
        ];
        originLanding = "https://${host}";
        basicSecretFile = config.age.secrets.immichClientSecret.path;
        preferShortUsername = true;
        scopeMaps."immich-users" = [ "openid" "profile" "email" "immich_role" ];
        supplementaryScopeMaps."app-admin" = [ "immich_role" ];
        claimMaps.immich_role.valuesByGroup."app-admin" = [ "admin" ];
      };
    };
  };
}
