{ lib, pkgs, vars, ... }:

let
  zfsBin = "${pkgs.zfs}/bin/zfs";
  canonicalUsersDataset = "${vars.zfsDataPool.name}/users";
  canonicalSharedDataset = "${vars.zfsDataPool.name}/shared";
  canonicalUploadStagingDataset = "${vars.zfsDataPool.name}/upload-staging";

  mkDirCmd =
    { path
    , mode
    , user
    , group
    ,
    }:
    "${pkgs.coreutils}/bin/install -d -m ${mode} -o ${user} -g ${group} '${path}'";

  zfsContentDirs = [
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
    {
      path = vars.uploadSecurity.stagingRoot;
      mode = "0710";
      user = "root";
      group = "upload-staging";
    }
    {
      path = vars.uploadSecurity.quarantineRoot;
      mode = "0750";
      user = "upload-processor";
      group = "upload-review";
    }
  ];

  datasetSpecs = [
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
    {
      dataset = canonicalUploadStagingDataset;
      mountpoint = vars.uploadSecurity.stagingRoot;
      properties = {
        compression = "zstd";
        atime = "off";
        exec = "off";
        devices = "off";
        setuid = "off";
      };
    }
  ];

  mkDatasetEnsure = spec:
    let
      propertyCommands = lib.concatStringsSep "\n"
        (lib.mapAttrsToList
          (property: value: "${zfsBin} set ${property}='${value}' '${spec.dataset}'")
          spec.properties);
    in
    ''
      ensure_dataset '${spec.dataset}' '${spec.mountpoint}'
      ${propertyCommands}
    '';

  zfsContentLayoutScript = builtins.concatStringsSep "\n" (map mkDirCmd zfsContentDirs);
  zfsDatasetLayoutScript = builtins.concatStringsSep "\n" (map mkDatasetEnsure datasetSpecs);
in
{
  systemd.tmpfiles.rules = [
    "d /persist/appdata 0755 root root -"
  ];

  systemd.services.data-pool-layout = {
    description = "Provision data-pool-backed content layout";
    wantedBy = [ "multi-user.target" ];
    wants = [ "local-fs.target" ];
    after = [ "local-fs.target" ];
    unitConfig.ConditionPathIsMountPoint = vars.dataRoot;
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      set -euo pipefail
      ensure_dataset() {
        local dataset="$1"
        local mountpoint="$2"

        if ! ${zfsBin} list -H -o name "$dataset" >/dev/null 2>&1; then
          ${zfsBin} create -o mountpoint="$mountpoint" "$dataset"
        else
          ${zfsBin} set canmount=on "$dataset"
          ${zfsBin} set mountpoint="$mountpoint" "$dataset"
          ${zfsBin} mount "$dataset" >/dev/null 2>&1 || true
        fi
      }

      ${zfsDatasetLayoutScript}
      ${zfsContentLayoutScript}
    '';
  };
}
