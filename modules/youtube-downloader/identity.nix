{ config, vars, ... }:

let
  host = "ytdownload.${vars.domain}";
in

{
  config = {
    users.groups.youtube-downloader = { };

    users.users.youtube-downloader = {
      isSystemUser = true;
      group = "youtube-downloader";
      extraGroups = [ "users" ];
      home = "/var/lib/youtube-downloader";
      createHome = true;
    };

    services.kanidm.provision = {
      groups."downloads-users".members = vars.kanidmAppUsers;

      systems.oauth2.youtube-downloader-web = {
        displayName = "Downloads";
        imageFile = ../Core_Modules/kanidm/assets/apps/youtube.svg;
        originUrl = "https://${host}/oauth2/callback";
        originLanding = "https://${host}";
        basicSecretFile = config.age.secrets.youtubeDownloaderOauth2ProxyClientSecret.path;
        preferShortUsername = true;
        scopeMaps."downloads-users" = [ "openid" "profile" "email" "groups_name" ];
      };

      # Public PKCE client for the native desktop and Android shells. Desktop
      # uses a loopback redirect with an arbitrary port, so localhost redirects
      # are enabled per RFC 8252; Android uses the app's custom scheme.
      systems.oauth2.youtube-downloader-app = {
        displayName = "Downloads (app)";
        imageFile = ../Core_Modules/kanidm/assets/apps/youtube.svg;
        originUrl = [ "org.sydneybasiniot.youtubedownloader://auth/callback" ];
        originLanding = "https://${host}";
        public = true;
        enableLocalhostRedirects = true;
        preferShortUsername = true;
        scopeMaps."downloads-users" = [ "openid" "profile" "email" "groups_name" ];
      };
    };
  };
}
