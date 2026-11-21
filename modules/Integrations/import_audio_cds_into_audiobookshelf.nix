# The DVD converter's audio CD importer publishes audiobook and spoken-word
# discs into Audiobookshelf: the shared inbox into the shared library, and
# each user's own inbox into that user's library. Audiobookshelf's native
# library watcher picks a book up once its finished folder is renamed into
# place, so no scan request is needed.
{ config, ... }:
{
  repo.mkvmaker.audio = {
    enable = true;
    sharedLibrary = config.repo.audiobookshelf.paths.sharedAudiobooksRoot;
    userLibrary = "_Audiobooks";
    libraryGroups = [ "audiobookshelf-media" ];
    libraryUnits = [ "audiobookshelf-storage-layout-v1.service" ];
  };
}
