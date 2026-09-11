{ lib }:

lib.types.submodule {
  options = {
    order = lib.mkOption { type = lib.types.int; };
    id = lib.mkOption { type = lib.types.str; };
    name = lib.mkOption { type = lib.types.str; };
    url = lib.mkOption { type = lib.types.str; };
    enabled = lib.mkOption { type = lib.types.bool; };
    category = lib.mkOption { type = lib.types.str; };
    description = lib.mkOption { type = lib.types.str; };
    loginNotes = lib.mkOption { type = lib.types.str; };
    logoUrl = lib.mkOption { type = lib.types.str; };
    appName = lib.mkOption { type = lib.types.str; };
    uploadNotes = lib.mkOption { type = lib.types.str; };
    projectUrl = lib.mkOption { type = lib.types.nullOr lib.types.str; default = null; };
    requiredAllGroups = lib.mkOption { type = lib.types.nullOr (lib.types.listOf lib.types.str); default = null; };
    requiredAnyGroups = lib.mkOption { type = lib.types.nullOr (lib.types.listOf lib.types.str); default = null; };
  };
}
