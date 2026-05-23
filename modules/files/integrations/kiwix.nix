{ lib, vars, ... }:

{
  users.users.filestash.extraGroups = lib.mkAfter [ "kiwix" ];

  systemd.services.filestash.serviceConfig.ReadWritePaths = lib.mkAfter [
    vars.kiwixLibraryRoot
  ];
}
