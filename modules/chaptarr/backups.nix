{ config, lib, ... }:

let
  cfg = config.repo.chaptarr;
in
{
  config = lib.mkIf cfg.enable {
    repo.backups.appStateEntries = [
      {
        app = "chaptarr";
        component = "app";
        stateRoot = cfg.paths.stateDir;
        payloadRoots = [
          cfg.paths.audiobookRoot
          cfg.paths.ebookRoot
        ];
        notes = "Chaptarr database, API key, history, naming rules, and application configuration. Managed audiobook and ebook libraries are separate payload roots.";
      }
    ];
    repo.backups.sqliteDumps = [
      {
        source = "${cfg.paths.stateDir}/chaptarr.db";
        outputName = "chaptarr.sqlite";
      }
    ];
  };
}
