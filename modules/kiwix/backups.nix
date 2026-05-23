{ config, ... }:

let
  libraryRoot = config.services.kiwixServe.libraryRoot;
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
