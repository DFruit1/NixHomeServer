{ config, ... }:

let
  libraryRoot = config.repo.kiwix.paths.libraryRoot;
in

{
  config = {
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
