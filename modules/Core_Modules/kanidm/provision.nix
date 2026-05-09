{ config, vars, ... }:

let
  kanidmPort = 8443;
  kanidmCliUrl = "https://${vars.kanidmDomain}:${toString kanidmPort}";
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
    instanceUrl = kanidmCliUrl;

    persons.${vars.kanidmAdminUser} = {
      displayName = vars.kanidmAdminUser;
      mailAddresses = [ vars.kanidmAdminEmail ];
    };

    groups."user-files" = mkManualGroup [ vars.kanidmAdminUser ];
    groups."shared-files-ro" = mkManualGroup [ ];
    groups."app-admin" = mkManualGroup [ vars.kanidmAdminUser ];
    groups."mail-archive-users" = mkManualGroup [ ];
    groups."immich-users" = mkManualGroup [ vars.kanidmAdminUser ];
    groups."glances-users" = mkManualGroup vars.glancesAccessUsers;
    groups."paperless-users" = mkManualGroup [ vars.kanidmAdminUser ];
    groups."audiobookshelf-users" = mkManualGroup [ vars.kanidmAdminUser ];
    groups."kavita-users" = mkManualGroup [ vars.kanidmAdminUser ];
    groups."metube-users" = mkManualGroup [ vars.kanidmAdminUser ];
    groups.users = mkManualGroup [ vars.kanidmAdminUser ];

    systems.oauth2.immich-web = {
      displayName = "Photos";
      imageFile = ./assets/photos.svg;
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

    systems.oauth2.paperless-web = {
      displayName = "Documents";
      imageFile = ./assets/documents.svg;
      originUrl = "https://paperless.${vars.domain}/accounts/oidc/kanidm/login/callback/";
      originLanding = "https://paperless.${vars.domain}";
      basicSecretFile = config.age.secrets.paperlessClientSecret.path;
      preferShortUsername = true;
      scopeMaps."paperless-users" = [ "openid" "profile" "email" "groups_name" ];
      supplementaryScopeMaps."app-admin" = [ "groups_name" ];
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
      scopeMaps."audiobookshelf-users" = [ "openid" "profile" "email" "abs_role" ];
      supplementaryScopeMaps."app-admin" = [ "abs_role" ];
      claimMaps.abs_role = {
        joinType = "array";
        valuesByGroup."audiobookshelf-users" = [ "user" ];
        valuesByGroup."app-admin" = [ "admin" ];
      };
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
      scopeMaps."kavita-users" = [ "openid" "profile" "email" "kavita_roles" ];
      supplementaryScopeMaps."app-admin" = [ "kavita_roles" ];
      claimMaps.kavita_roles = {
        joinType = "array";
        valuesByGroup."kavita-users" = [ "Login" ];
        valuesByGroup."app-admin" = [ "Admin" ];
      };
    };

    systems.oauth2.oauth2-proxy = {
      displayName = "Uploads";
      imageFile = ./assets/files.svg;
      originUrl = "https://${vars.uploadsDomain}/oauth2/callback";
      originLanding = "https://${vars.uploadsDomain}";
      basicSecretFile = oauth2ProxyClientSecretPath;
      preferShortUsername = true;
      scopeMaps."user-files" = [ "openid" "profile" "email" "groups_name" ];
    };

    systems.oauth2.filebrowser-quantum-web = {
      displayName = "Files";
      imageFile = ./assets/files.svg;
      originUrl = "https://${vars.filebrowserDomain}/api/auth/oidc/callback";
      originLanding = "https://${vars.filebrowserDomain}/";
      basicSecretFile = config.age.secrets.filebrowserQuantumClientSecret.path;
      allowInsecureClientDisablePkce = true;
      preferShortUsername = true;
      scopeMaps."user-files" = [ "openid" "profile" "email" "groups_name" ];
      scopeMaps."shared-files-ro" = [ "openid" "profile" "email" "groups_name" ];
      scopeMaps.system_admins = [ "openid" "profile" "email" "groups_name" ];
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

    systems.oauth2.glances-web = {
      displayName = "Monitoring";
      imageFile = ./assets/portal.svg;
      originUrl = "https://${vars.monitorDomain}/oauth2/callback";
      originLanding = "https://${vars.monitorDomain}";
      basicSecretFile = config.age.secrets.glancesOauth2ProxyClientSecret.path;
      preferShortUsername = true;
      scopeMaps."glances-users" = [ "openid" "profile" "email" "groups_name" ];
    };

    systems.oauth2.kiwix-web = {
      displayName = "Kiwix";
      imageFile = ./assets/books.svg;
      originUrl = "https://${vars.kiwixDomain}/oauth2/callback";
      originLanding = "https://${vars.kiwixDomain}";
      basicSecretFile = config.age.secrets.kiwixOauth2ProxyClientSecret.path;
      preferShortUsername = true;
      scopeMaps.users = [ "openid" "profile" "email" "groups_name" ];
    };

    systems.oauth2.metube-web = {
      displayName = "Downloads";
      imageFile = ./assets/videos.svg;
      originUrl = "https://${vars.metubeDomain}/oauth2/callback";
      originLanding = "https://${vars.metubeDomain}";
      basicSecretFile = config.age.secrets.metubeOauth2ProxyClientSecret.path;
      preferShortUsername = true;
      scopeMaps."metube-users" = [ "openid" "profile" "email" "groups_name" ];
    };
  };
}
