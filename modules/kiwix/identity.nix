{ config, vars, ... }:

let
  host = "wiki.${vars.domain}";
in

{
  config = {
    assertions = map
      (user: {
        assertion = builtins.hasAttr user config.users.users;
        message = "repo.kiwix.extraUploadUsers entry '${user}' must name a local Unix account.";
      })
      config.repo.kiwix.extraUploadUsers;

    users.groups.kiwix = { };

    services.kanidm.provision.groups."kiwix-users".members = vars.kanidmAppUsers;

    users.users.kiwix = {
      isSystemUser = true;
      group = "kiwix";
      home = config.repo.kiwix.stateDir;
      createHome = false;
    };

    services.kanidm.provision.systems.oauth2.kiwix-web = {
      displayName = "Kiwix";
      imageFile = ../Core_Modules/kanidm/assets/books.svg;
      originUrl = "https://${host}/oauth2/callback";
      originLanding = "https://${host}";
      basicSecretFile = config.age.secrets.kiwixOauth2ProxyClientSecret.path;
      preferShortUsername = true;
      scopeMaps."kiwix-users" = [ "openid" "profile" "email" "groups_name" ];
    };
  };
}
