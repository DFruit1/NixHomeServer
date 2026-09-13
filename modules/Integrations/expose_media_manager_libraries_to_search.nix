{ config, lib, options, vars, ... }:

let
  hasApp = name: lib.hasAttrByPath [ "repo" name ] options;
  searchPresent = lib.hasAttrByPath [ "repo" "search" ] options;
  mediaApps = [ "jellyfin" "audiobookshelf" "kavita" ];
  enabledMediaApps = lib.filter hasApp mediaApps;
in
{
  # The structure of this module's config is decided from `options` alone;
  # the runtime enable flag is applied with mkIf. Referencing `config` in the
  # optionalAttrs guard instead would recurse while the option tree is built.
  config = lib.optionalAttrs
    (searchPresent && enabledMediaApps != [ ])
    (lib.mkIf config.repo.search.enable {
      # Media Manager already exports bounded, read-only metadata snapshots for
      # each media application. Indexing those snapshots gives Search every
      # library's titles, descriptions, authors, narrators, genres, and tags
      # without per-application credentials or direct database access.
      repo.search.sources = lib.mkMerge [
        (lib.optionalAttrs (hasApp "jellyfin") {
          jellyfin = {
            displayName = "Videos";
            sourceType = "media-snapshot";
            appBase = "https://videos.${vars.domain}";
            settings.snapshotPath = "/var/cache/media-manager-jellyfin/metadata.json";
          };
        })
        (lib.optionalAttrs (hasApp "audiobookshelf") {
          audiobookshelf = {
            displayName = "Audiobooks";
            sourceType = "media-snapshot";
            appBase = "https://audiobooks.${vars.domain}/audiobookshelf/";
            settings.snapshotPath = "/var/cache/media-manager-audiobookshelf/metadata.json";
          };
        })
        (lib.optionalAttrs (hasApp "kavita") {
          kavita = {
            displayName = "Books";
            sourceType = "media-snapshot";
            appBase = "https://books.${vars.domain}";
            settings = {
              snapshotPath = "/var/cache/media-manager-kavita/metadata.json";
              # Kavita's snapshot omits a per-entry media type; index its
              # entries as books for the content-type facet.
              contentType = "book";
            };
          };
        })
      ];

      # The snapshots are group-readable by the Media Manager service group.
      users.users.search.extraGroups = lib.mkAfter [ "media-manager" ];
    });
}
