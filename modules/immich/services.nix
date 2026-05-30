{ vars, config, ... }:

let
  immichPort = vars.networking.ports.immich;
  shareHost = "sharephotos.${vars.domain}";
in
{
  imports = [
    ./admin-reconcile.nix
    ./public-proxy.nix
  ];

  config = {
    services.immich = {
      enable = true;
      host = vars.networking.loopbackIPv4;
      port = immichPort;
      mediaLocation = config.repo.immich.paths.managed;
      user = "immich";
      group = "immich";
      settings.server.externalDomain = "https://${shareHost}";
      settings.oauth = {
        enabled = true;
        clientId = "immich-web";
        clientSecret._secret = config.age.secrets.immichClientSecret.path;
        issuerUrl = vars.kanidmIssuer "immich-web";
        mobileOverrideEnabled = false;
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
      machine-learning = {
        enable = true;
        environment.MPLCONFIGDIR = "/var/cache/immich/matplotlib";
      };
    };

    systemd.services.immich-server = {
      after = [ "data-pool-layout.service" ];
      wants = [ "data-pool-layout.service" ];
    };
  };
}
