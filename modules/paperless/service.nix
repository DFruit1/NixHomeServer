{ vars, ... }:

let
  paperlessPort = 8000;
  dataDir = "/var/lib/paperless";
  paperlessInboxDir = "${vars.mediaRoot}/documents/inbox";
  paperlessArchiveDir = "${vars.mediaRoot}/documents/archive";
  paperlessExportDir = "${vars.mediaRoot}/documents/export";
in
{
  services.paperless.environmentFile = "/run/paperless-oidc.env";

  users.users.paperless = {
    isSystemUser = true;
    group = "paperless";
    home = dataDir;
  };

  users.groups.paperless = { };

  services.paperless = {
    enable = true;
    dataDir = dataDir;
    mediaDir = paperlessArchiveDir;
    consumptionDir = paperlessInboxDir;
    address = "127.0.0.1";
    port = paperlessPort;

    settings = {
      PAPERLESS_SOCIAL_LOGIN_ENABLED = "true";
      PAPERLESS_SOCIALACCOUNT_ALLOW_SIGNUPS = "true";
      PAPERLESS_SOCIAL_AUTO_SIGNUP = "true";
      PAPERLESS_SOCIAL_DEFAULT_GROUPS = "Users";
      PAPERLESS_APPS = "allauth.socialaccount.providers.openid_connect";
      PAPERLESS_URL = "https://paperless.${vars.domain}";
      PAPERLESS_ALLOWED_HOSTS = "paperless.${vars.domain}";
      PAPERLESS_EXPORT_DIR = paperlessExportDir;
    };
  };

  systemd.tmpfiles.rules = [ ];
}
