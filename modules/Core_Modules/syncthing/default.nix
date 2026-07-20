{ config, lib, pkgs, vars, ... }:

let
  offlineMediaCfg = vars.offlineMedia;
  enabled =
    (config.nixhomeserver.modules."offline-music" or false)
    && (offlineMediaCfg.enable or false);
  offlineMediaModel = (import ../../../lib/offline-media.nix { inherit lib; }) offlineMediaCfg;
  storageValidation = import ../../../lib/storage-validation.nix { inherit lib; };
  stateDir = offlineMediaCfg.stateDir or "/persist/appdata/offline-media";
  stateFile = "${stateDir}/devices.json";
  syncthingConfig = "/var/lib/syncthing/.config/syncthing/config.xml";
  cleanupInputsValid =
    storageValidation.validAbsolutePath stateDir
    && lib.hasPrefix "/persist/appdata/" stateDir
    && offlineMediaModel.folderSpecsAreList
    && offlineMediaModel.invalidFolderSpecIndexes == [ ]
    && offlineMediaModel.invalidFolderIdPrefixes == [ ]
    && !offlineMediaModel.duplicateFolderIdPrefixes
    && !offlineMediaModel.duplicateRelativePaths
    && lib.all storageValidation.validRelativePath offlineMediaModel.relativePaths;
  disabledCleanup = pkgs.writeShellApplication {
    name = "offline-media-disabled-cleanup";
    runtimeInputs = with pkgs; [
      coreutils
      jq
      libxml2
      systemd
      util-linux
      xmlstarlet
    ];
    text = ''
      export OFFLINE_MEDIA_FOLDER_SPECS_JSON=${lib.escapeShellArg (builtins.toJSON offlineMediaModel.folderSpecs)}
      export OFFLINE_MEDIA_LOCK_FILE=${lib.escapeShellArg "${stateDir}/.devices.lock"}
      export OFFLINE_MEDIA_STATE_FILE=${lib.escapeShellArg stateFile}
      export OFFLINE_MEDIA_SYNCTHING_CONFIG=${lib.escapeShellArg syncthingConfig}
      export OFFLINE_MEDIA_USERS_ROOT=${lib.escapeShellArg vars.usersRoot}
      exec ${../../../scripts/helpers/offline-media-disabled-cleanup.sh}
    '';
  };
  lanIface = vars.networking.interfaces.lan;
  netbirdIface = vars.networking.interfaces.netbird;
  syncthingHost = "syncthing.${vars.domain}";
in
{
  config = lib.mkMerge [
    (lib.mkIf enabled {
      services.syncthing = {
        enable = true;
        systemService = true;
        user = "syncthing";
        group = "syncthing";
        dataDir = "/var/lib/syncthing";
        configDir = "/var/lib/syncthing/.config/syncthing";
        guiAddress = "127.0.0.1:8384";
        openDefaultPorts = false;
        overrideDevices = false;
        overrideFolders = false;

        settings.options = {
          natEnabled = false;
          relaysEnabled = false;
          globalAnnounceEnabled = false;
          localAnnounceEnabled = true;
        };
      };

      networking.firewall.interfaces = {
        ${lanIface} = {
          allowedTCPPorts = [ 22000 ];
          allowedUDPPorts = [
            22000
            21027
          ];
        };
        ${netbirdIface} = {
          allowedTCPPorts = [ 22000 ];
          allowedUDPPorts = [
            22000
            21027
          ];
        };
      };

      # The administrative GUI is never published directly. Register it with
      # the shared SSO gateway so a disabled or unavailable gateway fails closed.
      repo.authGateway.protectedApps.syncthing = {
        host = syncthingHost;
        upstream = "http://127.0.0.1:8384";
        allowedGroups = [ "app-admin" ];
      };

      services.unbound.privateHosts.${syncthingHost} = {
        target = "private";
      };
    })

    # This unit lives in Core_Modules so it still exists after the optional
    # offline-music module is removed.  It edits only validated, managed
    # Syncthing XML entries while Syncthing is stopped and retains both the
    # source trees and enrollment inventory for deliberate re-enablement.
    (lib.mkIf (!enabled && cleanupInputsValid) {
      systemd.services.offline-media-disabled-cleanup = {
        description = "Remove disabled offline-media peers and folders from persistent Syncthing configuration";
        wantedBy = [ "multi-user.target" ];
        conflicts = [ "syncthing.service" ];
        before = [ "syncthing.service" ];
        unitConfig.ConditionPathExists = syncthingConfig;
        serviceConfig = {
          Type = "oneshot";
          ExecStart = lib.getExe disabledCleanup;
        };
      };
    })
  ];
}
