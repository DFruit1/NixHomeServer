{lib, vars, ...}:

lib.mkMerge [
  ###############################################################
  # -- system drive (btrfs) -------------------------------------
  ###############################################################
  {
    disk.system = {
      device = "/dev/disk/by-id/${vars.mainDisk}";
      type   = "disk";
      content = {
        type = "gpt";
        partitions = {
          boot = {
            size = "512m";
            type = "ef00";
            content = {
              type   = "filesystem";
              format = "vfat";
              mountpoint = "/boot";
            };
          };
          root = {
            size = "100%";
            content = {
              type = "btrfs";
              subvolumes = {
                "@"        = { mountpoint = "/";       mountoptions = [ "compress=zstd" "noatime" ]; };
                "@nix"     = { mountpoint = "/nix";    mountoptions = [ "compress=zstd" "noatime" ]; };
                "@persist" = { mountpoint = "/persist";mountoptions = [ "compress=zstd" "noatime" ]; };
              };
            };
          };
        };
      };
    };
  }

  ###############################################################
  # -- data drives (xfs) ----------------------------------------
  ###############################################################
  (lib.mkMerge (lib.imap0
    (idx: id:
      let n = builtins.tostring (idx + 1); in
      {
        disk."data${n}" = {
          device = "/dev/disk/by-id/${id}";
          type   = "disk";
          content = {
            type = "gpt";
            partitions.data = {
              size    = "100%";
              content = {
                type       = "filesystem";
                format     = "xfs";
                mountpoint = "/mnt/disk${n}";
              };
            };
          };
        };
      })
    vars.dataDisks))

  ###############################################################
  # -- parity drive (xfs) ---------------------------------------
  ###############################################################
  {
    disk.parity = {
      device = "/dev/disk/by-id/${vars.parityDisk}";
      type   = "disk";
      content = {
        type = "gpt";
        partitions.parity = {
          size = "100%";
          content = {
            type       = "filesystem";
            format     = "xfs";
            mountpoint = "/mnt/parity";
          };
        };
      };
    };
  }
]
