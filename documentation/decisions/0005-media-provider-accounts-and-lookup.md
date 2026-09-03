# Runtime media provider accounts and lookup boundary

- Status: accepted
- Date: 2026-09-02
- Supersedes: the build-time OpenSubtitles and AcoustID credential portions of
  [ADR 0001](0001-media-manager-architecture.md)

## Context

Media Manager can already inspect portable and application observations, stage
safe metadata changes, search MusicBrainz, fingerprint music through AcoustID,
search OpenSubtitles, and contains an initial TMDB adapter. OpenSubtitles and
AcoustID credentials are currently Nix/agenix inputs, however, and TMDB is not
wired into the deployed service. That makes the application harder to move
between configurations and makes ordinary account changes depend on a NixOS
rebuild.

Provider accounts must belong to individual people. Sharing one account would
couple every user's quota, suspension, password rotation, and audit history.
The authentication gateway supplies both the stable OIDC subject and a mutable
preferred username; the preferred username is appropriate for display and the
existing personal-library path, but not for durable credential ownership.

The application should make useful public, account-based, and optional lookup
sources discoverable without exposing saved credentials after submission.
Vaultwarden, KeePassXC, and similar password managers are appropriate recovery
copies, but making Media Manager depend on a password manager's vault format,
session, or API would increase the blast radius of either service and would not
remove the need for Media Manager to protect provider secrets while using them.

## Decision

Add a dedicated `media-manager-provider-broker` Rust service. It listens only
on a separate loopback port and owns `/var/lib/media-manager-provider`. The
shared authentication gateway routes `/api/v1/provider-accounts` and
`/api/v1/provider-lookups` to this service after removing spoofable identity headers and
supplying authenticated headers. Credential request bodies therefore do not
pass through the ordinary Media Manager web process. The mutation broker
remains a separate, networkless service and never receives provider secrets.

The provider broker uses the forwarded OIDC subject as the credential owner.
The preferred username is stored only as a current display label. A username
change must continue to resolve the same accounts; a different subject must not
be able to enumerate, test, replace, or delete them. Object lookup that fails
either ownership or existence returns the same not-found response.

The broker creates a random 256-bit master key at first runtime with mode 0600.
Each credential document is encrypted independently with XChaCha20-Poly1305 and
a fresh random 192-bit nonce. The schema version, owner subject, and provider ID
are authenticated as associated data so ciphertext cannot be moved between
users or providers. SQLite stores ciphertext, nonce, non-secret display state,
and health history in a broker-only database. API responses, structured logs,
status text, and audit rows never include a submitted secret. Updating an
account replaces the complete credential document; secrets are never returned
to pre-fill a form. The database and master key are included in the existing
encrypted backup system, while an export of plaintext provider credentials is
not supported.

The account API is additive and resource-oriented:

- `GET /api/v1/provider-accounts` returns a versioned provider catalog and the
  authenticated user's non-secret setup state.
- `PUT /api/v1/provider-accounts/{providerId}` validates and replaces that
  user's credential document. The response contains only status metadata.
- `POST /api/v1/provider-accounts/{providerId}/test` performs a bounded live
  check and records a normalized success, credential rejection, rate-limit, or
  provider-unavailable result.
- `DELETE /api/v1/provider-accounts/{providerId}` removes only that user's
  account and is idempotent.

Provider definitions declare media domains, credential field descriptions,
whether an account or key is required, setup/documentation URLs, capabilities,
implementation state, and the optional adapter used for a live connection
test. The API derives `canConfigure` and `canTest` from those declarations so
the setup interface does not infer support from provider IDs. Public sources
appear as ready without accepting a credential. Sources whose lookup adapter
has not shipped remain visibly `planned`, rather than implying that saving a
key already affects matching.

Provider calls use a broker-owned adapter registry with strict response bounds,
HTTPS-only origins except explicit loopback test mirrors, per-user/provider
rate-limit state, redacted errors, and timeouts. Lookup results are suggestions
with source IDs, provenance, and confidence evidence. They enter the existing
draft, preview, digest, and explicit-confirm workflow; no provider result writes
or renames media automatically.

The Accounts interface explains that saved values cannot be viewed again and
encourages users to keep their recovery copy in Vaultwarden, KeePassXC, or
another password manager. Vaultwarden is not a live credential backend: the
two applications keep separate encryption keys, authorization boundaries,
availability, and backup/restore behavior.

## Initial provider inventory

The catalog starts with adapters already present or directly useful to the
managed media types:

- Movies and television: TMDB, TVDB, OMDb, Fanart.tv and Wikidata.
- Music: MusicBrainz, Cover Art Archive, AcoustID, Discogs and TheAudioDB.
- Books and comics: Open Library, Google Books, Comic Vine and ISBNdb.
- Podcasts and audiobooks: Podcast Index and Audnexus.
- Subtitles: OpenSubtitles and SubDL.

Public sources such as MusicBrainz, Cover Art Archive, Open Library, Wikidata,
and Audnexus require no stored account. A catalog entry does not waive a
provider's terms, attribution rules, commercial-use limits, or rate limits.
Adapters are enabled in practical batches and their implementation state is
shown to the user.

## Consequences

- Provider account changes and rotations happen at runtime without a rebuild.
- One user's quota, rejected password, or provider lock does not disable other
  users who configured their own account.
- Compromise of the ordinary web UID or mutation broker does not grant direct
  read access to stored credential ciphertext or the master key.
- A provider-broker state loss requires users to re-enter accounts from their
  password managers; there is no UI or API that reveals a saved secret.
- The broker is network-capable by design and therefore receives tighter
  filesystem access than the ordinary web service: it cannot read media roots,
  the catalog database, or mutation staging.
- The deployed Media Manager service no longer receives build-time TMDB,
  OpenSubtitles, or AcoustID credentials; its adapters resolve the caller's
  runtime account through the broker.

## Rejected alternatives

- Store plaintext credentials in SQLite or show them again in the UI.
- Key credential ownership by preferred username or filesystem path.
- Share one provider account across all Media Manager users.
- Make Vaultwarden a required online secret backend or request vault master
  credentials from Media Manager.
- Give the network-capable provider broker mutation or media-library access.
- Automatically apply the highest-scoring online match.
