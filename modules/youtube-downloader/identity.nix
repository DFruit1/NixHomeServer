{ config, pkgs, vars, ... }:

let
  host = "ytdownload.${vars.domain}";
  kanidmCliUrl = "https://${vars.kanidmDomain}:${toString vars.networking.ports.kanidm}";
  appRefreshTokenSeconds = config.repo.youtubeDownloader.appRefreshTokenDays * 86400;
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
        displayName = "YouTube Downloads";
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
        displayName = "YouTube Downloads (app)";
        imageFile = ../Core_Modules/kanidm/assets/apps/youtube.svg;
        originUrl = [ "org.sydneybasiniot.youtubedownloader://auth/callback" ];
        originLanding = "https://${host}";
        public = true;
        enableLocalhostRedirects = true;
        preferShortUsername = true;
        scopeMaps."downloads-users" = [ "openid" "profile" "email" "groups_name" ];
      };
    };

    # Kanidm hard-codes refresh tokens to 16 hours; raise the native app client
    # so the phone and desktop shells keep working without a fresh login.
    systemd.services.youtube-downloader-oauth2-refresh = {
      description = "Set the YouTube Downloader app refresh-token expiry";
      wantedBy = [ "multi-user.target" ];
      after = [ "kanidm.service" ];
      wants = [ "kanidm.service" ];
      path = [ pkgs.kanidm_1_11 ];
      script = ''
        set -euo pipefail

        export HOME="$(mktemp -d)"
        trap 'rm -rf "$HOME"' EXIT
        KANIDM_PASSWORD="$(< ${config.age.secrets.kanidmAdminPass.path})"
        export KANIDM_PASSWORD

        kanidm login \
          -H ${kanidmCliUrl} \
          -D idm_admin >/dev/null

        kanidm system oauth2 set-refresh-token-expiry \
          -H ${kanidmCliUrl} \
          -D idm_admin \
          youtube-downloader-app \
          ${toString appRefreshTokenSeconds}
      '';
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        Restart = "on-failure";
        RestartSec = "30s";
      };
    };
  };
}
