{ config, lib, ... }:

let
  libraryRoot = config.repo.kiwix.paths.libraryRoot;
in

{
  config = lib.mkIf config.repo.kiwix.enable {
    repo.backups = {
      criticalPaths = [
        libraryRoot
      ];
      pathInventories = [
        {
          label = "kiwix";
          root = libraryRoot;
        }
      ];
      pathRows.app-content-roots = [
        {
          label = "kiwix-library";
          path = libraryRoot;
          owner = "kiwix";
        }
      ];
    };
  };
}
