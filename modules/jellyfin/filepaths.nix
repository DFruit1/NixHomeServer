{ config, lib, pkgs, vars, ... }:

let
  cfg = config.repo.jellyfin;
  defaultVideoLibraries = [
    {
      dir = "_Movies";
      collectionType = "movies";
      label = "Movies";
    }
    {
      dir = "_Shows";
      collectionType = "tvshows";
      label = "Shows";
    }
    {
      dir = "_Home";
      collectionType = "homevideos";
      label = "Home Videos";
    }
    {
      dir = "_Music-videos";
      collectionType = "musicvideos";
      label = "Music Videos";
    }
    {
      dir = "_YouTube";
      collectionType = "homevideos";
      label = "YouTube";
    }
  ];
  libraryType = lib.types.submodule {
    options = {
      dir = lib.mkOption { type = lib.types.str; };
      collectionType = lib.mkOption { type = lib.types.str; };
      label = lib.mkOption { type = lib.types.str; };
    };
  };
  userVideoSubdirs = map (library: library.dir) cfg.libraries.personal;
  sharedJellyfinDirs = map (library: "${cfg.paths.sharedVideosRoot}/${library.dir}") cfg.libraries.shared;
  logDir = "/var/lib/jellyfin/log";
in
{
  options.repo.jellyfin = {
    libraries = {
      video = lib.mkOption {
        type = lib.types.listOf libraryType;
        default = defaultVideoLibraries;
        description = "Default Jellyfin video library definitions.";
      };

      personal = lib.mkOption {
        type = lib.types.listOf libraryType;
        default = defaultVideoLibraries;
        description = "Jellyfin library definitions provisioned below each user's videos directory.";
      };

      shared = lib.mkOption {
        type = lib.types.listOf libraryType;
        default = defaultVideoLibraries;
        description = "Jellyfin library definitions provisioned below the shared videos directory.";
      };

      sharedMusic = lib.mkOption {
        type = lib.types.listOf libraryType;
        default = [ ];
        description = "Jellyfin music library definitions provisioned below the shared music directory.";
      };
    };

    paths = {
      sharedVideosRoot = lib.mkOption {
        type = lib.types.str;
        default = "${vars.sharedRoot}/_Videos";
        description = "Shared Jellyfin videos root.";
      };

      sharedMusicRoot = lib.mkOption {
        type = lib.types.str;
        default = "${vars.sharedRoot}/_Music";
        description = "Shared Jellyfin music root.";
      };
    };
  };

  config = {
    repo.storage.userRoots = {
      contentSubdirs = [ "_Videos" ];
      videoSubdirs = userVideoSubdirs;
      memberGroups = [
        "jellyfin-users"
      ];
      rootTraverseGroups = [
        "jellyfin-media"
      ];
      recursiveWritableGrants = [
        {
          group = "jellyfin-media";
          relativePaths = [ "_Videos" ];
        }
      ];
    };

    repo.storage.sharedRoots.contentSubdirs = [ "_Videos" ];

    systemd.tmpfiles.rules = [
      "d ${logDir} 0750 jellyfin jellyfin -"
    ];

    systemd.services.jellyfin-storage-layout-v1 = {
      description = "Provision Jellyfin storage layout";
      wantedBy = [ "multi-user.target" ];
      wants = [ "data-pool-layout.service" "local-fs.target" ];
      after = [ "data-pool-layout.service" "local-fs.target" ];
      before = [ "jellyfin.service" ];
      unitConfig.ConditionPathIsMountPoint = vars.dataRoot;
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

        install -d -m 1770 -o root -g root ${cfg.paths.sharedVideosRoot}
        for path in ${lib.escapeShellArgs sharedJellyfinDirs}; do
          install -d -m 1770 -o root -g root "$path"
        done

        grant_traverse_acl() {
          local group="$1"
          shift

          for path in "$@"; do
            [[ -d "$path" ]] || continue
            setfacl -m "g:$group:r-X" "$path"
          done
        }

        apply_recursive_acl() {
          local access_spec="$1"
          local default_spec="$2"
          shift
          shift

          for path in "$@"; do
            [[ -d "$path" ]] || continue
            setfacl -R -m "$access_spec" "$path"
            find "$path" -type d -exec setfacl -m "$default_spec" '{}' +
          done
        }

        grant_traverse_acl jellyfin-media ${lib.escapeShellArgs [ vars.sharedRoot cfg.paths.sharedVideosRoot ]}
        apply_recursive_acl "g:jellyfin-media:rwX" "d:g:jellyfin-media:rwx" ${lib.escapeShellArgs sharedJellyfinDirs}
      '';
    };

    systemd.services.jellyfin = {
      wants = [ "jellyfin-storage-layout-v1.service" ];
      after = [ "jellyfin-storage-layout-v1.service" ];
    };
  };
}
