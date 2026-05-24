{ config, lib, vars, ... }:

let
  host = "books.${vars.domain}";
in

{
  config = {
    users.groups.kavita-media = { };

    users.users.kavita.extraGroups = lib.mkAfter [ "kavita-media" ];

    services.kanidm.provision = {
      groups."kavita-users".members = vars.kanidmAppUsers;

      systems.oauth2.kavita-web = {
        displayName = "Books";
        imageFile = ../Core_Modules/kanidm/assets/books.svg;
        originUrl = [
          "https://${host}/signin-oidc"
          "https://${host}/signout-callback-oidc"
        ];
        originLanding = "https://${host}/";
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
