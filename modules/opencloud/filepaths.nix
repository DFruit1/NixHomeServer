{ config, lib, pkgs, vars, ... }:

let
  cfg = config.repo.opencloud;
  stateDir = cfg.paths.stateDir;
in
{
  options.repo.opencloud.paths = {
    stateDir = lib.mkOption {
      type = lib.types.str;
      default = "${vars.dataRoot}/opencloud";
      description = "OpenCloud base data directory holding PosixFS storage, the IDM directory, caches, and generated config.";
    };
  };

  config = {
    # Every unit below reads or writes the data pool, so the core layout
    # injection makes them fail closed when the pool is unavailable.
    repo.storage.dataPool.guardedServices = [
      "opencloud-storage-layout-v1"
      "opencloud-secret-materialize"
      "opencloud-init-config"
      "opencloud"
    ];

    systemd.services.opencloud-storage-layout-v1 = {
      description = "Provision OpenCloud storage layout";
      wantedBy = [ "multi-user.target" ];
      wants = [ "data-pool-layout.service" "local-fs.target" ];
      after = [ "data-pool-layout.service" "local-fs.target" ];
      before = [
        "opencloud-secret-materialize.service"
        "opencloud-init-config.service"
        "opencloud.service"
        "coolwsd.service"
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        set -euo pipefail
        ${pkgs.coreutils}/bin/install -d -m 0750 -o opencloud -g opencloud ${lib.escapeShellArg stateDir}
        ${pkgs.coreutils}/bin/install -d -m 0750 -o opencloud -g opencloud ${lib.escapeShellArg "${stateDir}/config"}
        ${pkgs.coreutils}/bin/install -d -m 0750 -o opencloud -g opencloud ${lib.escapeShellArg "${stateDir}/storage"}
      '';
    };
  };
}
