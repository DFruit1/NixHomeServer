{ config, lib, pkgs, vars, ... }:

let
  cfg = config.repo.calibreWeb;
  calibreRoot = "${vars.sharedRoot}/_Calibre";
  emptyLibrary = pkgs.callPackage ./package.nix { };
in
{
  config = lib.mkIf cfg.enable {
    repo.storage.dataPool.guardedServices = [
      "calibre-web-library-layout-v1"
      "calibre-web"
    ];

    repo.storage.sharedRoots.contentSubdirs = [ "_Calibre" ];
    # `_Calibre` only holds the provisioned library directory, so it keeps the
    # sticky bit and cannot be deleted through any _Shared view.
    repo.storage.sharedRoots.structuralSubdirs = [ "_Calibre" ];

    systemd.services.calibre-web-library-layout-v1 = {
      description = "Provision the shared Calibre technical library";
      wantedBy = [ "multi-user.target" ];
      wants = [ "data-pool-layout.service" "local-fs.target" ];
      after = [ "data-pool-layout.service" "local-fs.target" ];
      before = [ "calibre-web.service" ];
      path = [
        pkgs.acl
        pkgs.coreutils
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        set -euo pipefail

        library_root=${lib.escapeShellArg cfg.paths.libraryRoot}
        calibre_root=${lib.escapeShellArg calibreRoot}
        state_dir=${lib.escapeShellArg cfg.paths.stateDir}

        # The state directory is bind-mounted from /persist, whose backing
        # directory is created root-owned before this unit runs. Re-assert
        # ownership here so Calibre-Web can open its app.db.
        install -d -m 0700 -o calibre-web -g calibre-web "$state_dir"

        install -d -m 1770 -o root -g root "$calibre_root"
        install -d -m 2770 -o calibre-web -g calibre-web "$library_root"

        # Members of the Calibre-Web group (the Search indexer and, when
        # enabled, Filestash) need to traverse the shared root into the library.
        setfacl -m g:calibre-web:r-X ${lib.escapeShellArg vars.sharedRoot}
        setfacl -m g:calibre-web:rwx "$calibre_root"

        if [[ ! -f "$library_root/metadata.db" ]]; then
          install -m 0644 -o calibre-web -g calibre-web \
            ${emptyLibrary}/metadata.db "$library_root/metadata.db"
        fi

        setfacl -m g:calibre-web:rwx,d:g:calibre-web:rwx "$library_root"
      '';
    };

    systemd.services.calibre-web = {
      wants = [ "calibre-web-library-layout-v1.service" ];
      after = [ "calibre-web-library-layout-v1.service" ];
    };
  };
}
