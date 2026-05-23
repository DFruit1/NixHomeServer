{ config, vars, ... }:

let
  host = "ytdownload.${vars.domain}";
in

{
  config = {
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

    services.kanidm.provision = {
      groups."downloads-users".members = vars.kanidmAppUsers;

      systems.oauth2.youtube-downloader-web = {
        displayName = "Downloads";
        imageFile = ../Core_Modules/kanidm/assets/videos.svg;
        originUrl = "https://${host}/oauth2/callback";
        originLanding = "https://${host}";
        basicSecretFile = config.age.secrets.youtubeDownloaderOauth2ProxyClientSecret.path;
        preferShortUsername = true;
        scopeMaps."downloads-users" = [ "openid" "profile" "email" "groups_name" ];
      };
    };
  };
}
