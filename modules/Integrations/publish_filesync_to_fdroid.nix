{ config, lib, options, ... }:

let
  apkPath = "${config.repo.fdroid.paths.stateDir}/incoming/filesync.apk";
  incomingDir = builtins.dirOf apkPath;
in
{
  config = lib.optionalAttrs
    (lib.hasAttrByPath [ "repo" "fdroid" "paths" "stateDir" ] options
      && lib.hasAttrByPath [ "repo" "ipfs" "enable" ] options)
    (lib.mkIf config.repo.ipfs.enable {
      systemd.tmpfiles.rules = [ "d ${incomingDir} 0775 root fdroidserver -" ];

      systemd.services.fdroid-filesync-publish = {
        description = "Publish the File Sync Android APK to F-Droid and IPFS";
        wantedBy = [ "multi-user.target" ];
        after = [ "fdroid-repository-init.service" ];
        requires = [ "fdroid-repository-init.service" ];
        unitConfig.ConditionPathExists = apkPath;
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${config.repo.fdroid.publisher} org.nixhomeserver.filesync ${apkPath}";
        };
      };

      systemd.paths.fdroid-filesync-publish = {
        wantedBy = [ "multi-user.target" ];
        pathConfig = {
          PathChanged = apkPath;
          Unit = "fdroid-filesync-publish.service";
        };
      };
    });
}
