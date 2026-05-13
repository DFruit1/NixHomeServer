{ vars, ... }:

{
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
    '';
  };

  systemd.services.filebrowser-quantum = {
    wants = [ "filebrowser-quantum-storage-layout-v1.service" ];
    after = [ "filebrowser-quantum-storage-layout-v1.service" ];
  };
}
