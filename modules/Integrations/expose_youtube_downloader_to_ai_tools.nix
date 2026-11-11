{ config, lib, options, ... }:
{
  config = lib.optionalAttrs
    (lib.hasAttrByPath [ "repo" "aiTools" ] options && lib.hasAttrByPath [ "repo" "youtubeDownloader" ] options)
    (lib.mkIf config.repo.aiTools.enable {
      # The shared gateway keeps downloads-users admission and passes the
      # caller to the existing job ownership/shared-write checks.
      repo.aiTools.youtubeHost = config.repo.authGateway.protectedApps.downloads.host;
    });
}
