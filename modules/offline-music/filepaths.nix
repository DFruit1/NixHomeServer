{ lib, vars, ... }:

let
  legacyCfg = vars.offlineMusic or { };
  cfg = if builtins.hasAttr "offlineMedia" vars then vars.offlineMedia else legacyCfg;
  enabled = cfg.enable or false;
  folderName = cfg.musicFolderName or cfg.folderName or "_Music";
  folderSpecs = cfg.folders or [
    { relativePath = folderName; }
    { relativePath = "_Videos/_YouTube"; }
    { relativePath = "_Videos/_Other"; }
  ];
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
  accessGroup = cfg.accessGroup or "users";
  stateDir = cfg.stateDir or "/persist/appdata/offline-media";
in
{
  config = lib.mkIf enabled {
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
