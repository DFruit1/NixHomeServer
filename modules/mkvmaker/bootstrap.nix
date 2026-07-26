{ config, lib, pkgs, vars, ... }:

let
  cfg = config.repo.mkvmaker;
  sharedAccessGroup = vars.fileAccess.sharedAccessGroup or "files-shared-users";
in
{
  repo.storage.dataPool.guardedServices = [ "mkvmaker-storage-layout-v1" ];

  systemd.services.mkvmaker-storage-layout-v1 = {
    description = "Provision shared DVD ISO ingestion and Jellyfin output paths";
    wantedBy = [ "multi-user.target" ];
    requires = [ "data-pool-layout.service" ];
    wants = [ "local-fs.target" ];
    after = [ "data-pool-layout.service" "local-fs.target" ];
    before = [ "mkvmaker-import.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    path = [ pkgs.acl pkgs.coreutils ];
    script = ''
      set -euo pipefail

      install -d -m 3770 -o mkvmaker -g ${lib.escapeShellArg sharedAccessGroup} \
        ${lib.escapeShellArg cfg.paths.dvdInbox}
      install -d -m 2750 -o mkvmaker -g ${lib.escapeShellArg sharedAccessGroup} \
        ${lib.escapeShellArg "${cfg.paths.dvdInbox}/_Processed"} \
        ${lib.escapeShellArg "${cfg.paths.dvdInbox}/_Failed"}
      install -d -m 1770 -o root -g root \
        ${lib.escapeShellArg cfg.paths.moviesOutput} \
        ${lib.escapeShellArg cfg.paths.showsOutput}

      for path in \
        ${lib.escapeShellArg vars.sharedRoot} \
        ${lib.escapeShellArg cfg.paths.sharedIsoRoot} \
        ${lib.escapeShellArg "${vars.sharedRoot}/_Videos"}; do
        setfacl -m g:mkvmaker:r-X "$path"
      done
      for path in \
        ${lib.escapeShellArg cfg.paths.dvdInbox} \
        ${lib.escapeShellArg cfg.paths.moviesOutput} \
        ${lib.escapeShellArg cfg.paths.showsOutput}; do
        setfacl -m g:mkvmaker:rwx,d:g:mkvmaker:rwx "$path"
      done
    '';
  };
}
