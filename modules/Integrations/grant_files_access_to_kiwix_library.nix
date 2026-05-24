{ config, lib, ... }:

{
  users.users.filestash.extraGroups = lib.mkAfter [ "kiwix" ];

  systemd.services.filestash.serviceConfig.ReadWritePaths = lib.mkAfter [
    config.services.kiwixServe.libraryRoot
  ];
}
