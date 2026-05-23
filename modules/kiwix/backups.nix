{ vars, ... }:

{
  config = {
    repo.backups = {
      criticalPaths = [
        vars.kiwixLibraryRoot
      ];
      pathInventories = [
        {
          label = "kiwix";
          root = vars.kiwixLibraryRoot;
        }
      ];
      pathRows.upload-flow-roots = [
        {
          label = "kiwix-library";
          path = vars.kiwixLibraryRoot;
          owner = "kiwix";
        }
      ];
    };
  };
}
