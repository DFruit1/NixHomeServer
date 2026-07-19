{ lib, options, ... }:

{
  config = lib.optionalAttrs (
    lib.hasAttrByPath [ "repo" "files" ] options
    && lib.hasAttrByPath [ "repo" "kavita" ] options
  ) {
    users.users.filestash.extraGroups = lib.mkAfter [ "kavita-media" ];
  };
}
