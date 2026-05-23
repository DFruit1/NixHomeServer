{ config, lib, vars, ... }:

{
  config = lib.mkIf config.nixhomeserver.apps."youtube-downloader".enable {
    assertions = [
      {
        assertion = config.age.secrets ? youtubeDownloaderOauth2ProxyClientSecret;
        message = "Missing youtubeDownloaderOauth2ProxyClientSecret secret; run scripts/generate-all-secrets.sh";
      }
      {
        assertion = config.age.secrets ? youtubeDownloaderOauth2ProxyCookieSecret;
        message = "Missing youtubeDownloaderOauth2ProxyCookieSecret secret; run scripts/generate-all-secrets.sh";
      }
    ];

    users.groups.youtube-downloader = {
      gid = 3002;
    };

    users.users.youtube-downloader = {
      isSystemUser = true;
      uid = 3002;
      group = "youtube-downloader";
      extraGroups = [ "users" ];
      home = "/var/lib/youtube-downloader";
      createHome = true;
    };

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
