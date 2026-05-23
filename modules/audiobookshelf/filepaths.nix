{ config, lib, pkgs, vars, ... }:

{
  config = lib.mkMerge [
    {
      repo.apps.audiobookshelf.filepaths = {
        state = "/var/lib/audiobookshelf";
        sharedRoots.audiobooks = vars.sharedAudiobooksRoot;
        sharedRoots.youtube = "${vars.sharedAudiobooksRoot}/youtube";
        userRoots.personal = vars.usersRoot;
      };
    }
    (lib.mkIf config.nixhomeserver.apps.audiobookshelf.enable {
      repo.storage.userRoots = {
        rootWritableGroups = [
          "audiobookshelf-media"
        ];
        recursiveWritableGrants = [
          {
            group = "audiobookshelf-media";
            relativePaths = [ "audiobooks" ];
          }
        ];
      };

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

          install -d -m 2775 -o root -g users ${vars.sharedAudiobooksRoot}
          install -d -m 2775 -o root -g users ${vars.sharedAudiobooksRoot}/youtube

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

          apply_recursive_acl "g:audiobookshelf-media:rwX" "d:g:audiobookshelf-media:rwx" ${vars.sharedAudiobooksRoot}
        '';
      };

      systemd.services.audiobookshelf = {
        wants = [ "audiobookshelf-storage-layout-v1.service" ];
        after = [ "audiobookshelf-storage-layout-v1.service" ];
      };
    })
  ];
}
