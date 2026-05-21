{ config, lib, vars, ... }:

{
  config = lib.mkIf config.nixhomeserver.apps.kavita.enable {
    repo.identity = {
      groups."kavita-users" = {
        owner = "kavita";
        members = [ vars.kanidmAdminUser ];
      };

      oauth2Clients.kavita-web = {
        owner = "kavita";
        displayName = "Books";
        imageFile = ../Core_Modules/kanidm/assets/books.svg;
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
    };
  };
}
