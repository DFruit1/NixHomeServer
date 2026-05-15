{ vars, config, ... }:

let
  immichPort = vars.networking.ports.immich;
in
{
  services.immich = {
    enable = true;
    host = vars.networking.loopbackIPv4;
    port = immichPort;
    mediaLocation = vars.immichManagedRoot;
    user = "immich";
    group = "immich";
    settings.server.externalDomain = "https://${vars.sharePhotosDomain}";
    settings.oauth = {
      enabled = true;
      clientId = "immich-web";
      clientSecret._secret = config.age.secrets.immichClientSecret.path;
      issuerUrl = vars.kanidmIssuer "immich-web";
      mobileOverrideEnabled = true;
      mobileRedirectUri = "https://${vars.photosDomain}/api/oauth/mobile-redirect";
      signingAlgorithm = "ES256";
      scope = "openid profile email immich_role";
      roleClaim = "immich_role";
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

  systemd.services.immich-server = {
    after = [ "data-pool-layout.service" ];
    wants = [ "data-pool-layout.service" ];
  };

  systemd.tmpfiles.rules = [ ];
}
