{ config, lib, vars, ... }:

{
  config = lib.mkMerge [
    {
      repo.apps.copyparty.filepaths = {
        state = "/var/lib/copyparty";
        data = vars.uploadSecurity.stagingRoot;
        mediaRoots.staging = vars.uploadSecurity.stagingRoot;
        mediaRoots.quarantine = vars.uploadSecurity.quarantineRoot;
        userRoots.staging = vars.uploadSecurity.stagingRoot;
      };
    }
    (lib.mkIf config.nixhomeserver.apps.copyparty.enable {
      repo.storage.dataPool = {
        directories = [
          {
            path = vars.uploadSecurity.stagingRoot;
            mode = "0710";
            user = "root";
            group = "upload-staging";
          }
          {
            path = vars.uploadSecurity.quarantineRoot;
            mode = "0750";
            user = "upload-processor";
            group = "upload-review";
          }
        ];
        datasets = [
          {
            dataset = "${vars.zfsDataPool.name}/upload-staging";
            mountpoint = vars.uploadSecurity.stagingRoot;
            properties = {
              compression = "zstd";
              atime = "off";
              exec = "off";
              devices = "off";
              setuid = "off";
            };
          }
        ];
      };

      repo.storage.userRoots = {
        memberGroups = [
          "user-files"
        ];
        perUserDirectories = [
          {
            root = vars.uploadSecurity.stagingRoot;
            relativePath = "";
            mode = "0730";
            user = "root";
            group = "upload-staging";
          }
        ];
      };

      systemd.services.fileshare-user-root-sync.before = [
        "copyparty.service"
      ];
    })
  ];
}
