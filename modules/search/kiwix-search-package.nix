{ kiwix-tools }:

# Upstream kiwix-search prints display titles, which cannot be used as ZIM
# entry paths (spaces, punctuation and namespaces need not match). Search
# resolves titles/snippets itself with zimdump and needs the actual paths.
# Raise both title and full-text samples to the app's per-archive limit.
kiwix-tools.overrideAttrs (old: {
  pname = "kiwix-tools-search-paths";
  postPatch = (old.postPatch or "") + ''
    substituteInPlace src/searcher/kiwix-search.cpp \
      --replace-fail 'cout << r.getTitle() << endl;' 'cout << r.getPath() << endl;' \
      --replace-fail '.getResults(0, 10)' '.getResults(0, 25)'
  '';
})
