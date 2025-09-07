{
  disko.devices = {
    disk = {
      ##############################################################
      #  System SSD  (Btrfs)                                       #
      ##############################################################
      system = {
        device = "/dev/disk/by-id/ata-SK_hynix_SC401_SATA_256GB_EI89QSTDS10309C9E";
        type   = "disk";
        content = {
          type = "gpt";
          partitions = {

            boot = {
              size = "512M";
              type = "EF00";
              content = {
                type   = "filesystem";
                format = "vfat";
                mountpoint = "/boot";
              };
            };

            root = {
              size = "100%";
              content = {
                type = "btrfs";
                subvolumes = {
                  "/"        = { mountpoint = "/";       mountOptions = [ "compress=zstd" "noatime" ]; };
                  "/nix"     = { mountpoint = "/nix";    mountOptions = [ "compress=zstd" "noatime" ]; };
                  "/persist" = { mountpoint = "/persist";mountOptions = [ "compress=zstd" "noatime" ]; };
                };
              };
            };
          };
        };
      };

      ##############################################################
      #  Data drives 1-5  (XFS)                                    #
      ##############################################################
      data1 = {
        device = "/dev/disk/by-id/ata-HGST_HUS726T4TALA6L4_V6G7R6MS";
        type   = "disk";
        content = {
          type = "gpt";
          partitions.data = {
            size = "100%";
            content = { type = "filesystem"; format = "xfs"; mountpoint = "/mnt/disk1"; };
          };
        };
      };

      data2 = {
        device = "/dev/disk/by-id/ata-HGST_HUS726T4TALA6L4_V1JAKPNH";
        type   = "disk";
        content.type = "gpt";
        content.partitions.data = {
          size = "100%";
          content = { type = "filesystem"; format = "xfs"; mountpoint = "/mnt/disk2"; };
        };
      };

      data3 = {
        device = "/dev/disk/by-id/ata-HGST_HUS726T4TALA6L4_V1J9PKDH";
        type   = "disk";
        content.type = "gpt";
        content.partitions.data = {
          size = "100%";
          content = { type = "filesystem"; format = "xfs"; mountpoint = "/mnt/disk3"; };
        };
      };

      data4 = {
        device = "/dev/disk/by-id/ata-HGST_HUS726T4TALA6L4_V1JAN8PH";
        type   = "disk";
        content.type = "gpt";
        content.partitions.data = {
          size = "100%";
          content = { type = "filesystem"; format = "xfs"; mountpoint = "/mnt/disk4"; };
        };
      };

      data5 = {
        device = "/dev/disk/by-id/ata-HGST_HUS726T4TALA6L4_V1G5K8YC";
        type   = "disk";
        content.type = "gpt";
        content.partitions.data = {
          size = "100%";
          content = { type = "filesystem"; format = "xfs"; mountpoint = "/mnt/disk5"; };
        };
      };

      ##############################################################
      #  Parity drive  (XFS)                                       #
      ##############################################################
      parity = {
        device = "/dev/disk/by-id/ata-HGST_HUS726040ALA610_K7G5W29L";
        type   = "disk";
        content = {
          type = "gpt";
          partitions.parity = {
            size = "100%";
            content = { type = "filesystem"; format = "xfs"; mountpoint = "/mnt/parity"; };
          };
        };
      };
    };
  };
}
