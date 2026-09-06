{ config, lib, options, vars, ... }:

{
  config = lib.optionalAttrs
    (
      lib.hasAttrByPath [ "repo" "search" ] options
      && lib.hasAttrByPath [ "repo" "kiwix" ] options
    )
    (lib.mkIf (config.repo.search.enable && config.repo.kiwix.enable) {
      repo.search.sources.kiwix = {
        displayName = "Wiki";
        sourceType = "kiwix";
        aclGroup = "kiwix-users";
        appBase = "https://wiki.${vars.domain}";
        settings = {
          libraryRoot = config.repo.kiwix.paths.libraryRoot;
          metadataZims = config.repo.search.metadataZims;
          fulltextZims = config.repo.search.fulltextZims;
        };
      };

      # The indexer walks the uploaded ZIM library.
      users.users.search.extraGroups = lib.mkAfter [ "kiwix" ];
    });
}
