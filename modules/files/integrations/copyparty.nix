{ lib, vars, ... }:

{
  users.users.filestash.extraGroups = lib.mkAfter [ "upload-review" ];

  systemd.services.filestash.serviceConfig.ReadWritePaths = lib.mkAfter [
    vars.uploadSecurity.quarantineRoot
  ];
}
