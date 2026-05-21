{ config, lib, vars, ... }:

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
    })
  ];
}
