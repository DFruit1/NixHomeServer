{ config, lib, options, ... }:

{
  config = lib.mkIf
    (
      lib.hasAttrByPath [ "repo" "files" ] options
      && lib.hasAttrByPath [ "repo" "calibreWeb" ] options
      && config.repo.calibreWeb.enable
    )
    {
      users.users.filestash.extraGroups = lib.mkAfter [ "calibre-web" ];
    };
}
