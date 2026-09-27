{ config, lib, options, ... }:

let
  apkPath = config.repo.youtubeDownloader.paths.appDir + "/youtube-downloader.apk";
in
{
  config = lib.optionalAttrs
    (lib.hasAttrByPath [ "repo" "fdroid" ] options && lib.hasAttrByPath [ "repo" "youtubeDownloader" ] options)
    {
      systemd.services.fdroid-youtube-downloader-publish = {
        description = "Publish the current YouTube Downloader Android APK to F-Droid";
        wantedBy = [ "multi-user.target" ];
        after = [ "fdroid-repository-init.service" "fdroid-reindex.service" "youtube-downloader.service" ];
        requires = [ "fdroid-repository-init.service" "fdroid-reindex.service" ];
        unitConfig.ConditionPathExists = apkPath;
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${config.repo.fdroid.publisher} org.sydneybasiniot.youtubedownloader ${apkPath}";
        };
      };

      systemd.paths.fdroid-youtube-downloader-publish = {
        wantedBy = [ "multi-user.target" ];
        pathConfig = {
          PathChanged = apkPath;
          Unit = "fdroid-youtube-downloader-publish.service";
        };
      };
    };
}
