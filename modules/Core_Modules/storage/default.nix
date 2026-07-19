{ lib, vars, ... }:

{
  imports = [
    ./fileshare-user-roots.nix
    ./import-fix.nix
    ./layout.nix
    ./system-ssd-btrfs.nix
    ./system-ssd-ext4.nix
  ];

  services.zfs.autoScrub = lib.mkIf vars.enableZfsDataPool {
    enable = true;
    pools = [ vars.zfsDataPool.name ];
  };

  services.zfs.trim.enable = lib.mkForce false;

  services.zfs.autoSnapshot = lib.mkIf vars.enableZfsDataPool {
    enable = true;
    frequent = 0;
    hourly = 24;
    daily = 7;
    weekly = 4;
    monthly = 0;
  };

  systemd.services = lib.mkIf vars.enableZfsDataPool (lib.genAttrs [
    "zfs-scrub"
    "zfs-snapshot-daily"
    "zfs-snapshot-frequent"
    "zfs-snapshot-hourly"
    "zfs-snapshot-monthly"
    "zfs-snapshot-weekly"
  ] (_: {
    requires = [ "data-pool-layout.service" ];
    after = [ "data-pool-layout.service" ];
  }));
}
