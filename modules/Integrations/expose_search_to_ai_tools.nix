{ config, lib, options, ... }:
{
  config = lib.optionalAttrs
    (lib.hasAttrByPath [ "repo" "aiTools" ] options && lib.hasAttrByPath [ "repo" "search" ] options)
    (lib.mkIf (config.repo.aiTools.enable && config.repo.search.enable) {
      # Calls go through Search's existing SSO and search-admins group gate.
      # Never pass its index credentials or filesystem grants to AI Tools.
      repo.aiTools.searchHost = config.repo.authGateway.protectedApps.search.host;
    });
}
