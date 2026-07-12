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
    repo.storage.sharedRoots.videoSubdirs = userVideoSubdirs;

    systemd.tmpfiles.rules = [
      "d ${logDir} 0750 jellyfin jellyfin -"
    ];

    systemd.services.media-folder-layout-v2 = {
      description = "Migrate media video folder layout to Movies, Shows, YouTube, and Other";
      wantedBy = [ "multi-user.target" ];
      wants = [ "data-pool-layout.service" "local-fs.target" ];
      after = [ "data-pool-layout.service" "local-fs.target" ];
      before = [
        "fileshare-user-root-sync.service"
        "jellyfin-storage-layout-v1.service"
        "jellyfin-library-bootstrap-v1.service"
        "youtube-downloader.service"
      ];
      unitConfig = lib.mkIf vars.dataRootIsMountPoint {
        ConditionPathIsMountPoint = vars.dataRoot;
      };
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      path = [
        pkgs.coreutils
        pkgs.findutils
      ];
      script = ''
        set -euo pipefail

        timestamp="$(date -u +%Y%m%dT%H%M%SZ)"

        move_children() {
          local source="$1"
          local destination="$2"
          local collision_label="$3"
          local item
          local base
          local collision_root

          [[ -d "$source" ]] || return 0
          install -d -m 1770 -o root -g root "$destination"

          while IFS= read -r -d "" item; do
            base="$(basename "$item")"
            if [[ -e "$destination/$base" ]]; then
              collision_root="$destination/.migrated-from-$collision_label/$timestamp"
              install -d -m 1770 -o root -g root "$collision_root"
              mv "$item" "$collision_root/$base"
            else
              mv "$item" "$destination/"
            fi
          done < <(find "$source" -mindepth 1 -maxdepth 1 -print0)

          rmdir --ignore-fail-on-non-empty "$source" || true
        }

        migrate_video_root() {
          local videos_root="$1"
          [[ -d "$videos_root" ]] || return 0

          install -d -m 1770 -o root -g root "$videos_root/_Other"
          move_children "$videos_root/_Home" "$videos_root/_Other" "_Home"
        }

        migrate_video_root ${lib.escapeShellArg cfg.paths.sharedVideosRoot}

        if [[ -d ${lib.escapeShellArg vars.usersRoot} ]]; then
          while IFS= read -r -d "" videos_root; do
            migrate_video_root "$videos_root"
          done < <(find ${lib.escapeShellArg vars.usersRoot} -mindepth 2 -maxdepth 2 -type d -name _Videos -print0)
        fi
      '';
    };

    systemd.services.jellyfin-storage-layout-v1 = {
      description = "Provision Jellyfin storage layout";
      wantedBy = [ "multi-user.target" ];
      wants = [ "data-pool-layout.service" "local-fs.target" "media-folder-layout-v2.service" ];
      after = [ "data-pool-layout.service" "local-fs.target" "media-folder-layout-v2.service" ];
      before = [ "jellyfin.service" ];
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

        grant_traverse_acl jellyfin-media ${lib.escapeShellArgs [ vars.sharedRoot cfg.paths.sharedVideosRoot ]}
        for path in ${lib.escapeShellArgs sharedJellyfinDirs}; do
          setfacl -m g:jellyfin-media:rwx,d:g:jellyfin-media:rwx "$path"
        done
      '';
    };

    systemd.services.jellyfin = {
      wants = [ "media-folder-layout-v2.service" "jellyfin-storage-layout-v1.service" ];
      after = [ "media-folder-layout-v2.service" "jellyfin-storage-layout-v1.service" ];
    };
  };
}
