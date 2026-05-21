{ vars, ... }:

{
  config = {
    repo.apps.kiwix.filepaths = {
      state = "/var/lib/kiwix";
      data = vars.kiwixLibraryRoot;
      mediaRoots.library = vars.kiwixLibraryRoot;
    };
  };
}
