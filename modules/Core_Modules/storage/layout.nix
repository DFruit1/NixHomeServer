{ config, lib, pkgs, vars, ... }:

let
  cfg = config.repo.storage.dataPool;
  zpoolBin = "${config.boot.zfs.package}/sbin/zpool";
  zfsBin = "${pkgs.zfs}/bin/zfs";
  canonicalUsersDataset = "${vars.zfsDataPool.name}/users";
  canonicalSharedDataset = "${vars.zfsDataPool.name}/shared";

  mkDirCmd =
    { path
    , mode
    , user
    , group
    ,
    }:
    "${pkgs.coreutils}/bin/install -d -m ${mode} -o ${user} -g ${group} '${path}'";

  coreContentDirs = [
    {
      path = vars.dataRoot;
      mode = "0755";
      user = "root";
      group = "root";
    }
    {
      path = vars.usersRoot;
      mode = "0755";
      user = "root";
      group = "root";
    }
    {
      path = vars.sharedRoot;
      mode = "2775";
      user = "root";
      group = "users";
    }
  ];

  coreDatasetSpecs = [
    {
      dataset = canonicalUsersDataset;
      mountpoint = vars.usersRoot;
      properties = {
        compression = "zstd";
        atime = "off";
        acltype = "posixacl";
        xattr = "sa";
        recordsize = "1M";
      };
    }
    {
      dataset = canonicalSharedDataset;
      mountpoint = vars.sharedRoot;
      properties = {
        compression = "zstd";
        atime = "off";
        acltype = "posixacl";
        xattr = "sa";
        recordsize = "1M";
      };
    }
  ];

  mkDatasetEnsure = spec:
    let
      propertyCommands = lib.concatStringsSep "\n"
        (lib.mapAttrsToList
          (property: value: "set_zfs_property '${spec.dataset}' '${property}' '${value}'")
          spec.properties);
    in
    ''
      ensure_dataset '${spec.dataset}' '${spec.mountpoint}'
      ${propertyCommands}
    '';

  zfsContentLayoutScript = builtins.concatStringsSep "\n" (map mkDirCmd cfg.directories);
  zfsDatasetLayoutScript = builtins.concatStringsSep "\n" (map mkDatasetEnsure cfg.datasets);

  datasetNames = map (spec: spec.dataset) cfg.datasets;
in
{
  options.repo.storage.dataPool = {
    directories = lib.mkOption {
      type = lib.types.listOf (lib.types.submodule {
        options = {
          path = lib.mkOption { type = lib.types.str; };
          mode = lib.mkOption { type = lib.types.str; };
          user = lib.mkOption { type = lib.types.str; };
          group = lib.mkOption { type = lib.types.str; };
        };
      });
      default = [ ];
      description = "Data-pool-backed directories to provision.";
    };

    datasets = lib.mkOption {
      type = lib.types.listOf (lib.types.submodule {
        options = {
          dataset = lib.mkOption { type = lib.types.str; };
          mountpoint = lib.mkOption { type = lib.types.str; };
          properties = lib.mkOption {
            type = lib.types.attrsOf lib.types.str;
            default = { };
          };
        };
      });
      default = [ ];
      description = "ZFS datasets to create or reconcile for the data pool.";
    };
  };

  options.repo.storage.sharedRoots = {
    contentSubdirs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = vars.sharedContentSubdirs or [ ];
      description = "Top-level shared content directories contributed by enabled modules.";
    };
  };

  config = {
    assertions = [
      {
        assertion = builtins.length datasetNames == builtins.length (lib.unique datasetNames);
        message = "repo.storage.dataPool.datasets contains duplicate dataset names.";
      }
    ];

    repo.storage.dataPool = {
      directories = coreContentDirs;
      datasets = coreDatasetSpecs;
    };

  systemd.tmpfiles.rules = [
    "d /persist/appdata 0755 root root -"
  ];

  systemd.services.data-pool-layout = {
    description = "Provision data-pool-backed content layout";
    wantedBy = [ "local-fs.target" ];
    wants = [ "systemd-udev-settle.service" ];
    after = [ "systemd-modules-load.service" "systemd-udev-settle.service" ];
    before = [ "local-fs.target" ];
    unitConfig.DefaultDependencies = false;
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
      script = ''
        set -euo pipefail
        ZFS_FORCE=""

        for option in $(cat /proc/cmdline); do
          case "$option" in
            zfs_force|zfs_force=1|zfs_force=y)
              ZFS_FORCE="-f"
              ;;
          esac
        done

        if ! ${zpoolBin} list '${vars.zfsDataPool.name}' >/dev/null 2>&1; then
          # shellcheck disable=SC2086
          ${zpoolBin} import -d /dev/disk/by-id -N $ZFS_FORCE '${vars.zfsDataPool.name}'
        fi

        ensure_dataset() {
          local dataset="$1"
          local mountpoint="$2"

        if ! ${zfsBin} list -H -o name "$dataset" >/dev/null 2>&1; then
          ${zfsBin} create -o mountpoint="$mountpoint" "$dataset"
        else
          set_zfs_property "$dataset" canmount on
          set_zfs_property "$dataset" mountpoint "$mountpoint"
          ${zfsBin} mount "$dataset" >/dev/null 2>&1 || true
        fi
      }

      set_zfs_property() {
        local dataset="$1"
        local property="$2"
        local value="$3"
        local current

        current="$(${zfsBin} get -H -o value "$property" "$dataset")"
        if [[ "$current" != "$value" ]]; then
          ${zfsBin} set "$property=$value" "$dataset"
        fi
      }

      set_zfs_property '${vars.zfsDataPool.name}' canmount on
      set_zfs_property '${vars.zfsDataPool.name}' mountpoint '${vars.dataRoot}'
      ${zfsBin} mount '${vars.zfsDataPool.name}' >/dev/null 2>&1 || true
      ${pkgs.util-linux}/bin/mountpoint -q '${vars.dataRoot}'

      ${zfsDatasetLayoutScript}
      ${zfsContentLayoutScript}
    '';
  };
  };
}
