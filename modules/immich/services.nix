{ vars, config, lib, pkgs, unstablePkgs, ... }:

let
  immichPort = vars.networking.ports.immich;
  shareHost = "sharephotos.${vars.domain}";
  clipModel = "ViT-SO400M-16-SigLIP2-384__webli";
  v3MigrationMarker = "/var/lib/immich/.nixhomeserver-v3-schema-migration-started";
  preV3RollbackGuard = pkgs.writeShellScript "immich-pre-v3-rollback-guard" ''
    set -eu
    ${lib.optionalString (lib.versionOlder config.services.immich.package.version "3.0.0") ''
      if [[ -e ${lib.escapeShellArg v3MigrationMarker} ]]; then
        echo "Refusing to start pre-v3 Immich after the v3 schema migration marker was created" >&2
        exit 1
      fi
    ''}
  '';
in
{
  imports = [
    ./admin-reconcile.nix
    ./public-proxy.nix
  ];

  config = {
    services.immich = {
      enable = true;
      package = unstablePkgs.immich;
      host = vars.networking.loopbackIPv4;
      port = immichPort;
      mediaLocation = config.repo.immich.paths.managed;
      user = "immich";
      group = "immich";
      settings.server.externalDomain = "https://${shareHost}";
      settings.job.smartSearch.concurrency = 4;
      settings.machineLearning.clip.modelName = clipModel;
      settings.oauth = {
        enabled = true;
        clientId = "immich-web";
        clientSecret._secret = config.age.secrets.immichClientSecret.path;
        issuerUrl = vars.kanidmIssuer "immich-web";
        endSessionEndpoint = "https://${config.repo.authGateway.domain}/oauth2/sign_out";
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
        environment = {
          GUNICORN_CMD_ARGS = "--no-control-socket";
          MACHINE_LEARNING_PRELOAD__CLIP__TEXTUAL = clipModel;
          PYTHONUTF8 = "1";
        };
      };
    };

    systemd.services.immich-server = {
      after = [ "data-pool-layout.service" ];
      wants = [ "data-pool-layout.service" ];
      serviceConfig.ExecStartPre = [ preV3RollbackGuard ];
    };

    systemd.services.immich-machine-learning.serviceConfig = {
      MemoryHigh = lib.mkForce "10G";
      MemoryMax = lib.mkForce "12G";
    };
  };
}
