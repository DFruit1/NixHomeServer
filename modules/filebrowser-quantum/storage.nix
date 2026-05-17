{ config, lib, vars, ... }:

{
  config = lib.mkIf config.nixhomeserver.apps."filebrowser-quantum".enable {
    systemd.services.filebrowser-quantum-storage-layout-v1 = {
      description = "Provision FileBrowser Quantum storage layout";
      wantedBy = [ "multi-user.target" ];
      wants = [ "data-pool-layout.service" "local-fs.target" ];
      after = [ "data-pool-layout.service" "local-fs.target" ];
      before = [ "filebrowser-quantum.service" ];
      unitConfig.ConditionPathIsMountPoint = vars.dataRoot;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        set -euo pipefail
        install -d -m 2775 -o root -g users '${vars.sharedRoot}/files'
        install -d -m 2775 -o root -g users '${vars.sharedRoot}/kiwix'
        install -d -m 0750 -o root -g kiwix '${vars.kiwixLibraryRoot}'
      '';
    };

    fileSystems."${vars.sharedRoot}/kiwix" = {
      device = vars.kiwixLibraryRoot;
      options = [
        "bind"
        "nofail"
        "x-systemd.requires=data-pool-layout.service"
      ];
    };

    systemd.services.filebrowser-quantum = {
      wants = [ "filebrowser-quantum-storage-layout-v1.service" ];
      after = [ "filebrowser-quantum-storage-layout-v1.service" ];
    };
  };
}
