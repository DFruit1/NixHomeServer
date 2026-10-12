{ config, lib, pkgs, vars, ... }:

{
  # Persistence outlives optional apps. Retire the old model location from the
  # platform even when the Bonsai module is disabled or physically removed.
  repo.backups.rebuildableSnapshotPaths = [ "var/lib/bonsai/models" ];
  repo.storage.dataPool.guardedServices = [ "bonsai-model-archive" ];

  systemd.services.bonsai-model-archive = {
    description = "Archive legacy Bonsai model artifacts on the data pool";
    wantedBy = [ "multi-user.target" ];
    after = [ "local-fs.target" "persist-nesting-migration.service" ];
    before = [ "bonsai-storage-layout.service" "bonsai-model-prepare.service" "bonsai-llama.service" "kopia-persist-snapshot.service" ];
    path = with pkgs; [ coreutils findutils rsync systemd util-linux ];
    unitConfig.RequiresMountsFor = [ "/persist" vars.dataRoot ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      TimeoutStartSec = "2h";
      Nice = 10;
      CPUWeight = 20;
      IOWeight = 20;
      MemoryHigh = "256M";
      MemoryMax = "512M";
      UMask = "0027";
    };
    script = ''
      set -euo pipefail
      exec 9>${lib.escapeShellArg config.repo.backups.maintenanceLock}
      flock 9
      exec ${pkgs.bash}/bin/bash ${../../../scripts/helpers/archive-bonsai-models.sh} \
        /persist/var/lib/bonsai/models \
        ${lib.escapeShellArg "${vars.dataRoot}/bonsai/models"} \
        ${lib.escapeShellArg vars.dataRoot}
    '';
  };
}
