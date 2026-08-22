# Media metadata observation and propagation

- Status: accepted
- Date: 2026-08-22

## Context

Media files, portable sidecars, and each consuming application can disagree
about descriptive metadata and subtitle state. A form populated with one
merged value hides those disagreements, makes accidental replacement likely,
and cannot explain whether a change will affect Jellyfin, Audiobookshelf, or
Kavita. Jellyfin already provides mature native metadata identification and
subtitle administration, while Audiobookshelf and Kavita have their own
metadata models and refresh behavior.

Media Manager needs to make cross-application state inspectable and to
coordinate portable changes without becoming a second implementation of each
application's administration interface. Application databases are private
implementation details and may be live or version-dependent.

## Decision

The metadata API returns independent observations rather than presenting the
merged value as the only truth. Observations may come from the filename, a
contained NFO or OPF sidecar, embedded EPUB package metadata, root-level
ComicInfo.xml, bounded plain PDF XMP, audio tags, or a short-lived application
snapshot. Every observation states where it is stored, which application
consumes it, whether it survives a rescan, whether it is locked, and whether it
is writable. The response also identifies the effective source for each field,
reports metadata-health findings, and separates portable-file from app-local
modification targets.

Application observations are produced by hardened, root-run exporters that
query loopback application APIs. Exporters remove absolute paths, reject
unowned personal paths, bound response size and entry counts, stamp an
observation time, and atomically publish group-readable caches. The web service
accepts only fresh schema-versioned snapshots and matches them against a
registered root, owner, and exact item path or bounded parent folder. It never
opens the Audiobookshelf or Kavita databases for metadata inspection. Kavita's
database remains read-only only in the existing refresh adapter where its API
does not expose scan completion.

The editor opens in inspection mode. Creating a draft explicitly unlocks the
form. Existing NFO and OPF sidecars are parsed before editing; a replacement
updates Media Manager's owned fields while preserving unknown elements,
attributes, comments, and package content. Confirmation archives the original
under the adjacent `superseded` directory and installs the fingerprint-bound
replacement with no-overwrite broker operations. EPUB and CBZ edits rebuild a
bounded ZIP container, copy every non-metadata entry verbatim, preserve unknown
metadata XML and package structure, parse the staged result, and use the same
recoverable broker boundary. PDF XMP and CBR remain inspection-only because a
lossless bounded writer is not available.

Audiobookshelf and Kavita application snapshots include richer media-specific
state: audiobook tracks, chapters, ebook presence, tags and explicit flags;
and Kavita people, genres, tags, language, age/publication status, provider IDs,
and per-field locks. Manual application refresh does not report success until
the corresponding observation export has also completed, so refresh-and-verify
cannot immediately reload a stale snapshot. App-local modification targets
open the native application editor instead of duplicating provider matchers,
chapter editors, feed administration, or application-only lock semantics.

Podcasts are a separate reserved library category and media type with shared
and personal roots. They are intentionally not treated as audiobooks.
Audiobookshelf podcast snapshots and embedded episode tags can be inspected;
native feed and episode editing remains in Audiobookshelf, and portable podcast
tag writes remain disabled until they can be performed without losing
format-specific fields.

After a confirmed write, clients can query the owning plan's durable state.
Once it is complete they may request the existing typed application refresh,
wait for its terminal result, and query observations again. This is the
verification boundary: a successful file write alone does not claim that an
application has consumed the change.

Subtitle inspection lists both contained external sidecars and bounded
ffprobe/Jellyfin embedded-stream observations. SRT, WebVTT, and ASS sidecars
can be previewed as cues with overlap, invalid-duration, and reading-speed
issues. Media Manager continues to offer portable sidecar search, upload, and
validation. It links to Jellyfin for native subtitle upload/removal and item
identification instead of duplicating those mature workflows.

## Consequences

- Users can see conflicts and provenance before editing instead of inferring
  them from a pre-filled form.
- Application data is eventually consistent and may be absent when an
  exporter is stale or an optional app is disabled; filename and sidecar
  observations still work.
- Metadata propagation is an explicit write, refresh, observation-export, and
  re-query sequence.
- Existing sidecar edits create recoverable archive files and therefore use
  additional storage until an operator deliberately cleans old revisions.
- Portable metadata remains the preferred cross-application write surface.
  EPUB and CBZ have format-aware writers; PDF, CBR, and podcast audio remain
  read-only.
- Jellyfin remains the authoritative native interface for provider
  identification and destructive subtitle administration.

## Rejected alternatives

- Reading Jellyfin, Audiobookshelf, or Kavita metadata directly from their
  SQLite databases. This couples Media Manager to live private schemas and
  bypasses application authorization and normalization.
- Rebuilding Jellyfin's metadata identification and subtitle administration
  screens. This would duplicate provider logic and destructive operations
  without improving portability.
- Treating the merged metadata object as a single source of truth. It hides
  disagreements and makes post-refresh verification impossible.
- Overwriting an existing sidecar in place. It loses unrecognized metadata and
  provides no recoverable original if installation is interrupted.
