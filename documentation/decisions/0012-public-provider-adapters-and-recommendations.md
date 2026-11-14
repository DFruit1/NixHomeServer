# Public provider adapters and recommended sources

- Status: accepted
- Date: 2026-11-15
- Extends: [ADR 0011](0011-additional-media-provider-adapters.md)

## Context

The owner asked for more metadata sources, including a disc database, and for
the Metadata sources page to group sources by media type and mark the ones to
set up first. Several sources cover more than one media type but are only
authoritative for one of them.

## Decision

Add four public, keyless adapters to the existing additional-provider broker,
each in its own module under `src/provider_account_http/additional/`:

- **TheDiscDB** (movies, television): GraphQL search of media items; an item
  lists its disc releases. Release evidence maps disc playlists/files to the
  episodes or feature they contain, which helps identify ripped titles.
- **TVmaze** (television): series, season and episode drill-down.
- **AniList** (television, movies, manga): GraphQL anime/manga search returning
  complete candidates; videos search anime, books/comics search manga.
- **Deezer** (music): album search and album details with track list, label,
  UPC and high-resolution cover.

They reuse the generic `/provider-lookups/{provider}/search|details` routes,
normalized candidates, field comparison, per-subject request gates, a global
gate for shared-IP limits, and the provider-specific HTTPS artwork allowlist.
No credentials, routes, migrations or deployment settings are added.

Each catalogue entry gains `recommendedFor`, a subset of its media domains where
the source is reputable, large and accurate enough to set up first: TMDB
(movies, television), TheTVDB (television), MusicBrainz and Discogs (music),
Google Books (books), Comic Vine (comics), AniList (manga), Podcast Index
(podcasts) and OpenSubtitles (subtitles). The frontend groups single-tag
sources under that tag and multi-tag sources under "Multiple", and labels
recommended sources, naming the tag when the source covers others.

Hardcover (books) and Metron (comics) were considered but need personal
accounts that could not be verified during implementation; they remain
candidates for a later adapter.

## Consequences

- Recommendations are editorial catalogue data, not a measured ranking. Revisit
  them when a source's coverage, licensing or reliability changes.
- `recommendedFor` is optional in the contract so older fixtures and clients
  stay valid; the broker always sends it.
- The adapters were exercised once against the live upstream APIs during
  development; there are no new automated tests, following AGENTS.md. Upstream
  schema changes surface as bounded `provider_unavailable` errors.
- TVmaze omits specials; TheDiscDB coverage is community-contributed and
  smaller than the general-purpose movie/TV sources.

## Sources

- [TheDiscDB GraphQL](https://thediscdb.com/graphql)
- [TVmaze API](https://www.tvmaze.com/api)
- [AniList API](https://docs.anilist.co/)
- [Deezer API](https://developers.deezer.com/api)
