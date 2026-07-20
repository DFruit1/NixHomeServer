{ config, lib, pkgs, ... }:

let
  cfg = config.repo.kiwix;
  uploadUsers = lib.unique ([ cfg.uploadUser ] ++ cfg.extraUploadUsers);
  dirWriterAclArgs = lib.concatStringsSep " " (
    lib.concatMap
      (user: [
        ''-m u:${user}:rwx''
        ''-m d:u:${user}:rwx''
      ])
      uploadUsers
  );
in
{
  config = lib.mkIf cfg.enable {
    repo.storage.dataPool.guardedServices = [
      "kiwix-library-root-layout-v1"
      "kiwix-library-sync"
      "kiwix-library-watch"
      "kiwix-serve"
    ];

    repo.storage.sharedRoots.contentSubdirs = [ "_Kiwix" ];

    systemd.tmpfiles.rules = [
      "d ${cfg.stateDir} 0750 kiwix kiwix -"
    ];

    systemd.services.kiwix-library-root-layout-v1 = {
      description = "Provision Kiwix library root";
      wantedBy = [ "multi-user.target" ];
      wants = [ "data-pool-layout.service" "local-fs.target" ];
      after = [ "data-pool-layout.service" "local-fs.target" ];
      before = [ "kiwix-library-sync.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        set -euo pipefail

        library_root=${lib.escapeShellArg cfg.paths.libraryRoot}

        if [[ ! -d "$library_root" ]]; then
          ${pkgs.coreutils}/bin/install -d -m 0750 -o root -g kiwix "$library_root"
        fi
        ${pkgs.acl}/bin/setfacl \
          ${dirWriterAclArgs} \
          -m g:kiwix:rx \
          -m d:g:kiwix:rx \
          "$library_root"
      '';
    };

    systemd.services.kiwix-library-sync = {
      wants = [ "kiwix-library-root-layout-v1.service" ];
      after = [ "kiwix-library-root-layout-v1.service" ];
    };
  };
}
