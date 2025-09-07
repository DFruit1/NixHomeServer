{ vars, config, ... }:
{
  services.immich = {
    enable  = true;
    mediaLocation = "${vars.dataRoot}/immich";
    port = vars.immichPort;
  };

  systemd.services.immich.environment = {
    IMMICH_OIDC_ENABLED            = "true";
    IMMICH_OIDC_CLIENT_ID          = "immich-web";
    IMMICH_OIDC_CLIENT_SECRET_FILE = config.age.secrets.immichClientSecret.path;
    IMMICH_OIDC_ISSUER             = vars.kanidmIssuer;
    IMMICH_OIDC_SCOPE              = "openid profile email";
  };
}
