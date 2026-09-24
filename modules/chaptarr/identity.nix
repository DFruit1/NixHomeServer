{ config, lib, vars, ... }:

let
  cfg = config.repo.chaptarr;
  host = "chaptarr.${vars.domain}";
in
{
  config = lib.mkIf cfg.enable {
    users.groups.chaptarr = { };
    users.users.chaptarr = {
      isSystemUser = true;
      group = "chaptarr";
      home = cfg.paths.stateDir;
    };

    services.kanidm.provision.groups."media-automation-users".members = vars.kanidmAppUsers;

    # Chaptarr authenticates through the shared auth gateway. This public
    # (secret-less) client exists only so the Kanidm app listing shows a
    # consistent "Book Downloads" card matching the homepage service card.
    services.kanidm.provision.systems.oauth2.chaptarr-web = {
      displayName = "Book Downloads";
      imageFile = ../Core_Modules/kanidm/assets/apps/chaptarr.svg;
      public = true;
      originUrl = "https://${host}/oauth2/callback";
      originLanding = "https://${host}";
      preferShortUsername = true;
      scopeMaps."media-automation-users" = [ "openid" "profile" "email" "groups_name" ];
    };
  };
}
