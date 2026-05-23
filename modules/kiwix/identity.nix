{ config, vars, ... }:

let
  host = "wiki.${vars.domain}";
in

{
  config = {
    assertions = [
      {
        assertion = config.age.secrets ? kiwixOauth2ProxyClientSecret;
        message = "Missing kiwixOauth2ProxyClientSecret secret; run scripts/generate-all-secrets.sh";
      }
      {
        assertion = config.age.secrets ? kiwixOauth2ProxyCookieSecret;
        message = "Missing kiwixOauth2ProxyCookieSecret secret; run scripts/generate-all-secrets.sh";
      }
    ] ++ map
      (user: {
        assertion = builtins.hasAttr user config.users.users;
        message = "services.kiwixServe.extraUploadUsers entry '${user}' must name a local Unix account.";
      })
      config.services.kiwixServe.extraUploadUsers;

    users.groups.kiwix = { };

    users.users.kiwix = {
      isSystemUser = true;
      group = "kiwix";
      home = config.services.kiwixServe.stateDir;
      createHome = false;
    };

    services.kanidm.provision.systems.oauth2.kiwix-web = {
      displayName = "Kiwix";
      imageFile = ../Core_Modules/kanidm/assets/books.svg;
      originUrl = "https://${host}/oauth2/callback";
      originLanding = "https://${host}";
      basicSecretFile = config.age.secrets.kiwixOauth2ProxyClientSecret.path;
      preferShortUsername = true;
      scopeMaps.users = [ "openid" "profile" "email" "groups_name" ];
    };
  };
}
