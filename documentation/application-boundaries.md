# Application lifecycle and interface boundaries

## SQLite initialization

Media Manager initializes its catalog once at each process entrypoint (HTTP,
scanner, mutation broker). `Catalog::initialize` takes an immediate transaction
and runs every outstanding migration through schema version 3 before returning.
An unsuccessful migration rolls back its schema and data changes. Version 1
queued plans retain the existing migration policy of becoming rejected; they
must be previewed again. Ordinary `Catalog::open`/`CatalogHandle::open` calls
require a current database and perform no schema writes or implicit creation.

Mail Archive uses `PRAGMA user_version` to distinguish its existing unversioned
schema from version 1. Its legacy column additions and table cleanup run together
in one transaction. Repeated initialization skips that cleanup. Both applications
reject newer schema versions instead of attempting to downgrade them. WAL setup
happens outside the migration transaction, as SQLite requires.

Before a future incompatible schema upgrade, retain a database backup and define
the restore procedure: rolling back the NixOS executable does not undo a committed
SQLite migration. A migration failure itself leaves the prior schema available.

## Blocking work in HTTP services

`homelab_common::work::isolate_handlers` gives Media Manager, its provider broker,
and Mail Archive separate budgets of 16 in-flight handlers. Handler futures are
polled on Tokio blocking workers so existing synchronous SQLite and filesystem
operations cannot stall async reactor threads. The future still has access to the
Tokio runtime for asynchronous I/O. Streaming response bodies run asynchronously
after the handler returns.

Admission is immediate: saturation returns HTTP 503 with `Retry-After: 1` and an
error code of `server_busy`. There is no application-side waiting queue. The
worker owns its permit until completion even if its caller disconnects. This is
an isolation boundary for the existing mixed handlers; new code should keep
blocking operations explicit and bounded too.

Mail Archive additionally shares two background action slots across HTTP sync and
repair requests. A full budget rejects new work instead of creating unlimited
detached blocking tasks. Existing account state and reconciliation remain the
source of job progress; this budget is not a durable job queue. Scheduled CLI
execution retains its existing process and account locking boundaries.

## Optional integrations

`modules/catalog.nix` declares each integration's module path, required `allApps`,
and alternative `anyApps` triggers. `lib/select-integrations.nix` selects imports
for the configured app list; the existing local integration guards still cover
more specific service conditions. Add or remove dependency metadata here, rather
than maintaining a separate shell dependency map.

The integration test checks catalog references, directory coverage, uniqueness,
and selection semantics. Optional-module removal evaluation checks actual NixOS
behavior, including integration disappearance. Homepage card checks should use
evaluated card registrations rather than checking for a particular source layout.
The validation build uses `--keep-going` so independent checks can finish after
one fails; any failed check still fails the gate and preserves the prior passing
validation roots.

## Media Manager API contract

`custom_apps/rust/apps/media-manager/openapi.yaml` is the wire contract. Run:

```sh
python3 scripts/helpers/generate-media-api.py
```

The generator uses Python and PyYAML only as build tooling. It produces frontend
wire types and runtime schema data, plus the same data for Rust handler contract
tests. Keep generated files tracked. `--check` rejects stale outputs, and the
`media-manager-api-contract` flake check supplies the pinned Python environment.

The JSON client validates successful responses against the documented method,
path, status and schema before returning them. Unknown responses, malformed JSON,
and shape mismatches produce `ApiError` with `invalid_response`. Binary downloads
use their separate existing byte validation. Add a response schema when adding a
JSON endpoint, regenerate the artifacts, and exercise actual handler responses
against the contract in the Rust tests. UI state and user-editable drafts remain
separate from generated transport types.

Frontend UI fixtures may use the contract-driven fixture builder to supply omitted
transport fields. Tests of invalid responses must bypass it, and fixtures must
still use the actual endpoint status codes and domain values.

For full validation from a minimal server SSH environment, supply the Node
runtime required by the shell canary tests alongside the ops shell's Rust
toolchain, using the repository's pinned inputs:

```sh
nix develop .#ops -c nix shell --inputs-from . nixpkgs#nodejs -c bash scripts/validate-repo.sh --full
```

This does not install Node globally or deploy the configuration.

## Media Manager provider accounts and system jobs

Provider accounts (OpenSubtitles, TMDB, Immich and the rest) are saved under
Metadata sources and stored by the provider broker per signed-in user, keyed by
that user's stable Kanidm subject. An account saved under one login is not
visible, testable or usable from another login; sign in as the account's owner
to see or replace it.

Host system jobs never use the broker's forwarded-identity HTTP API. Listing a
Unix user in `repo.mediaManager.providerSystemClients` adds it to
`media-manager-provider-system` and makes the broker also listen on
`/run/media-manager-provider-system/system.sock` (directory `2750`, socket
`0660`; the group is the authorization boundary). The socket serves
`POST /system/v1/opensubtitles/episode-text`: the caller names the user whose
saved OpenSubtitles account to use (for a DVD, its uploader) and receives one
episode's plain dialogue text, never credentials. Errors are `no_account`,
`not_found`, `quota` and `provider_error`. Successful texts are cached in the
broker's lookup cache for a week, so repeated identification does not spend the
owner's daily download quota. It also serves `POST /system/v1/tmdb/tv-episodes`
(`owner` plus one of `tmdbId`, `tvdbId`, `imdbId`, or `name` with optional
`year`), which returns a series' TMDB seasons, specials included, with each
episode's number, name, air date and runtime, using the named user's saved TMDB
account. Layouts are public data and cached for a week. Errors are `no_account`
(404), `not_found`, `ambiguous` (409, with candidates) and `provider_error`.

The socket also serves two keyless routes for the audio CD importer.
`POST /system/v1/audible/search` (`title`, optional `author`) returns up to ten
editions from Audible's public catalogue with their ASIN, authors, narrators,
runtime, abridgement, series, description and cover address; answers are cached
for a week and upstream requests are spaced a second apart. Audible does not
document this endpoint, so every unexpected answer is `provider_error` and the
importer retries later. `POST /system/v1/audible/cover` (`image`) fetches one
JPEG of at most 2 MiB, and only from the catalogue's own image host.

For music discs it serves `POST /system/v1/acoustid/release-groups` (`owner`,
`fingerprint`, `duration`), which returns the MusicBrainz release groups one
Chromaprint fingerprint appears on, using the named user's saved AcoustID
account (`no_account` without one), and `POST
/system/v1/musicbrainz/release-group` (`releaseGroup`), which lists up to
fifty releases of that group with each disc's track titles and lengths.
Both answers are cached for a week; AcoustID requests are spaced 350 ms apart
and MusicBrainz requests 1.1 s.

With the list empty (the default) no socket exists.
