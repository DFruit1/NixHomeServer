{ config, lib, ... }:

{
  config = lib.mkIf
    (
      config.nixhomeserver.apps.files.enable
      && config.nixhomeserver.apps.audiobookshelf.enable
    )
    {
      users.users.filestash.extraGroups = lib.mkAfter [ "audiobookshelf-media" ];
    };
}
