{ config, lib, vars, ... }:

{
  config = lib.mkIf config.nixhomeserver.apps."mail-archive-ui".enable {
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
