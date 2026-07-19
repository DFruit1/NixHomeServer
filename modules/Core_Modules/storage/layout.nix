{ config, lib, pkgs, vars, ... }:

let
  cfg = config.repo.storage.dataPool;
  zpoolBin = "${config.boot.zfs.package}/sbin/zpool";
  zfsBin = "${pkgs.zfs}/bin/zfs";
  canonicalUsersDataset = "${vars.zfsDataPool.name}/users";
  canonicalSharedDataset = "${vars.zfsDataPool.name}/shared";
  canonicalBackupsDataset = "${vars.zfsDataPool.name}/backups";
  backupRoot = vars.backupRoot or "${vars.dataRoot}/backups";
  backupStorageAccessGroup = vars.backupAccess.storageGroup or "backup-admin";
  backupStorageAccessGid = vars.fileAccessPosixGids.${backupStorageAccessGroup};
  sharedContentDirs = map
    (name: {
      path = "${vars.sharedRoot}/${name}";
      mode = "1770";
      user = "root";
      group = "root";
    })
    config.repo.storage.sharedRoots.contentSubdirs;
  sharedVideoDirs = map
    (name: {
      path = "${vars.sharedRoot}/_Videos/${name}";
      mode = "1770";
      user = "root";
      group = "root";
    })
    config.repo.storage.sharedRoots.videoSubdirs;

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
      mode = "1770";
      user = "root";
      group = "root";
    }
    {
      path = backupRoot;
      mode = "0750";
      user = "root";
      group = toString backupStorageAccessGid;
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
        "com.sun:auto-snapshot" = "true";
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
        "com.sun:auto-snapshot" = "true";
      };
    }
    {
      dataset = canonicalBackupsDataset;
      mountpoint = backupRoot;
      properties = {
        compression = "zstd";
        atime = "off";
        acltype = "posixacl";
        xattr = "sa";
        recordsize = "1M";
        primarycache = "metadata";
        "com.sun:auto-snapshot" = "false";
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

  directoryCommands = builtins.concatStringsSep "\n" (map mkDirCmd cfg.directories);
  zfsDatasetCommands = builtins.concatStringsSep "\n" (map mkDatasetEnsure cfg.datasets);
  directoryLayoutScript = ''
    set -euo pipefail
    ${directoryCommands}
  '';
  zfsLayoutScript = ''
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

    refuse_nonempty_mountpoint() {
      local mountpoint="$1"

      if ! ${pkgs.util-linux}/bin/mountpoint -q "$mountpoint" \
        && [[ -d "$mountpoint" ]] \
        && [[ -n "$(${pkgs.findutils}/bin/find "$mountpoint" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
        echo "Refusing to hide existing files beneath unmounted data-pool path $mountpoint" >&2
        exit 1
      fi
    }

    ensure_dataset() {
      local dataset="$1"
      local mountpoint="$2"

      refuse_nonempty_mountpoint "$mountpoint"

      if ! ${zfsBin} list -H -o name "$dataset" >/dev/null 2>&1; then
        ${zfsBin} create -o mountpoint="$mountpoint" "$dataset"
      else
        set_zfs_property "$dataset" canmount on
        set_zfs_property "$dataset" mountpoint "$mountpoint"
        ${zfsBin} mount "$dataset" >/dev/null 2>&1 || true
      fi

      if [[ "$(${zfsBin} get -H -o value mounted "$dataset")" != yes ]] \
        || ! ${pkgs.util-linux}/bin/mountpoint -q "$mountpoint"; then
        echo "Required ZFS dataset $dataset is not mounted at $mountpoint" >&2
        exit 1
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

    refuse_nonempty_mountpoint '${vars.dataRoot}'
    set_zfs_property '${vars.zfsDataPool.name}' canmount on
    set_zfs_property '${vars.zfsDataPool.name}' mountpoint '${vars.dataRoot}'
    set_zfs_property '${vars.zfsDataPool.name}' 'com.sun:auto-snapshot' true
    ${zfsBin} mount '${vars.zfsDataPool.name}' >/dev/null 2>&1 || true
    if [[ "$(${zfsBin} get -H -o value mounted '${vars.zfsDataPool.name}')" != yes ]] \
      || ! ${pkgs.util-linux}/bin/mountpoint -q '${vars.dataRoot}'; then
      echo "Required ZFS pool ${vars.zfsDataPool.name} is not mounted at ${vars.dataRoot}" >&2
      exit 1
    fi

    ${zfsDatasetCommands}
    if ${zfsBin} list -H -o name '${vars.zfsDataPool.name}/upload-staging' >/dev/null 2>&1; then
      set_zfs_property '${vars.zfsDataPool.name}/upload-staging' 'com.sun:auto-snapshot' false
    fi
    ${directoryCommands}
  '';

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

    videoSubdirs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Video subdirectories to create under the shared videos directory.";
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
      directories = coreContentDirs ++ sharedContentDirs ++ sharedVideoDirs;
      datasets = lib.mkIf vars.enableZfsDataPool coreDatasetSpecs;
    };

    systemd.tmpfiles.rules = [
      "d /persist 0755 root root -"
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
        TimeoutStartSec = "10min";
      };
      script = if vars.enableZfsDataPool then zfsLayoutScript else directoryLayoutScript;
    };
  };
}
