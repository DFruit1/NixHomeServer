{ config, lib, pkgs, vars, ... }:

let
  cfg = config.repo.storage.dataPool;
  zpoolBin = "${config.boot.zfs.package}/sbin/zpool";
  zfsBin = "${pkgs.zfs}/bin/zfs";
  storageValidation = import ../../../lib/storage-validation.nix { inherit lib; };
  expectedPoolGuidRaw = vars.zfsDataPool.expectedGuid or null;
  expectedPoolGuid =
    if builtins.isString expectedPoolGuidRaw && storageValidation.validZpoolGuid expectedPoolGuidRaw
    then expectedPoolGuidRaw
    else null;
  poolImportIdentifier = if expectedPoolGuid == null then vars.zfsDataPool.name else expectedPoolGuid;
  poolIdentityVerifier = pkgs.writeShellScript "verify-zfs-pool-identity"
    (builtins.readFile ../../../scripts/helpers/verify-zfs-pool-identity.sh);
  poolIdentityVerifierArgs = lib.escapeShellArgs (
    [ "--pool" vars.zfsDataPool.name ]
    ++ lib.optionals (expectedPoolGuid != null) [ "--expected-guid" expectedPoolGuid ]
    ++ lib.concatMap
      (diskId: [ "--expected-device" "/dev/disk/by-id/${diskId}" ])
      vars.zfsDataPoolDiskIds
  );
  canonicalUsersDataset = "${vars.zfsDataPool.name}/users";
  canonicalSharedDataset = "${vars.zfsDataPool.name}/shared";
  canonicalBackupsDataset = "${vars.zfsDataPool.name}/backups";
  backupRoot = vars.backupRoot or "${vars.dataRoot}/backups";
  backupStorageAccessGroup = vars.backupStorageGroup;
  backupStorageAccessGid = vars.fileAccessPosixGids.${backupStorageAccessGroup};
  invalidSharedContentNames = lib.filter
    (name: !storageValidation.validPathComponent name)
    config.repo.storage.sharedRoots.contentSubdirs;
  invalidSharedVideoNames = lib.filter
    (name: !storageValidation.validPathComponent name)
    config.repo.storage.sharedRoots.videoSubdirs;
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
      ${zpoolBin} import -d /dev/disk/by-id -N $ZFS_FORCE ${lib.escapeShellArg poolImportIdentifier}
    fi

    ZFS_POOL_IDENTITY_ZPOOL_BIN=${lib.escapeShellArg zpoolBin} \
      ZFS_POOL_IDENTITY_AWK_BIN=${lib.escapeShellArg "${pkgs.gawk}/bin/awk"} \
      ZFS_POOL_IDENTITY_LSBLK_BIN=${lib.escapeShellArg "${pkgs.util-linux}/bin/lsblk"} \
      ${poolIdentityVerifier} ${poolIdentityVerifierArgs}

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
    guardedServices = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        Systemd service names that must not run unless the data-pool layout is
        available.  Enabled application modules contribute their storage
        layout units and every runtime service that reads or writes dataRoot.
      '';
    };

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
      {
        assertion = builtins.length cfg.guardedServices == builtins.length (lib.unique cfg.guardedServices);
        message = "repo.storage.dataPool.guardedServices contains duplicate service names.";
      }
      {
        assertion = !(builtins.elem "data-pool-layout" cfg.guardedServices);
        message = "data-pool-layout cannot depend on itself through repo.storage.dataPool.guardedServices.";
      }
      {
        assertion = storageValidation.validZpoolGuid expectedPoolGuidRaw;
        message = "storage.dataPool.expectedGuid must be null or a non-empty decimal string containing the GUID reported by zpool get guid.";
      }
      {
        assertion = invalidSharedContentNames == [ ];
        message = "repo.storage.sharedRoots.contentSubdirs must contain only safe single directory names: ${lib.concatStringsSep ", " invalidSharedContentNames}";
      }
      {
        assertion = invalidSharedVideoNames == [ ];
        message = "repo.storage.sharedRoots.videoSubdirs must contain only safe single directory names: ${lib.concatStringsSep ", " invalidSharedVideoNames}";
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

    systemd.services = lib.mkMerge [
      {
        data-pool-layout = {
          description = "Provision data-pool-backed content layout";
          wantedBy = [ "local-fs.target" ];
          wants = [ "systemd-udev-settle.service" ];
          after = [ "systemd-modules-load.service" "systemd-udev-settle.service" ];
          before = [ "local-fs.target" ];
          unitConfig = {
            DefaultDependencies = false;
            StartLimitIntervalSec = "5min";
            StartLimitBurst = 6;
          };
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            TimeoutStartSec = "10min";
            Restart = "on-failure";
            RestartSec = "15s";
          };
          script = if vars.enableZfsDataPool then zfsLayoutScript else directoryLayoutScript;
        };
      }
      (lib.genAttrs cfg.guardedServices (_: {
        requires = [ "data-pool-layout.service" ];
        after = [ "data-pool-layout.service" ];
        unitConfig = lib.mkIf vars.dataRootIsMountPoint {
          ConditionPathIsMountPoint = vars.dataRoot;
        };
      }))
    ];
  };
}
