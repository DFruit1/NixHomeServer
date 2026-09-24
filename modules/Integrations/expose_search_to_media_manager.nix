{ vars, ... }:

{
  # Media Manager keeps its own path-scoped filter, but metadata and full-text
  # discovery belong to the Search app (which already indexes the library
  # metadata snapshots). This module is imported only when Search is enabled, so
  # Search stays an optional integration rather than a Media Manager dependency.
  repo.mediaManager.integrations.search = {
    available = true;
    label = "Advanced search";
    capabilities = [ "advanced-search" ];
    url = "https://search.${vars.domain}";
  };
}
