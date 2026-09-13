{ config, lib, ... }:

let
  cfg = config.repo.calibreWeb;
in
{
  config = lib.mkIf cfg.enable {
    repo.backups = {
      appStateEntries = [
        {
          app = "calibre-web";
          component = "app";
          stateRoot = "/var/lib/calibre-web";
          payloadRoots = [ cfg.paths.libraryRoot ];
          notes = "Calibre-Web settings database, local accounts, and the technical Calibre library.";
        }
      ];
      criticalPaths = [ cfg.paths.libraryRoot ];
      sqliteDumps = [
        {
          source = "/var/lib/calibre-web/app.db";
          outputName = "calibre-web.sqlite";
        }
        {
          source = "${cfg.paths.libraryRoot}/metadata.db";
          outputName = "calibre-web-calibre-metadata.sqlite";
        }
      ];
    };
  };
}
