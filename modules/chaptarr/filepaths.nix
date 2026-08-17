{ config, lib, pkgs, vars, ... }:

let
  cfg = config.repo.chaptarr;
  paths = cfg.paths;
  booksParent = builtins.dirOf paths.ebookRoot;
  aclPolicyKey = builtins.substring 0 16 (builtins.hashString "sha256" (
    lib.concatStringsSep "\n" [
      "chaptarr-library-acl-v1"
      paths.audiobookRoot
      paths.ebookRoot
    ]
  ));
in
{
  options.repo.chaptarr.paths = {
    stateDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/chaptarr";
      readOnly = true;
      description = "Persistent Chaptarr configuration and database directory.";
    };

    audiobookRoot = lib.mkOption {
      type = lib.types.str;
      default = "${vars.sharedRoot}/_Audiobooks";
      description = "Shared audiobook library managed by Chaptarr.";
    };

    ebookRoot = lib.mkOption {
      type = lib.types.str;
      default = "${vars.sharedRoot}/_Books/_Ebooks";
      description = "Shared ebook library managed by Chaptarr.";
    };

    downloadRoot = lib.mkOption {
      type = lib.types.str;
      default = "${vars.sharedRoot}/_Downloads/qbittorrent";
      description = "Shared download staging root visible to Chaptarr.";
    };
  };

  config = lib.mkIf cfg.enable {
    repo.storage.dataPool.guardedServices = [ "chaptarr-storage-layout-v1" ];
    repo.storage.sharedRoots.contentSubdirs = [
      "_Audiobooks"
      "_Books"
      "_Downloads"
    ];

    systemd.services.chaptarr-storage-layout-v1 = {
      description = "Provision Chaptarr audiobook, ebook, and download storage";
      wantedBy = [ "multi-user.target" ];
      wants = [
        "data-pool-layout.service"
        "local-fs.target"
      ];
      after = [
        "data-pool-layout.service"
        "local-fs.target"
      ];
      before = [ "chaptarr.service" ];
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

        managed_dir=${lib.escapeShellArg "${paths.stateDir}/.nixos-managed"}
        acl_marker="$managed_dir/library-acl-${aclPolicyKey}"
        install -d -m 0750 -o chaptarr -g chaptarr "$managed_dir"
        install -d -m 1770 -o root -g root ${lib.escapeShellArg booksParent}
        for path in ${lib.escapeShellArgs [ paths.audiobookRoot paths.ebookRoot ]}; do
          install -d -m 0770 -o root -g root "$path"
          setfacl -m g:chaptarr:rwx,d:g:chaptarr:rwx "$path"
        done
        install -d -m 1770 -o root -g root ${lib.escapeShellArg paths.downloadRoot}
        setfacl -m g:chaptarr:--x ${lib.escapeShellArg paths.downloadRoot}
        setfacl -m g:chaptarr:--x ${lib.escapeShellArg vars.sharedRoot} ${lib.escapeShellArg booksParent}

        if [[ ! -e "$acl_marker" ]]; then
          for path in ${lib.escapeShellArgs [ paths.audiobookRoot paths.ebookRoot ]}; do
            setfacl -P -R -m g:chaptarr:rwX "$path"
            find "$path" -type d -exec setfacl -m d:g:chaptarr:rwx '{}' +
          done
          install -m 0640 -o chaptarr -g chaptarr /dev/null "$acl_marker"
        fi
      '';
    };
  };
}
