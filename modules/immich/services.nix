{ lib, vars, config, ... }:

let
  enabled = true;
  immichPort = vars.networking.ports.immich;
  resources = vars.resourceLimits;
  photosHost = "photos.${vars.domain}";
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
      mediaLocation = vars.immichManagedRoot;
      user = "immich";
      group = "immich";
      settings.server.externalDomain = "https://${shareHost}";
      settings.oauth = {
        enabled = true;
        clientId = "immich-web";
        clientSecret._secret = config.age.secrets.immichClientSecret.path;
        issuerUrl = vars.kanidmIssuer "immich-web";
        mobileOverrideEnabled = true;
        mobileRedirectUri = "https://${photosHost}/api/oauth/mobile-redirect";
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

    systemd.services.immich-machine-learning.serviceConfig = {
      MemoryMax = resources.immichMachineLearning.memoryMax;
      CPUQuota = resources.immichMachineLearning.cpuQuota;
    };
  };
}
