{ config, lib, pkgs, vars, ... }:

let
  cfg = config.repo.kavita;
  defaultLibraries = [
    {
      dir = "_Ebooks";
      type = 2;
      fileGroupTypes = [ 2 3 1 ];
      label = "Ebooks";
    }
    {
      dir = "_Comics";
      type = 1;
      fileGroupTypes = [ 1 4 3 ];
      label = "Comics";
    }
    {
      dir = "_Manga";
      type = 0;
      fileGroupTypes = [ 1 4 ];
      label = "Manga";
    }
  ];
  libraryType = lib.types.submodule {
    options = {
      dir = lib.mkOption { type = lib.types.str; };
      type = lib.mkOption { type = lib.types.int; };
      fileGroupTypes = lib.mkOption { type = lib.types.listOf lib.types.int; };
      label = lib.mkOption { type = lib.types.str; };
    };
  };
  userBookSubdirs = map (library: library.dir) cfg.libraries.personal;
  userBookWritablePaths = map (name: "_Books/${name}") userBookSubdirs;
  sharedKavitaDirs = map (library: "${cfg.paths.sharedBooksRoot}/${library.dir}") cfg.libraries.shared;
  sharedKavitaAnonDirs = map (library: "${cfg.paths.sharedBooksRoot}/${library.dir}/_Anon") cfg.libraries.shared;
in
{
  options.repo.kavita = {
    libraries = {
      personal = lib.mkOption {
        type = lib.types.listOf libraryType;
        default = defaultLibraries;
        description = "Kavita library definitions provisioned below each user's books directory.";
      };

      shared = lib.mkOption {
        type = lib.types.listOf libraryType;
        default = defaultLibraries;
        description = "Kavita library definitions provisioned below the shared books directory.";
      };
    };

    paths.sharedBooksRoot = lib.mkOption {
      type = lib.types.str;
      default = "${vars.sharedRoot}/_Books";
      description = "Shared Kavita books root.";
    };
  };

  config = {
    repo.storage.userRoots = {
      contentSubdirs = [ "_Books" ];
      bookSubdirs = userBookSubdirs;
      rootTraverseGroups = [
        "kavita-media"
      ];
      recursiveWritableGrants = [
        {
          group = "kavita-media";
          relativePaths = [ "_Books" ] ++ userBookWritablePaths;
        }
      ];
    };

    repo.storage.sharedRoots.contentSubdirs = [ "_Books" ];

    systemd.services.kavita-storage-layout-v1 = {
      description = "Provision Kavita storage layout";
      wantedBy = [ "multi-user.target" ];
      wants = [ "data-pool-layout.service" "local-fs.target" ];
      after = [ "data-pool-layout.service" "local-fs.target" ];
      before = [ "kavita.service" ];
      unitConfig = lib.mkIf vars.dataRootIsMountPoint {
        ConditionPathIsMountPoint = vars.dataRoot;
      };
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      path = [
        pkgs.acl
        pkgs.coreutils
        pkgs.findutils
      ];
      script = ''
        set -euo pipefail

        install -d -m 1770 -o root -g root ${cfg.paths.sharedBooksRoot}
        for path in ${lib.escapeShellArgs sharedKavitaDirs}; do
          install -d -m 1770 -o root -g root "$path"
        done
        for path in ${lib.escapeShellArgs sharedKavitaAnonDirs}; do
          install -d -m 1770 -o root -g root "$path"
        done

        setfacl -m g:kavita-media:r-X ${vars.sharedRoot} ${cfg.paths.sharedBooksRoot}
        for path in ${lib.escapeShellArgs sharedKavitaDirs}; do
          setfacl -m g:kavita-media:rwx,d:g:kavita-media:rwx "$path"
        done
      '';
    };

    systemd.services.kavita = {
      wants = [
        "data-pool-layout.service"
        "kavita-storage-layout-v1.service"
      ];
      after = [
        "data-pool-layout.service"
        "kavita-storage-layout-v1.service"
      ];
    };
  };
}
