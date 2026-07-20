{ lib, vars, ... }:

let
  cfg = vars.offlineMedia;
  storageValidation = import ../../lib/storage-validation.nix { inherit lib; };
  enabled = cfg.enable or false;
  offlineMediaModel = (import ../../lib/offline-media.nix { inherit lib; }) cfg;
  folderSpecs = offlineMediaModel.folderSpecs;
  syncRelativePaths = lib.unique (map (spec: spec.relativePath) folderSpecs);
  videoSubdirs = lib.unique (
    lib.filter (name: name != null) (
      map
        (path:
          if lib.hasPrefix "_Videos/" path then
            lib.removePrefix "_Videos/" path
          else
            null)
        syncRelativePaths
    )
  );
  topLevelContentSubdirs = lib.unique (lib.filter (path: !(lib.hasInfix "/" path)) syncRelativePaths);
  syncthingReadonlyPaths =
    syncRelativePaths
    ++ lib.optional (lib.any (path: lib.hasPrefix "_Videos/" path) syncRelativePaths) "_Videos";
  accessGroupRaw = cfg.accessGroup or "users";
  accessGroup = if builtins.isString accessGroupRaw then accessGroupRaw else "invalid-offline-media-access-group";
  stateDir = cfg.stateDir or "/persist/appdata/offline-media";
  invalidFolderPaths = lib.filter
    (path: !storageValidation.validRelativePath path)
    syncRelativePaths;
in
{
  config = lib.mkIf enabled {
    assertions = [
      {
        assertion = offlineMediaModel.folderSpecsAreList && offlineMediaModel.invalidFolderSpecIndexes == [ ];
        message = "offlineMedia.folders must be a list of attribute sets containing string relativePath and folderIdPrefix fields; invalid entries: ${builtins.toJSON offlineMediaModel.invalidFolderSpecIndexes}";
      }
      {
        assertion = offlineMediaModel.invalidFolderIdPrefixes == [ ];
        message = "offlineMedia folderIdPrefix values must start with a lowercase letter, contain only lowercase letters, digits, dot, underscore, or hyphen, and be at most 64 characters: ${builtins.toJSON offlineMediaModel.invalidFolderIdPrefixes}";
      }
      {
        assertion = !offlineMediaModel.duplicateFolderIdPrefixes;
        message = "offlineMedia folderIdPrefix values must be unique so one managed Syncthing folder cannot alias another.";
      }
      {
        assertion = !offlineMediaModel.duplicateRelativePaths;
        message = "offlineMedia folder relativePath values must be unique.";
      }
      {
        assertion = invalidFolderPaths == [ ];
        message = "offlineMedia folder relativePath values must be normalized safe relative paths without traversal, empty components, whitespace, or control characters: ${lib.concatStringsSep ", " invalidFolderPaths}";
      }
      {
        assertion = storageValidation.validAbsolutePath stateDir && lib.hasPrefix "/persist/appdata/" stateDir;
        message = "offlineMedia.stateDir must be a normalized absolute child of /persist/appdata using only safe path components.";
      }
    ];

    repo.storage.userRoots = {
      contentSubdirs = topLevelContentSubdirs;
      videoSubdirs = videoSubdirs;
      memberGroups = [ accessGroup ];
      rootTraverseGroups = [ "syncthing" ];
      recursiveReadonlyGrants = [
        {
          group = "syncthing";
          relativePaths = lib.unique syncthingReadonlyPaths;
        }
      ];
    };

    repo.storage.sharedRoots.contentSubdirs = topLevelContentSubdirs;
    repo.storage.sharedRoots.videoSubdirs = videoSubdirs;

    systemd.tmpfiles.rules = [
      "d ${stateDir} 0750 root root -"
    ];
  };
}
