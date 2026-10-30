{ config, lib, options, ... }:

{
  # Imported only when both apps are present. Search contacts SearXNG solely
  # for the explicitly selected Online papers type; no new host is exposed.
  config = lib.optionalAttrs
    (
      lib.hasAttrByPath [ "repo" "search" ] options
      && lib.hasAttrByPath [ "repo" "searxng" ] options
    )
    (lib.mkIf (config.repo.search.enable && config.repo.searxng.enable) {
      systemd.services.search-ui = {
        environment.SEARCH_SEARXNG_URL = "http://127.0.0.1:${toString config.repo.searxng.port}";
        wants = [ "searxng.service" ];
        after = [ "searxng.service" ];
      };
    });
}
