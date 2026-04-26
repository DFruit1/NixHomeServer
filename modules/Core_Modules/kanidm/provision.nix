{ config, vars, ... }:

let
  kanidmPort = 8443;
  oauth2ProxyClientSecretPath = "/run/oauth2-proxy/client-secret";
  mkManualGroup =
    members:
    {
      inherit members;
      overwriteMembers = false;
    };
in
{
  services.kanidm.provision = {
    enable = true;
    idmAdminPasswordFile = config.age.secrets.kanidmAdminPass.path;
    adminPasswordFile = config.age.secrets.kanidmSysAdminPass.path;
    instanceUrl = "https://localhost:${toString kanidmPort}";
    acceptInvalidCerts = true;

    persons.${vars.kanidmAdminUser} = {
      displayName = vars.kanidmAdminUser;
      mailAddresses = [ vars.kanidmAdminEmail ];
    };

    groups.fileshare_users = mkManualGroup [ vars.kanidmAdminUser ];
    groups."mail-archive-users" = mkManualGroup [ ];
    groups."immich-users" = mkManualGroup [ ];
    groups."immich-admin" = mkManualGroup [ vars.kanidmAdminUser ];
    groups."paperless-users" = mkManualGroup [ ];
    groups."paperless-admin" = mkManualGroup [ vars.kanidmAdminUser ];
    groups."audiobookshelf-users" = mkManualGroup [ ];
    groups."audiobookshelf-admin" = mkManualGroup [ vars.kanidmAdminUser ];
    groups."kavita-admin" = mkManualGroup [ vars.kanidmAdminUser ];
    groups."kavita-login" = mkManualGroup [ ];
    groups."jellyfin-users" = mkManualGroup [ ];
    groups."jellyfin-admin" = mkManualGroup [ vars.kanidmAdminUser ];
    groups.users = mkManualGroup [ vars.kanidmAdminUser ];

    systems.oauth2.immich-web = {
      displayName = "Photos";
      imageFile = ./assets/photos.svg;
      originUrl = "https://${vars.photosDomain}/auth/login";
      originLanding = "https://${vars.photosDomain}";
      basicSecretFile = config.age.secrets.immichClientSecret.path;
      preferShortUsername = true;
      scopeMaps."immich-users" = [ "openid" "profile" "email" ];
      scopeMaps."immich-admin" = [ "openid" "profile" "email" ];
    };

    systems.oauth2.paperless-web = {
      displayName = "Documents";
      imageFile = ./assets/documents.svg;
      originUrl = "https://paperless.${vars.domain}/accounts/oidc/kanidm/login/callback/";
      originLanding = "https://paperless.${vars.domain}";
      basicSecretFile = config.age.secrets.paperlessClientSecret.path;
      allowInsecureClientDisablePkce = true;
      preferShortUsername = true;
      scopeMaps."paperless-users" = [ "openid" "profile" "email" ];
      scopeMaps."paperless-admin" = [ "openid" "profile" "email" ];
    };

    systems.oauth2.abs-web = {
      displayName = "Audiobooks";
      imageFile = ./assets/audiobooks.svg;
      originUrl = [
        "https://${vars.audiobooksDomain}/audiobookshelf/auth/openid/callback"
        "https://${vars.audiobooksDomain}/audiobookshelf/auth/openid/mobile-redirect"
      ];
      originLanding = "https://${vars.audiobooksDomain}/audiobookshelf/";
      basicSecretFile = config.age.secrets.absClientSecret.path;
      preferShortUsername = true;
      scopeMaps."audiobookshelf-users" = [ "openid" "profile" "email" ];
      scopeMaps."audiobookshelf-admin" = [ "openid" "profile" "email" ];
    };

    systems.oauth2.kavita-web = {
      displayName = "Books";
      imageFile = ./assets/books.svg;
      originUrl = [
        "https://${vars.kavitaDomain}/signin-oidc"
        "https://${vars.kavitaDomain}/signout-callback-oidc"
      ];
      originLanding = "https://${vars.kavitaDomain}/";
      basicSecretFile = config.age.secrets.kavitaClientSecret.path;
      preferShortUsername = true;
      scopeMaps."kavita-login" = [ "openid" "profile" "email" "groups" ];
      scopeMaps."kavita-admin" = [ "openid" "profile" "email" "groups" ];
    };

    systems.oauth2.oauth2-proxy = {
      displayName = "Files";
      imageFile = ./assets/files.svg;
      originUrl = "https://${vars.filesDomain}/oauth2/callback";
      originLanding = "https://${vars.filesDomain}";
      basicSecretFile = oauth2ProxyClientSecretPath;
      preferShortUsername = true;
      scopeMaps.fileshare_users = [ "openid" "profile" "email" "groups" ];
    };

    systems.oauth2.mail-archive-web = {
      displayName = "Mail Archive";
      imageFile = ./assets/mail.svg;
      originUrl = "https://${vars.emailsDomain}/oauth2/callback";
      originLanding = "https://${vars.emailsDomain}";
      basicSecretFile = config.age.secrets.mailArchiveOauth2ProxyClientSecret.path;
      preferShortUsername = true;
      scopeMaps."mail-archive-users" = [ "openid" "profile" "email" "groups_name" ];
    };

    systems.oauth2.kiwix-web = {
      displayName = "Kiwix";
      imageFile = ./assets/books.svg;
      originUrl = "https://${vars.kiwixDomain}/oauth2/callback";
      originLanding = "https://${vars.kiwixDomain}";
      basicSecretFile = config.age.secrets.kiwixOauth2ProxyClientSecret.path;
      preferShortUsername = true;
      scopeMaps.users = [ "openid" "profile" "email" "groups" ];
    };
  };
}
