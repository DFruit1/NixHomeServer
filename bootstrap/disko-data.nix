{ lib, vars, ... }:

let
  storageValidation = import ../lib/storage-validation.nix { inherit lib; };
  dataPool = vars.zfsDataPool;
  dataDiskIds = vars.zfsDataPoolDiskIds;
  optionalDataMountOptions = [
    "defaults"
    "nofail"
  ];
  mirrorPairsValid = builtins.all
    (pair:
      builtins.isList pair
      && builtins.length pair == 2
      && builtins.all storageValidation.validDiskId pair)
    dataPool.mirrorPairs;
  uniqueDiskIds = lib.unique dataDiskIds;
  requiredDatasets = [ "users" "shared" "backups" ];
  datasetNamesSafe = builtins.all
    (dataset:
      builtins.isString dataset
      && builtins.match "[A-Za-z0-9][A-Za-z0-9._-]*" dataset != null
      && dataset != "."
      && dataset != "..")
    dataPool.datasets;
  datasetsValid =
    datasetNamesSafe
    && builtins.length (lib.unique dataPool.datasets) == builtins.length dataPool.datasets
    && lib.sort builtins.lessThan dataPool.datasets == lib.sort builtins.lessThan requiredDatasets;
  mountPointValid = builtins.match "/mnt/[A-Za-z0-9][A-Za-z0-9._-]*" dataPool.mountPoint != null;
  topologyValid =
    if dataPool.mirrorPairs == [ ] || !mirrorPairsValid then
      throw "Every storage.dataPool.mirrorPairs entry must contain exactly two non-placeholder /dev/disk/by-id basenames."
    else if builtins.length uniqueDiskIds != builtins.length dataDiskIds then
      throw "storage.dataPool.mirrorPairs must not repeat a disk ID."
    else if builtins.elem vars.mainDisk dataDiskIds then
      throw "storage.systemDisk must not also appear in storage.dataPool.mirrorPairs."
    else if !storageValidation.validZpoolName dataPool.name then
      throw "storage.dataPool.name must be a non-empty ZFS-compatible pool name."
    else if !mountPointValid then
      throw "storage.dataPool.mountPoint must be a normalized /mnt/<name> path with no trailing slash or traversal components."
    else if !datasetsValid then
      throw "storage.dataPool.datasets must contain exactly the unique canonical datasets: users, shared, and backups."
    else
      true;

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

  mkDataVdev = idx: _: {
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
lib.mkIf vars.enableZfsDataPool (assert topologyValid; {
  assertions = [
    {
      assertion = dataPool.mirrorPairs != [ ] && mirrorPairsValid;
      message = "Every storage.dataPool.mirrorPairs entry must contain exactly two non-placeholder /dev/disk/by-id basenames.";
    }
    {
      assertion = builtins.length uniqueDiskIds == builtins.length dataDiskIds;
      message = "storage.dataPool.mirrorPairs must not repeat a disk ID or use two aliases for the same configured ID.";
    }
    {
      assertion = !(builtins.elem vars.mainDisk dataDiskIds);
      message = "storage.systemDisk must not also appear in storage.dataPool.mirrorPairs.";
    }
    {
      assertion = storageValidation.validZpoolName dataPool.name;
      message = "storage.dataPool.name must be a non-empty ZFS-compatible pool name.";
    }
    {
      assertion = mountPointValid;
      message = "storage.dataPool.mountPoint must be a normalized /mnt/<name> path with no trailing slash or traversal components.";
    }
    {
      assertion = datasetsValid;
      message = "storage.dataPool.datasets must contain exactly the unique canonical datasets: users, shared, and backups.";
    }
  ];

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
})
