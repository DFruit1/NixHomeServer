{ vars, ... }:

{
  imports = [
    ./fileshare-user-roots.nix
    ./import-fix.nix
    ./layout.nix
    ./system-ssd-btrfs.nix
  ];

  boot.zfs.forceImportRoot = false;

  services.zfs.autoScrub = {
    enable = true;
    pools = [ vars.zfsDataPool.name ];
  };
}
