{ config, lib, vars, ... }:

{
  config = lib.mkIf config.nixhomeserver.apps.jellyfin.enable {
    users.groups.jellyfin-media = { };

    users.users.jellyfin.extraGroups = lib.mkAfter [ "jellyfin-media" ];

    repo.identity.groups."jellyfin-users" = {
      owner = "jellyfin";
      members = [ vars.kanidmAdminUser ];
    };
  };
}
