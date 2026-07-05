{ lib, vars, ... }:

let
  systemDisk = "/dev/disk/by-id/${vars.mainDisk}";
in
lib.mkIf (vars.storageProfile == "single-disk-ext4") {
  fileSystems."/" = {
    device = lib.mkDefault "${systemDisk}-part2";
    fsType = lib.mkDefault "ext4";
  };

  fileSystems."/boot" = {
    device = lib.mkDefault "${systemDisk}-part1";
    fsType = lib.mkDefault "vfat";
  };
}
