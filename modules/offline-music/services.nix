{ config, lib, pkgs, vars, ... }:

let
  cfg = vars.offlineMedia;
  enabled = cfg.enable or false;
  stateDir = cfg.stateDir or "/persist/appdata/offline-media";
  stateFile = "${stateDir}/devices.json";
  accessGroupRaw = cfg.accessGroup or "users";
  accessGroup = if builtins.isString accessGroupRaw then accessGroupRaw else "invalid-offline-media-access-group";
  offlineMediaModel = (import ../../lib/offline-media.nix { inherit lib; }) cfg;
  folderSpecs = offlineMediaModel.folderSpecs;
  folderSpecsJson = builtins.toJSON folderSpecs;
  kanidmCliUrl = "https://${vars.kanidmDomain}:${toString vars.networking.ports.kanidm}";
  syncthingConfig = "/var/lib/syncthing/.config/syncthing/config.xml";
  reconcile = pkgs.writeShellApplication {
    name = "offline-media-reconcile";
    runtimeInputs = with pkgs; [
      coreutils
      curl
      findutils
      jq
      kanidm_1_10
      libxml2
      systemd
      util-linux
    ];
    text = ''
      export OFFLINE_MEDIA_ACCESS_GROUP=${lib.escapeShellArg accessGroup}
      export OFFLINE_MEDIA_FOLDER_SPECS_JSON=${lib.escapeShellArg folderSpecsJson}
      export OFFLINE_MEDIA_KANIDM_PASSWORD_FILE=${lib.escapeShellArg config.age.secrets.kanidmAdminPass.path}
      export OFFLINE_MEDIA_KANIDM_URL=${lib.escapeShellArg kanidmCliUrl}
      export OFFLINE_MEDIA_LOCK_FILE=${lib.escapeShellArg "${stateDir}/.devices.lock"}
      export OFFLINE_MEDIA_STATE_FILE=${lib.escapeShellArg stateFile}
      export OFFLINE_MEDIA_SYNCTHING_CONFIG=${lib.escapeShellArg syncthingConfig}
      export OFFLINE_MEDIA_USERS_ROOT=${lib.escapeShellArg vars.usersRoot}
      exec ${../../scripts/helpers/offline-media-reconcile.sh}
    '';
  };
in
{
  config = lib.mkIf enabled {
    repo.storage.dataPool.guardedServices = [ "offline-media-reconcile" ];

    systemd.services.offline-media-reconcile = {
      description = "Reconcile authorized offline-media Syncthing folders and revoke stale devices";
      requires = [ "syncthing.service" ];
      wants = [
        "fileshare-user-root-sync.service"
        "kanidm.service"
      ];
      after = [
        "data-pool-layout.service"
        "fileshare-user-root-sync.service"
        "kanidm.service"
        "syncthing.service"
      ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe reconcile;
      };
    };

    systemd.timers.offline-media-reconcile = {
      description = "Regularly verify offline-media authorization and sync health";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "2min";
        OnUnitActiveSec = "15min";
        RandomizedDelaySec = "1min";
        Persistent = true;
      };
    };
  };
}
