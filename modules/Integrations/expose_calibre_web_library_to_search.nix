{ config, lib, options, vars, ... }:

{
  config = lib.optionalAttrs
    (
      lib.hasAttrByPath [ "repo" "search" ] options
      && lib.hasAttrByPath [ "repo" "calibreWeb" ] options
    )
    (lib.mkIf (config.repo.search.enable && config.repo.calibreWeb.enable) {
      repo.search.sources.calibre = {
        displayName = "Technical Library";
        sourceType = "calibre";
        appBase = "https://calibre.${vars.domain}";
        settings = {
          libraryRoot = config.repo.calibreWeb.paths.libraryRoot;
        };
      };

      # The indexer walks the Calibre library's metadata.db and book files.
      users.users.search.extraGroups = lib.mkAfter [ "calibre-web" ];
    });
}
