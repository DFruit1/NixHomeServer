{ lib, config, vars, ... }:

let
  paperlessIssuer = "https://${vars.kanidmDomain}/oauth2/openid/paperless-web";
in
{
  users.users.paperless = {
    isSystemUser = true;
    group = "paperless";
    home = "${vars.dataRoot}/paperless";
  };

  users.groups.paperless = { };

  ######################################################################
  ## Paperless-ngx (services.paperless)
  ######################################################################
  services.paperless = {
    enable = true;
    dataDir = "${vars.dataRoot}/paperless";
    address = "127.0.0.1";

    # extra package pin is optional; defaults to pkgs.paperless
    # package = pkgs.paperless;

    settings = {
      ##################################################################
      # 1.  Social / OIDC login
      ##################################################################
      PAPERLESS_SOCIAL_LOGIN_ENABLED = "true";
      PAPERLESS_SOCIAL_AUTO_SIGNUP = "true";
      PAPERLESS_SOCIAL_DEFAULT_GROUPS = "Users";

      PAPERLESS_OIDC_CLIENT_ID = "paperless-web";
      PAPERLESS_OIDC_CLIENT_SECRET_FILE = config.age.secrets.paperlessClientSecret.path;
      PAPERLESS_OIDC_PROVIDER_URL = paperlessIssuer;

      ##################################################################
      # 2.  Misc instance tweaks
      ##################################################################
      PAPERLESS_ALLOWED_HOSTS = "paperless.${vars.domain}";
      # PAPERLESS_TIME_ZONE              = "Australia/Sydney";   # ← example
      # PAPERLESS_LOGLEVEL               = "INFO";
    };
  };

  systemd.tmpfiles.rules = [
    "d ${vars.dataRoot}/paperless 0750 paperless paperless -"
  ];

  systemd.services."paperless-web".serviceConfig.AppArmorProfile = "generated-paperless-web";
}
