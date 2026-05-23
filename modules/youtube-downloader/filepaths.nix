{ lib, vars, ... }:

let
  userVideoWritablePaths = map (name: "videos/${name}") vars.userVideoSubdirs;
in
{
  config = {
    repo.storage.userRoots.recursiveWritableGrants = [
      {
        group = "youtube-downloader";
        relativePaths = [
          "audiobooks"
          "videos"
        ] ++ userVideoWritablePaths;
      }
    ];

    systemd.tmpfiles.rules = [
      "d /var/lib/youtube-downloader 0750 youtube-downloader youtube-downloader -"
      "d /var/lib/youtube-downloader/state 0750 youtube-downloader youtube-downloader -"
      "d /var/cache/youtube-downloader 0750 youtube-downloader youtube-downloader -"
      "d /var/cache/youtube-downloader/tmp 0750 youtube-downloader youtube-downloader -"
    ];
  };
}
