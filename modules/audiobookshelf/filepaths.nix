{ config, lib, pkgs, vars, ... }:

let
  sharedAudiobooksRoot = config.repo.audiobookshelf.paths.sharedAudiobooksRoot;
in
{
  options.repo.audiobookshelf.paths.sharedAudiobooksRoot = lib.mkOption {
    type = lib.types.str;
    default = "${vars.sharedRoot}/_Audiobooks";
    description = "Shared Audiobookshelf media root.";
  };

  config = {
    repo.storage.userRoots = {
      contentSubdirs = [ "_Audiobooks" ];
      rootWritableGroups = [
        "audiobookshelf-media"
      ];
      recursiveWritableGrants = [
        {
          group = "audiobookshelf-media";
          relativePaths = [ "_Audiobooks" ];
        }
      ];
    };

    repo.storage.sharedRoots.contentSubdirs = [ "_Audiobooks" ];

    systemd.services.audiobookshelf-storage-layout-v1 = {
      description = "Provision Audiobookshelf storage layout";
      wantedBy = [ "multi-user.target" ];
      wants = [ "data-pool-layout.service" "local-fs.target" ];
      after = [ "data-pool-layout.service" "local-fs.target" ];
      before = [ "audiobookshelf.service" ];
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

        install -d -m 1770 -o root -g root ${sharedAudiobooksRoot}
        install -d -m 1770 -o root -g root ${sharedAudiobooksRoot}/_YouTube
        setfacl -m g:audiobookshelf-media:r-X ${vars.sharedRoot}

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

        apply_recursive_acl "g:audiobookshelf-media:rwX" "d:g:audiobookshelf-media:rwx" ${sharedAudiobooksRoot}
      '';
    };

    systemd.services.audiobookshelf = {
      wants = [ "audiobookshelf-storage-layout-v1.service" ];
      after = [ "audiobookshelf-storage-layout-v1.service" ];
    };
  };
}
