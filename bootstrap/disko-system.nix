{ config, vars, ... }:

let
  rootSubvolume =
    if config.repo.impermanence.enableRootRollback then
      config.repo.impermanence.rootSubvolume
    else
      "/";
  rootContent =
    if vars.storageProfile == "single-disk-ext4" then
      {
        type = "filesystem";
        format = "ext4";
        mountpoint = "/";
      }
    else
      {
        type = "btrfs";
        subvolumes = {
          ${rootSubvolume} = {
            mountpoint = "/";
            mountOptions = [ "compress=zstd" "noatime" ];
          };
          "/nix" = {
            mountpoint = "/nix";
            mountOptions = [ "compress=zstd" "noatime" ];
          };
          "/persist" = {
            mountpoint = "/persist";
            mountOptions = [ "compress=zstd" "noatime" ];
          };
        };
      };
in

{
  assertions = [
    {
      assertion = builtins.elem vars.storageProfile [ "zfs-mirror" "single-disk-ext4" ];
      message = "Unsupported storage.profile '${vars.storageProfile}' for disko-system.nix.";
    }
  ];

  disko.devices = {
    disk = {
      ##############################################################
      #  System disk                                                #
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
              content = rootContent;
            };
          };
        };
      };
    };
  };
}
