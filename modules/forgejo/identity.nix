{ config, lib, vars, ... }:

let
  cfg = config.repo.forgejo;
  host = "git.${vars.domain}";
in

{
  config = lib.mkIf cfg.enable {
    services.kanidm.provision = {
      groups."forgejo-users".members = vars.kanidmAppUsers;

      systems.oauth2.forgejo-web = {
        displayName = "Git";
        imageFile = ../Core_Modules/kanidm/assets/apps/forgejo.svg;
        originUrl = [
          "https://${host}/user/oauth2/kanidm/callback"
        ];
        originLanding = "https://${host}/";
        basicSecretFile = config.age.secrets.forgejoClientSecret.path;
        # Forgejo usernames cannot contain "@", so the preferred_username claim
        # must carry Kanidm's short form.
        preferShortUsername = true;
        scopeMaps."forgejo-users" = [ "openid" "profile" "email" "forgejo_role" ];
        claimMaps.forgejo_role = {
          joinType = "array";
          valuesByGroup."app-admin" = [ "admin" ];
        };
      };
    };
  };
}
