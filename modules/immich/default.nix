{ vars, config, ... }:

{
  services.immich = {
    enable = true;
    host = "127.0.0.1";
    port = vars.immichPort;
    mediaLocation = "${vars.dataRoot}/immich";
    user = "immich";
    group = "immich";
    settings.server.externalDomain = "https://${vars.photosDomain}";
    settings.oauth = {
      enabled = true;
      clientId = "immich-web";
      clientSecret._secret = config.age.secrets.immichClientSecret.path;
      issuerUrl = vars.kanidmIssuer "immich-web";
      signingAlgorithm = "ES256";
      scope = "openid profile email";
      buttonText = "Login with Kanidm";
      autoRegister = true;
    };
    database = {
      enable = true;
      createDB = true;
      name = "immich";
      user = "immich";
    };
    redis.enable = true;
    machine-learning.enable = true;
  };

  systemd.tmpfiles.rules = [
    "d ${vars.dataRoot}/immich 0750 immich immich -"
  ];
}
