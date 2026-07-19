{ lib, options, ... }:

{
  config = lib.optionalAttrs (
    lib.hasAttrByPath [ "repo" "files" ] options
    && lib.hasAttrByPath [ "repo" "jellyfin" ] options
  ) {
    users.users.filestash.extraGroups = lib.mkAfter [ "jellyfin-media" ];
  };
}
