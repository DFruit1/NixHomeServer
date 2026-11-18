# Jellyfin's metadata and image fetcher order per item type. metadata.nix
# writes it into Jellyfin; media-manager.nix names the online sources it uses
# for movies and shows in Media Manager's Online services.
{
  Movie = {
    MetadataFetcherOrder = [ "TheMovieDb" ];
    ImageFetcherOrder = [ "Fanart" "TheMovieDb" "Screen Grabber" "Embedded Image Extraction" ];
  };
  Series = {
    MetadataFetcherOrder = [ "TheMovieDb" "TheTVDB" ];
    ImageFetcherOrder = [ "Fanart" "TheMovieDb" "TheTVDB" "Screen Grabber" "Embedded Image Extraction" ];
  };
  MusicAlbum = {
    MetadataFetcherOrder = [ "MusicBrainz" "TheAudioDB" ];
    ImageFetcherOrder = [ "Cover Art Archive" "Embedded Image Extraction" "Screen Grabber" ];
  };
}
