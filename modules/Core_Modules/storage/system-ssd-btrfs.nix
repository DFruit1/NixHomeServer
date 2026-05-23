{ config, lib, vars, ... }:

let
  systemDisk = "/dev/disk/by-id/${vars.mainDisk}";
  rootSubvolume =
    if config.repo.impermanence.enableRootRollback then
      config.repo.impermanence.rootSubvolume
    else
      "/";
  btrfsOptions = subvolume: [
    "subvol=${subvolume}"
    "compress=zstd"
    "noatime"
  ];
in
{
  fileSystems."/" = {
    device = lib.mkDefault "${systemDisk}-part2";
    fsType = lib.mkDefault "btrfs";
    options = btrfsOptions rootSubvolume;
  };

  fileSystems."/boot" = {
    device = lib.mkDefault "${systemDisk}-part1";
    fsType = lib.mkDefault "vfat";
  };

  fileSystems."/nix" = {
    device = lib.mkDefault "${systemDisk}-part2";
    fsType = lib.mkDefault "btrfs";
    options = btrfsOptions "/nix";
  };

  fileSystems."/persist" = {
    device = lib.mkDefault "${systemDisk}-part2";
    fsType = lib.mkDefault "btrfs";
    options = btrfsOptions "/persist";
    neededForBoot = true;
  };

  services.btrfs.autoScrub.enable = true;
}
