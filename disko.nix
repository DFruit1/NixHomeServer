{ lib, vars, ... }:

let
  dataMountPoint = idx: "/mnt/disk${toString (idx + 1)}";
  parityMountPoint = idx:
    if idx == 0 then
      "/mnt/parity"
    else
      "/mnt/parity${toString (idx + 1)}";

  mkDataDisk = idx: diskId:
    lib.nameValuePair "data${toString (idx + 1)}" {
      device = "/dev/disk/by-id/${diskId}";
      type = "disk";
      content.type = "gpt";
      content.partitions.data = {
        size = "100%";
        content = {
          type = "filesystem";
          format = "xfs";
          mountpoint = dataMountPoint idx;
        };
      };
    };

  mkParityDisk = idx: diskId:
    lib.nameValuePair
      (if idx == 0 then "parity" else "parity${toString (idx + 1)}")
      {
        device = "/dev/disk/by-id/${diskId}";
        type = "disk";
        content = {
          type = "gpt";
          partitions.parity = {
            size = "100%";
            content = {
              type = "filesystem";
              format = "xfs";
              mountpoint = parityMountPoint idx;
            };
          };
        };
      };
in
{
  disko.devices = {
    disk =
      {
        ##############################################################
        #  System SSD  (Btrfs)                                       #
        ##############################################################
        system = {
          device = "/dev/disk/by-id/${vars.mainDisk}";
          type = "disk";
          content = {
            type = "gpt";
            partitions = {

              boot = {
                size = "512M";
                type = "EF00";
                content = {
                  type = "filesystem";
                  format = "vfat";
                  mountpoint = "/boot";
                };
              };

              root = {
                size = "100%";
                content = {
                  type = "btrfs";
                  subvolumes = {
                    "/" = { mountpoint = "/"; mountOptions = [ "compress=zstd" "noatime" ]; };
                    "/nix" = { mountpoint = "/nix"; mountOptions = [ "compress=zstd" "noatime" ]; };
                    "/persist" = { mountpoint = "/persist"; mountOptions = [ "compress=zstd" "noatime" ]; };
                  };
                };
              };
            };
          };
        };

      }
      // lib.optionalAttrs (vars.enableBackupDisk && vars.backupDisk != null) {
        backup = {
          device = "/dev/disk/by-id/${vars.backupDisk}";
          type = "disk";
          content = {
            type = "gpt";
            partitions.backup = {
              size = "100%";
              content = {
                type = "filesystem";
                format = "xfs";
                mountpoint = vars.backupMountPoint;
                mountOptions = [ "nofail" ];
              };
            };
          };
        };
      }
      // builtins.listToAttrs (lib.imap0 mkParityDisk vars.parityDisks)
      // builtins.listToAttrs (lib.imap0 mkDataDisk vars.dataDisks);
  };
}
