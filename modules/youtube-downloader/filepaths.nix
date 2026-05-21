{ config, lib, vars, ... }:

let
  userVideoWritablePaths = map (name: "videos/${name}") vars.userVideoSubdirs;
in
{
  config = lib.mkMerge [
    {
      repo.apps."youtube-downloader".filepaths = {
        state = "/var/lib/youtube-downloader";
        cache = "/var/cache/youtube-downloader";
        runtime.temp = "/var/cache/youtube-downloader/tmp";
        sharedRoots.videos = vars.sharedYouTubeRoot;
        sharedRoots.audiobooks = "${vars.sharedAudiobooksRoot}/youtube";
        userRoots.personal = vars.usersRoot;
      };
    }
    (lib.mkIf config.nixhomeserver.apps."youtube-downloader".enable {
      repo.storage.userRoots.recursiveWritableGrants = [
        {
          group = "youtube-downloader";
          relativePaths = [
            "audiobooks"
            "videos"
          ] ++ userVideoWritablePaths;
        }
      ];
    })
  ];
}
