{ lib, vars, ... }:

{
  users.groups.jellyfin-media = { };

  users.users.jellyfin.extraGroups = lib.mkAfter [ "jellyfin-media" ];

  services.kanidm.provision.groups."jellyfin-users".members = [ vars.kanidmAdminUser ];
}
