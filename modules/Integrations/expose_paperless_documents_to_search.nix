{ config, lib, options, vars, ... }:

{
  config = lib.optionalAttrs
    (
      lib.hasAttrByPath [ "repo" "search" ] options
      && lib.hasAttrByPath [ "repo" "paperless" ] options
    )
    (lib.mkIf config.repo.search.enable {
      repo.search.sources.paperless = {
        displayName = "Documents";
        sourceType = "paperless";
        appBase = "https://paperless.${vars.domain}";
        settings = {
          exportPath = config.repo.paperless.paths.export;
        };
      };

      # The indexer reads the paperless exporter output directory.
      users.users.search.extraGroups = lib.mkAfter [ "paperless" ];
    });
}
