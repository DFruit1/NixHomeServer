{ config, lib, options, vars, ... }:

{
  config = lib.optionalAttrs
    (
      lib.hasAttrByPath [ "repo" "search" ] options
      && lib.hasAttrByPath [ "repo" "freshrss" ] options
    )
    (lib.mkIf (config.repo.search.enable && config.repo.freshrss.enable) {
      repo.search.sources.freshrss = {
        displayName = "Feeds";
        sourceType = "freshrss";
        aclGroup = "freshrss-users";
        appBase = "https://rss.${vars.domain}";
        settings = {
          stateDir = config.repo.freshrss.stateDir;
        };
      };

      # The indexer reads the per-user FreshRSS SQLite databases read-only.
      users.users.search.extraGroups = lib.mkAfter [ "freshrss" ];
    });
}
