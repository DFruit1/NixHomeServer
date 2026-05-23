{ config, lib, ... }:

{
  config = lib.mkIf
    (
      config.nixhomeserver.apps.files.enable
      && config.nixhomeserver.apps.jellyfin.enable
    )
    {
      users.users.filestash.extraGroups = lib.mkAfter [ "jellyfin-media" ];
    };
}
