{ config, lib, pkgs, vars, ... }:

let
  monitoredPoolDisks = vars.monitoredDataDiskIds;
  monitoredColdDisks = vars.monitoredColdStorageDiskIds;

  smartDevices =
    map
      (diskId: {
        device = "/dev/disk/by-id/${diskId}";
        options = "-d removable";
      })
      (monitoredPoolDisks ++ monitoredColdDisks);
in
{
  environment.systemPackages = [
    config.boot.zfs.package
    pkgs.smartmontools
  ];

  services.smartd = {
    enable = true;
    autodetect = false;
    devices = smartDevices;
  };
}
