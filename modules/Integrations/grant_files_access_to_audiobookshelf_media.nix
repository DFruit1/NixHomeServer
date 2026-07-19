{ lib, options, ... }:

{
  config = lib.optionalAttrs (
    lib.hasAttrByPath [ "repo" "files" ] options
    && lib.hasAttrByPath [ "repo" "audiobookshelf" ] options
  ) {
    users.users.filestash.extraGroups = lib.mkAfter [ "audiobookshelf-media" ];
  };
}
