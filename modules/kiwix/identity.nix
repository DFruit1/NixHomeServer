{ config, lib, vars, ... }:

{
  config = lib.mkIf config.nixhomeserver.apps.kiwix.enable {
    repo.identity.oauth2Clients.kiwix-web = {
      owner = "kiwix";
      displayName = "Kiwix";
      imageFile = ../Core_Modules/kanidm/assets/books.svg;
      originUrl = "https://${vars.kiwixDomain}/oauth2/callback";
      originLanding = "https://${vars.kiwixDomain}";
      basicSecretFile = config.age.secrets.kiwixOauth2ProxyClientSecret.path;
      preferShortUsername = true;
      scopeMaps.users = [ "openid" "profile" "email" "groups_name" ];
    };
  };
}
