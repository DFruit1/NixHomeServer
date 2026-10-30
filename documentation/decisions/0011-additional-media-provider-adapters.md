# Additional reviewable media providers

- Status: accepted
- Date: 2026-10-31
- Extends: [ADR 0005](0005-media-provider-accounts-and-lookup.md) and
  [ADR 0007](0007-provider-metadata-enrichment.md)

## Context

The account catalogue listed eleven planned providers without usable lookup
adapters. Adding credentials alone could not make those entries useful. Existing
movie, book and music comparisons already provide a safe way to select metadata;
artwork and subtitles have separate staged confirmation workflows.

## Decision

Implement all eleven adapters in the existing Rust provider broker. Each upstream
owns a small module under `src/provider_account_http/additional/`. Shared transport
bounds, credential ownership, throttling and normalized candidate contracts stay
in that directory's parent module. The existing adapters and their routes remain
compatible. No new network service, database migration or deployment setting is
required.

The additional search/details routes return bounded candidates with explicit
fields, provider identifiers, reference evidence and optional child-record links.
The frontend validates field values through the existing metadata mapper and
uses the existing field-by-field comparison. Provider results never create an
automatic mutation. A detail list can represent TV episodes, exact music releases
or comic issues without treating their parent record as the selected edition.

Artwork references are random, short-lived, bounded in number and tied to the
OIDC subject and provider. The broker accepts upstream artwork only from a
provider-specific HTTPS host allowlist; clients cannot supply remote URLs.
Credentials are never forwarded to image hosts. Account replacement/deletion
invalidates that account's references. TVDB bearer tokens additionally use a
credential-version digest and are zeroized when evicted.

Fanart and music enrichment can offer cover, background and logo roles. Only one
selected image is fetched at a time. Backgrounds and logos use separate
`backdrop.*` and `logo.*` destinations and do not replace a cover or archive an
embedded cover. All roles retain the existing fingerprint, archive, no-overwrite
and explicit-confirmation behavior. Supplemental artwork is excluded from cover
selection.

ComicInfo stores selected provider IDs in the namespaced `mm:providerIds`
extension (`urn:nixhomeserver:media-manager:metadata:1`) while retaining the
standard Web link. Inspection and managed XML merging understand the extension,
preserve unrelated XML, and retain fractional issue numbers as text.

Podcast Index supplies discovery and reference information. Podcast metadata
remains owned by Audiobookshelf, with a native-editor handoff; portable writes
stay disabled. Feed IDs, podcast GUIDs and episode GUIDs remain distinct. The
protocol requires SHA-1 request signing, so the workspace's already locked SHA-1
version is explicitly declared. SHA-256 cannot substitute for that protocol.
Existing workspace `html2text` handles upstream HTML summaries.

SubDL uses v2 deterministic search and owner-bound download references. ZIP
downloads are bounded to 10 MiB compressed, 128 entries, 32 MiB total expanded
content and 2 MiB per subtitle. Traversal, non-regular files, overlapping entries
and unsupported encodings/formats are rejected. Packs require an explicit member
choice. Downloading returns validated UTF-8 content; the normal subtitle upload
workflow stages it and still requires confirmation. Its source label records the
user-selected SubDL origin, not a cryptographic assertion about client content.

## Consequences

- Catalogue entries become active with their usable adapters and editor paths.
  Required user accounts and provider entitlements remain separate setup state.
- Audnexus is an ASIN-and-region lookup, not an invented title-search endpoint.
  Its maintainers recommend AudiobookDB for new projects; switching providers
  remains a separate product decision.
- ISBNdb initially supplies edition metadata. Artist biographies, pressing
  evidence, track lists and non-IMDb rating scales remain reference information
  where the portable editor has no corresponding field.
- Search, page changes and downloads are explicit user actions. Upstream limits,
  missing records and credential failures produce bounded, redacted errors.
- New automated checks are limited to concrete credential-disclosure,
  cross-user-reference and unsafe-archive risks. Ordinary field/UI behavior uses
  existing focused checks and direct verification, following AGENTS.md.
- Focused fixture verification does not prove live provider availability,
  account entitlements or consuming-application refresh behavior. Live deployment
  remains separate from local fixture verification.

## Sources

- [TheTVDB v4 specification](https://github.com/thetvdb/v4-api/blob/master/docs/swagger.yml)
- [OMDb parameters](https://www.omdbapi.com/)
- [Fanart API](https://api.fanart.tv/)
- [Discogs developer documentation](https://www.discogs.com/developers/)
- [TheAudioDB v1/v2 guide](https://www.theaudiodb.com/free_music_api)
- [Comic Vine API](https://comicvine.gamespot.com/api/documentation)
- [ISBNdb v2 API](https://isbndb.com/apidocs/v2)
- [Podcast Index contract](https://podcastindex-org.github.io/docs-api/pi_api.json)
- [SubDL v2 guide](https://subdl.com/developers)
- [Wikidata data access](https://www.wikidata.org/wiki/Wikidata:Data_access)
- [Audnexus](https://github.com/laxamentumtech/audnexus)

Discogs, Comic Vine and ISBNdb documentation could not be retrieved by the web
tool during implementation. Their adapters have local protocol fixtures; live
account verification remains distinct evidence.
