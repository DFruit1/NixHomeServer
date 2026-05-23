{ config, lib, pkgs, vars, ... }:

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

      systemd.tmpfiles.rules = [
        "d /run/upload-processor 0770 upload-processor upload-staging -"
        "d /run/upload-processor/queue 0770 upload-processor upload-staging -"
        "d /var/lib/upload-processor 0750 upload-processor upload-processor -"
        "d ${vars.uploadSecurity.stagingRoot} 0710 root upload-staging -"
        "d ${vars.uploadSecurity.quarantineRoot} 0770 upload-processor upload-review -"
      ];

      systemd.services.upload-processor-runtime-layout = {
        description = "Create upload processor runtime directories";
        wantedBy = [ "multi-user.target" ];
        before = [
          "copyparty.service"
          "upload-processor.service"
          "upload-processor-rescan.service"
        ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        path = with pkgs; [
          coreutils
          findutils
        ];
        script = ''
          set -euo pipefail
          install -d -m 0770 -o upload-processor -g upload-staging /run/upload-processor
          install -d -m 0770 -o upload-processor -g upload-staging /run/upload-processor/queue
          install -d -m 0770 -o upload-processor -g upload-review ${lib.escapeShellArg vars.uploadSecurity.quarantineRoot}
          chgrp -R upload-review ${lib.escapeShellArg vars.uploadSecurity.quarantineRoot}
          find ${lib.escapeShellArg vars.uploadSecurity.quarantineRoot} -type d -exec chmod 0770 '{}' +
          find ${lib.escapeShellArg vars.uploadSecurity.quarantineRoot} -type f -exec chmod 0640 '{}' +
        '';
      };
    })
  ];
}
