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
      pathRows.upload-flow-roots = [
        {
          label = "kiwix-library";
          path = libraryRoot;
          owner = "kiwix";
        }
      ];
    };
  };
}
