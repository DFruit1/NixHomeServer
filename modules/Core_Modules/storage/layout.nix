{ pkgs, vars, ... }:

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

  zfsContentLayoutScript = builtins.concatStringsSep "\n" (map mkDirCmd zfsContentDirs);
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

      ensure_dataset '${canonicalUsersDataset}' '${vars.usersRoot}'
      ensure_dataset '${canonicalSharedDataset}' '${vars.sharedRoot}'
      ensure_dataset '${canonicalUploadStagingDataset}' '${vars.uploadSecurity.stagingRoot}'
      ${zfsBin} set exec=off '${canonicalUploadStagingDataset}'
      ${zfsBin} set devices=off '${canonicalUploadStagingDataset}'
      ${zfsBin} set setuid=off '${canonicalUploadStagingDataset}'
      ${zfsContentLayoutScript}
    '';
  };
}
