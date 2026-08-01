{ config, vars, ... }:

let
  cfg = config.repo.mediaManager;
in
{
  users.groups.media-manager = { };
  users.groups.media-manager-broker = { };
  users.users.media-manager = {
    isSystemUser = true;
    group = "media-manager";
    home = cfg.stateDir;
  };
  users.users.media-manager-broker = {
    isSystemUser = true;
    group = "media-manager";
    extraGroups = [ "media-manager-broker" ];
    home = cfg.stateDir;
  };

  nixhomeserver.kanidmGroupDescriptions.${cfg.editorGroup} =
    "Grants staged Media Manager metadata and library mutation permissions.";

  services.kanidm.provision.groups.${cfg.editorGroup} = {
    members = [ vars.kanidmAdminUser ];
    overwriteMembers = false;
  };

  services.kanidm.provision.systems.oauth2.auth-gateway-web.scopeMaps.${cfg.editorGroup} =
    [ "openid" "profile" "email" "groups_name" ];
}
