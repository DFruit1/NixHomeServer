{ config, lib, pkgs, vars, ... }:

let
  cfg = config.repo.immich;
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
      path = cfg.paths.root;
      mode = "0755";
      user = "root";
      group = "root";
    }
    {
      path = cfg.paths.managed;
      mode = "0750";
      user = "immich";
      group = "immich";
    }
    {
      path = cfg.paths.external;
      mode = "2770";
      user = "root";
      group = "immich";
    }
  ] ++ map
    (name: {
      path = "${cfg.paths.managed}/${name}";
      mode = "0750";
      user = "immich";
      group = "immich";
    })
    managedSubdirs;

  immichStorageLayoutScript = builtins.concatStringsSep "\n" (
    (map mkDirCmd immichStorageDirs)
    ++ map (name: mkImmichSentinelCmd "${cfg.paths.managed}/${name}/.immich") managedSubdirs
  );
in
{
  options.repo.immich.paths = {
    root = lib.mkOption {
      type = lib.types.str;
      default = "${vars.dataRoot}/immich";
      description = "Immich data-pool root.";
    };

    managed = lib.mkOption {
      type = lib.types.str;
      default = "${config.repo.immich.paths.root}/managed";
      description = "Immich managed media root.";
    };

    external = lib.mkOption {
      type = lib.types.str;
      default = "${config.repo.immich.paths.root}/external";
      description = "Immich external library root.";
    };
  };

  config = {
    systemd.services.immich-storage-layout-v1 = {
      description = "Provision Immich storage layout";
      wantedBy = [ "multi-user.target" ];
      wants = [ "data-pool-layout.service" "local-fs.target" ];
      after = [ "data-pool-layout.service" "local-fs.target" ];
      before = [ "immich-server.service" ];
      unitConfig = lib.mkIf vars.dataRootIsMountPoint {
        ConditionPathIsMountPoint = vars.dataRoot;
      };
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
