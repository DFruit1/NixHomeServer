{ config, lib, ... }:

let
  fp = config.repo.apps.kiwix.filepaths;
in
{
  config = lib.mkIf config.nixhomeserver.apps.kiwix.enable {
    repo.backups = {
      criticalPaths = [
        fp.mediaRoots.library
      ];
      pathInventories = [
        {
          label = "kiwix";
          root = fp.mediaRoots.library;
        }
      ];
      pathRows.upload-flow-roots = [
        {
          label = "kiwix-library";
          path = fp.mediaRoots.library;
          owner = "kiwix";
        }
      ];
    };
  };
}
