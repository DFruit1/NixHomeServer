# Reviewable provider metadata enrichment

- Status: accepted
- Date: 2026-09-04
- Extends: [ADR 0005](0005-runtime-media-provider-accounts.md)

## Context

The runtime provider broker already isolates per-user credentials and returns
non-writing suggestions, but its first metadata adapters stop short of several
important editing workflows. TMDB identifies movies and series but not the
selected season or episode. MusicBrainz returns a release group while cover art
belongs to an exact release. Open Library is useful for books, but a second
edition source helps disambiguate ISBNs, publishers, descriptions, and covers.

Provider responses also contain remote image URLs. Letting the browser or the
ordinary media process fetch arbitrary URLs would bypass the broker's response
bounds and create a server-side request-forgery boundary. Metadata and artwork
must remain separate choices because accepting bibliographic fields should not
implicitly replace an image, or vice versa.

The editor and provider broker had also accumulated provider-specific code in
large root modules, making it increasingly risky to add or remove an adapter.

## Decision

Complete the initial enrichment set with these broker adapters:

- TMDB movie, series, season, and episode details, plus validated image paths.
- MusicBrainz exact releases in addition to release-group identity, including
  date, country, barcode, label, catalog number, packaging, track count, and
  disambiguation.
- Cover Art Archive front artwork addressed only by a validated MusicBrainz
  release UUID.
- Google Books volume search using the authenticated user's runtime API key,
  with normalized edition metadata and cover availability.

Every provider candidate remains inert until a user opens the comparison
workspace, selects individual fields, adds them to the draft, previews the
portable mutation, and confirms it. Provider IDs are retained alongside chosen
values. Exact MusicBrainz release and release-group IDs are stored separately.
Artwork has its own prepare-and-confirm flow and does not imply metadata field
selection.

Remote artwork is fetched only through provider-specific broker routes. Route
parameters use strict identifier/path validation; JSON and image bodies are
bounded; image bytes must match a supported raster signature; responses use
`nosniff`; redirects are disabled except for an explicit Cover Art Archive to
Internet Archive allowlist. Google Books search responses never expose their
image URLs to the client: the cover route resolves the validated volume again
and accepts only Google image hosts. TMDB artwork requires the caller's saved
TMDB account, matching its metadata lookup boundary.

Provider code is separated by responsibility. The broker keeps account storage
and catalog behavior in `provider_account_http.rs`, while TMDB lookups, Google
Books, and remote artwork live in child modules. The frontend keeps orchestration
in `root.tsx`, while provider panels, normalized candidate contracts, the match
workspace, and the reusable remote-artwork confirmation flow live in separate
modules. Adding a provider should normally require a new adapter/panel and a
candidate mapper rather than expanding either root module.

## Consequences

- Episodes can be matched against a selected series without treating an
  episode ID as a series ID.
- Music candidates represent selectable physical/digital releases and can use
  the corresponding release cover rather than an ambiguous release group.
- Book editors can compare Open Library and Google Books field by field.
- Third-party image retrieval stays inside a bounded, auditable trust boundary.
- Provider modules remain coupled to the broker's common authentication,
  credential, error, throttling, and mutation contracts; they are not separate
  services.
- Google Books requires each user to supply a key, and external providers can
  still return incomplete metadata or no artwork.

## Rejected alternatives

- Automatically accept the highest-ranked provider result.
- Replace artwork whenever metadata fields are accepted.
- Send provider credentials to the browser or ordinary media web service.
- Proxy arbitrary image URLs supplied by a provider response or client.
- Treat a MusicBrainz release group as an exact edition.
- Continue adding provider UI and handlers directly to the existing root files.
