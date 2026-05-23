{ config, lib, vars, ... }:

{
  config = lib.mkIf config.nixhomeserver.apps."mail-archive-ui".enable {
    assertions = [
      {
        assertion = config.age.secrets ? mailArchiveOauth2ProxyClientSecret;
        message = "Missing mailArchiveOauth2ProxyClientSecret secret; run scripts/generate-all-secrets.sh";
      }
      {
        assertion = config.age.secrets ? mailArchiveOauth2ProxyCookieSecret;
        message = "Missing mailArchiveOauth2ProxyCookieSecret secret; run scripts/generate-all-secrets.sh";
      }
    ];

    users.groups.mail-archive-ui = { };

    users.users.mail-archive-ui = {
      isSystemUser = true;
      group = "mail-archive-ui";
      home = config.services.mail-archive-ui.dataDir;
      createHome = false;
    };

    repo.identity = {
      groups."mail-archive-users" = {
        owner = "mail-archive-ui";
        members = [ ];
      };

      oauth2Clients.mail-archive-web = {
        owner = "mail-archive-ui";
        displayName = "Mail Archive";
        imageFile = ../Core_Modules/kanidm/assets/mail.svg;
        originUrl = "https://${vars.emailsDomain}/oauth2/callback";
        originLanding = "https://${vars.emailsDomain}";
        basicSecretFile = config.age.secrets.mailArchiveOauth2ProxyClientSecret.path;
        preferShortUsername = true;
        scopeMaps."mail-archive-users" = [ "openid" "profile" "email" "groups_name" ];
      };
    };
  };
}
