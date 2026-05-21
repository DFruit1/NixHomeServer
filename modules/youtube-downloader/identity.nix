{ config, lib, vars, ... }:

{
  config = lib.mkIf config.nixhomeserver.apps."youtube-downloader".enable {
    repo.identity = {
      groups."downloads-users" = {
        owner = "youtube-downloader";
        members = [ vars.kanidmAdminUser ];
      };

      oauth2Clients.youtube-downloader-web = {
        owner = "youtube-downloader";
        displayName = "Downloads";
        imageFile = ../Core_Modules/kanidm/assets/videos.svg;
        originUrl = "https://${vars.downloadsDomain}/oauth2/callback";
        originLanding = "https://${vars.downloadsDomain}";
        basicSecretFile = config.age.secrets.youtubeDownloaderOauth2ProxyClientSecret.path;
        preferShortUsername = true;
        scopeMaps."downloads-users" = [ "openid" "profile" "email" "groups_name" ];
      };
    };
  };
}
