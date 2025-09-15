{ config, impermanence, lib, vars, ... }:
{
  imports = [ impermanence.nixosModules.impermanence ];

  fileSystems."/persist" = lib.mkForce {
    device = "/dev/disk/by-id/${vars.mainDisk}";
    fsType = "btrfs";
    options = [ "subvol=persist" "compress=zstd" "noatime" ];
    neededForBoot = true;
  };

  environment.persistence."/persist" = {
    directories = [
      "/var/lib"
      "/var/log"
    ];
    files = [ "/etc/machine-id" ];
  };
}
