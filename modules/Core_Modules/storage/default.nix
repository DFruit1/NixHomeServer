{ lib, vars, ... }:

{
  imports = [
    ./fileshare-user-roots.nix
    ./import-fix.nix
    ./layout.nix
    ./system-ssd-btrfs.nix
    ./system-ssd-ext4.nix
  ];

  boot.zfs.forceImportRoot = vars.enableZfsDataPool;

  services.zfs.autoScrub = lib.mkIf vars.enableZfsDataPool {
    enable = true;
    pools = [ vars.zfsDataPool.name ];
  };
}
