{ config, lib, vars, ... }:

{
  config = lib.mkIf config.nixhomeserver.apps.jellyfin.enable {
    repo.identity.groups."jellyfin-users" = {
      owner = "jellyfin";
      members = [ vars.kanidmAdminUser ];
    };
  };
}
