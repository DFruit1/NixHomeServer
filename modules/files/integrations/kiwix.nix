{ config, lib, vars, ... }:

{
  config = lib.mkIf
    (
      config.nixhomeserver.apps.files.enable
      && config.nixhomeserver.apps.kiwix.enable
    )
    {
      users.users.filestash.extraGroups = lib.mkAfter [ "kiwix" ];

      systemd.services.filestash.serviceConfig.ReadWritePaths = lib.mkAfter [
        vars.kiwixLibraryRoot
      ];
    };
}
