{ lib, vars, ... }:

let
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
          mountpoint = "/mnt/disk${toString (idx + 1)}";
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
      #  Parity drive  (XFS)                                       #
      ##############################################################
      parity = {
        device = "/dev/disk/by-id/${vars.parityDisk}";
        type   = "disk";
        content = {
          type = "gpt";
          partitions.parity = {
            size = "100%";
            content = { type = "filesystem"; format = "xfs"; mountpoint = "/mnt/parity"; };
          };
        };
      };
    }
      // builtins.listToAttrs (lib.imap0 mkDataDisk vars.dataDisks);
  };
}
