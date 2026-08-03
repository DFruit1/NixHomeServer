# Media Manager architecture and trust boundaries

- Status: accepted
- Date: 2026-08-01
- Updated: 2026-08-02

## Context

Media Manager needs to inspect several media libraries, report DVD conversion
progress, and eventually perform carefully staged metadata and filesystem
changes. Those libraries may be consumed by Jellyfin, Audiobookshelf, Kavita,
Syncthing, or no application at all. A browser-facing file manager with an
arbitrary path field would turn a naming correction tool into a general remote
filesystem interface and make authorization difficult to reason about.

The application is a core service. Optional applications may register typed
capabilities, but their absence must not prevent Media Manager from starting.

## Decision

The Rust service owns the catalog, preferences, job state, audit log, provider
coordination, and HTTP API. It listens only on loopback and is reachable through
the shared OAuth2 Proxy gateway at `media.sydneybasiniot.org`. The gateway
removes caller-supplied identity headers and supplies the authenticated Kanidm
identity. Every authenticated `users` member may view eligible roots. Only a
member of `media-manager-editors` may create or confirm a mutation plan.

The browser never supplies an arbitrary filesystem path. Every request names a
server-defined root ID and an item ID. Shared roots resolve to fixed paths.
Personal roots are resolved by the server from the authenticated username and
a fixed category suffix. Root resolution rejects unknown IDs, path separators,
NUL bytes, dot components, and symlink escapes.

Every mutation has two requests:

1. Preview creates an immutable plan containing normalized operations,
   precondition fingerprints, warnings, affected consumers, and a digest.
2. Confirm supplies the plan ID and digest using `If-Match`. The server rejects
   expired plans, changed inputs, conflicts, or a mismatched authenticated user.

No operation silently overwrites or deletes a destination. The web service is
always filesystem read-only. A separate broker UID executes only the closed
operation set after a digest-bound plan is queued. It uses Linux `openat2`
containment and `renameat2` no-replace semantics, holds no network access or
Linux capabilities, and resumes incomplete actions through the durable queue.
Operators can set mutation mode to `read-only` to stop confirmation and polling.

The durable catalog is SQLite in `/var/lib/media-manager/control.sqlite3`.
SQLite stores plan and audit state, while the media files remain authoritative.
Structured service logs contain a request ID and stable event names but never
provider credentials or media contents.

Online matches are suggestions, never automatic writes. An editor selects a
match before metadata or subtitle installation. Subtitle files default to
sidecars; MKV stream embedding is deferred because it rewrites large files.

Metadata changes in the first release are standards-based sidecars rather than
in-place media rewrites: Jellyfin-compatible NFO for video/music and OPF for
books/audiobooks. Unknown release years are omitted; the conversion year is
never substituted. Subtitle installs accept validated UTF-8 SRT, WebVTT, or
ASS uploads and an optional OpenSubtitles API adapter. Both workflows use
private staging and atomic, no-overwrite installation. OpenSubtitles searches
use a contained, read-only local file descriptor to calculate the provider's
first/last-64-KiB movie hash. Exact file matches are returned first; only an
empty exact search falls back to the derived or editor-supplied title. Media
contents are never uploaded during this lookup.

Manual refresh is a closed, coalescing adapter surface available to every
authenticated user. The unprivileged web process may only enqueue fixed
integration identifiers and exposes the request's durable queued, running,
succeeded, or failed state. A separate hardened dispatcher follows the current
Jellyfin scheduled-task result, Audiobookshelf scan tasks and `lastScan`
timestamps, Kavita library `LastScanned` timestamps, or Syncthing scan response
before recording a terminal result. It cannot execute user-supplied commands.
The Kavita adapter runs as the `kavita` account, mints a five-minute HS512
service token from Kavita's existing application token key, sends it only to the
loopback API, requests a scan of all registered libraries, and does not report
success until every library's stored scan timestamp advances. This keeps the
adapter independent of OIDC-only human admin roles without creating another
long-lived credential. Kavita has no public scan-job status endpoint; the
persisted timestamp is the adapter's completion boundary, and removal of a
baseline library is a terminal failure rather than a two-hour wait.

The catalog performs a one-time lazy reconciliation when an authenticated user
first reads a visible shared or personal root. A durable per-root and per-owner
scan marker distinguishes an empty but already scanned directory from a new
catalog. Concurrent first reads of the same root are serialized and re-check
that marker before walking the filesystem. Explicit editor scans remain
available for later reconciliation.

## Consequences

- The service can run when Jellyfin, Audiobookshelf, Kavita, Syncthing, or
  MKVMaker are disabled.
- Cross-library moves require a typed semantic operation and consumer-impact
  report instead of path manipulation.
- The dedicated mutation broker can be disabled without affecting conversion
  visibility or catalog inspection.
- Application refreshes remain usable from a viewer session without granting
  staged filesystem mutation rights, and duplicate in-flight requests for the
  same application are coalesced.
- The broker expires abandoned previews and deletes only fingerprint-bound
  private staging files, making cleanup retryable after a process interruption.
- State is centrally persisted and included in logical SQLite backups.
- Public Cloudflare ingress is intentionally absent; private DNS and the shared
  authentication gateway are required.

## Rejected alternatives

- Running the web application as root or granting it filesystem capabilities.
- Allowing arbitrary source/destination paths from the browser.
- Trusting direct public access or a per-application OAuth sidecar.
- Automatically accepting provider matches or overwriting existing subtitles.
