{ config, vars, ... }:

let
  host = "emails.${vars.domain}";
in

{
  config = {
    users.groups.mail-archive-ui = { };

    users.users.mail-archive-ui = {
      isSystemUser = true;
      group = "mail-archive-ui";
      home = config.services.mail-archive-ui.dataDir;
      createHome = false;
    };

    services.kanidm.provision = {
      groups."mail-archive-users".members = vars.kanidmAppUsers;

      systems.oauth2.mail-archive-web = {
        displayName = "Mail Archive";
        imageFile = ../Core_Modules/kanidm/assets/mail.svg;
        originUrl = "https://${host}/oauth2/callback";
        originLanding = "https://${host}";
        basicSecretFile = config.age.secrets.mailArchiveOauth2ProxyClientSecret.path;
        preferShortUsername = true;
        scopeMaps."mail-archive-users" = [ "openid" "profile" "email" "groups_name" ];
      };
    };
  };
}
