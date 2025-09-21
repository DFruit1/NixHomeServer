{ vars, config, ... }:

{
  services.immich = {
    enable = true;
    host = "127.0.0.1";
    port = vars.immichPort;
    mediaLocation = "${vars.dataRoot}/immich";
    user = "immich";
    group = "immich";
    settings.server.externalDomain = "https://photoshare.${vars.domain}";
    database = {
      enable = true;
      createDB = true;
      name = "immich";
      user = "immich";
    };
    redis.enable = true;
    machine-learning.enable = true;
  };

  systemd.services.immich-server.environment = {
    IMMICH_OIDC_ENABLED = "true";
    IMMICH_OIDC_CLIENT_ID = "immich-web";
    IMMICH_OIDC_CLIENT_SECRET_FILE = config.age.secrets.immichClientSecret.path;
    IMMICH_OIDC_ISSUER = vars.kanidmIssuer;
    IMMICH_OIDC_SCOPE = "openid profile email";
  };

  systemd.services.immich-server.serviceConfig.AppArmorProfile = "generated-immich-server";
}
