{ config, lib, ... }:

{
  config = lib.mkIf
    (
      config.nixhomeserver.apps.files.enable
      && config.nixhomeserver.apps.kavita.enable
    )
    {
      users.users.filestash.extraGroups = lib.mkAfter [ "kavita-media" ];
    };
}
