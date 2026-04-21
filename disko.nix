{ lib, vars, ... }:

let
  dataPool = vars.zfsDataPool;
  dataDiskIds = vars.zfsDataPoolDiskIds;
  optionalDataMountOptions = [
    "defaults"
    "nofail"
  ];

  mkDataDisk = idx: diskId:
    lib.nameValuePair "data${toString (idx + 1)}" {
      device = "/dev/disk/by-id/${diskId}";
      type = "disk";
      content = {
        type = "gpt";
        partitions.zfs = {
          size = "100%";
          content = {
            type = "zfs";
            pool = dataPool.name;
          };
        };
      };
    };

  mkDataVdev = idx: members: {
    mode = "mirror";
    members = map (memberIdx: "data${toString memberIdx}") [
      ((idx * 2) + 1)
      ((idx * 2) + 2)
    ];
  };

  mkDataset = dataset:
    lib.nameValuePair dataset {
      type = "zfs_fs";
      mountpoint = "${dataPool.mountPoint}/${dataset}";
      mountOptions = optionalDataMountOptions;
    };

in
{
  disko.devices = {
    disk = builtins.listToAttrs (lib.imap0 mkDataDisk dataDiskIds);

    zpool = {
      ${dataPool.name} = {
        type = "zpool";
        mode = {
          topology = {
            type = "topology";
            vdev = lib.imap0 mkDataVdev dataPool.mirrorPairs;
          };
        };
        mountpoint = dataPool.mountPoint;
        mountOptions = optionalDataMountOptions;
        rootFsOptions = {
          acltype = "posixacl";
          atime = "off";
          compression = "zstd";
          xattr = "sa";
        };
        datasets = builtins.listToAttrs (map mkDataset dataPool.datasets);
      };
    };
  };
}
