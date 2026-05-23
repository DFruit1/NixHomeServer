{ vars, ... }:

{
  imports = [
    ./fileshare-user-roots.nix
    ./import-fix.nix
    ./layout.nix
    ./system-ssd-btrfs.nix
  ];

  services.zfs.autoScrub = {
    enable = true;
    pools = [ vars.zfsDataPool.name ];
  };
}
