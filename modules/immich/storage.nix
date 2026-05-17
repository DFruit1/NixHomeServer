{ config, lib, pkgs, vars, ... }:

let
  mkDirCmd =
    { path
    , mode
    , user
    , group
    ,
    }:
    "${pkgs.coreutils}/bin/install -d -m ${mode} -o ${user} -g ${group} '${path}'";

  mkImmichSentinelCmd = path: ''
    ${pkgs.coreutils}/bin/touch '${path}'
    ${pkgs.coreutils}/bin/chown immich:immich '${path}'
    ${pkgs.coreutils}/bin/chmod 0640 '${path}'
  '';

  managedSubdirs = [
    "backups"
    "encoded-video"
    "library"
    "profile"
    "thumbs"
    "upload"
  ];

  immichStorageDirs = [
    {
      path = vars.immichRoot;
      mode = "0755";
      user = "root";
      group = "root";
    }
    {
      path = vars.immichManagedRoot;
      mode = "0750";
      user = "immich";
      group = "immich";
    }
    {
      path = vars.immichExternalRoot;
      mode = "2770";
      user = "root";
      group = "immich";
    }
  ] ++ map
    (name: {
      path = "${vars.immichManagedRoot}/${name}";
      mode = "0750";
      user = "immich";
      group = "immich";
    })
    managedSubdirs;

  immichStorageLayoutScript = builtins.concatStringsSep "\n" (
    (map mkDirCmd immichStorageDirs)
    ++ map (name: mkImmichSentinelCmd "${vars.immichManagedRoot}/${name}/.immich") managedSubdirs
  );
in
{
  config = lib.mkIf config.nixhomeserver.apps.immich.enable {
    systemd.services.immich-storage-layout-v1 = {
      description = "Provision Immich storage layout";
      wantedBy = [ "multi-user.target" ];
      wants = [ "data-pool-layout.service" "local-fs.target" ];
      after = [ "data-pool-layout.service" "local-fs.target" ];
      before = [ "immich-server.service" ];
      unitConfig.ConditionPathIsMountPoint = vars.dataRoot;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        set -euo pipefail
        ${immichStorageLayoutScript}
      '';
    };

    systemd.services.immich-server = {
      wants = [ "immich-storage-layout-v1.service" ];
      after = [ "immich-storage-layout-v1.service" ];
    };
  };
}
