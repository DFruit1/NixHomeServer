{ config, lib, options, ... }:

{
  config = lib.mkIf
    (
      lib.hasAttrByPath [ "repo" "files" ] options
      && lib.hasAttrByPath [ "repo" "kiwix" ] options
    )
    (lib.mkIf config.repo.kiwix.enable {
      users.users.filestash.extraGroups = lib.mkAfter [ "kiwix" ];

      systemd.services.filestash.serviceConfig.ReadWritePaths = lib.mkAfter [
        config.repo.kiwix.paths.libraryRoot
      ];
    });
}
