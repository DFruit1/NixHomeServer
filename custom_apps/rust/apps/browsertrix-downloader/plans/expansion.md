# Web Archives implementation plan

Status: implementation in progress. Baseline: `ff550b82549c`.

Independent plan review: one read-only pass at `13cb1b6`. Findings
WA-PLAN-01 through WA-PLAN-10 are accepted; the binding corrections below
supersede the corresponding initial sketches. Implementation acceptance still
requires evidence against these corrections.

The owner requested implementation of the complete 30-feature review, delegated
work, integration and application-level verification. This document is the scope
and acceptance ledger. A control, empty endpoint, mocked result or documented
future intention does not count as an implemented capability.

## Design decisions

- Retain Browsertrix Crawler 1.14.3 and ReplayWeb.page. Extend the existing Rust
  application and Qwik frontend; use the workspace's pinned dependencies.
- Keep archives independent of disposable jobs. Archive IDs, ownership, file
  hashes, provenance and parent/repair relationships survive history cleanup.
- Preserve existing HTTP clients: existing job endpoints and error shape
  `{ "error": "message" }` remain. New fields have defaults; new paginated
  endpoints use `{ items, total, offset, limit }`.
- Keep captured originals immutable. Cleaning, repair and compact export create
  a view or a derivative. Never equate hidden DOM with unused resources.
- Keep WACZ's random access: gzip-compressed WARC and CDX members use ZIP STORE;
  changes to WARC records require new byte offsets, indexes and manifest hashes.
- Estimate a bounded capture recipe, not an unknowable entire dynamic website.
  Report unknown scope and separate transfer bytes, stored bytes and peak disk.
- New scheduled captures are opt-in application data, not agent automations.
  No live schedules, credential values, exposure changes or deployments are
  introduced by this implementation session.
- Archive parsing is untrusted-input handling. Bound ZIP entry count, inflated
  bytes, record sizes, JSONL count, and previews. No archive member is extracted
  by a user-controlled filesystem path. Preserve per-user authorization on every
  archive, recipe, schedule, profile and derivative endpoint.

## Delegation and dependency order

1. Integration owner commits this plan, API contract and dependency wiring.
2. Three isolated worktrees implement disjoint directories concurrently:
   backend (`src/`, `tests/`), archive engine (`archive_engine/`), and frontend
   (`frontend/`). No agent edits another writer's directory or pushes.
3. Integrate archive engine, backend and frontend commits. Resolve contract
   mismatches and complete cross-cutting service/Search wiring in the parent.
4. Independently review the exact integrated range. Resolve required findings
   in at most three ordinary rounds, with new delegated review tasks per round.
5. Run all Web Archives Rust/frontend tests, relevant module checks and an
   isolated capture/replay browser exercise. Check desktop and mobile behavior.
6. Commit and push the validated feature branch. Activation remains governed by
   the existing deployment gate.

Each writer uses `scripts/hermes/directory_claims.py --repo "$PWD" --owner LABEL`
when the installed helper is absent, inspects existing claims, claims only its
assigned directories, and releases after its validated local commit. Shared
integration files require the existing `@shared-files` claim. Parent/child
claims conflict even across isolated worktrees.

## Feature and acceptance ledger

| ID | Capability | Implementation and acceptance |
| --- | --- | --- |
| 01 | Durable archive library | Separate archive catalog; clearing/removing terminal jobs leaves stable replay, download and metadata available. Migrate existing completed jobs without losing ownership. |
| 02 | Partial capture and resume | Distinguish pause, stop-and-save and discard. Retain partial WACZ/checkpoints on expected limits and restart; resume the same recipe without overwriting retained state. |
| 03 | Scope and SPA routes | Configurable depth, page-spa and selected seeds; show exact host/path scope. Preserve routing hashes while ordinary fragments remain deduplicated. |
| 04 | Coverage and stop reasons | Capture page/resource inventories, failure/exclusion reasons, remaining work and actual crawler stop reason. Packaging, partial capture and verification are distinct states. |
| 05 | Validated atomic publication | Validate ZIP structure, manifests and indexes before publication. Destination staging, flush, rename and catalog reconciliation survive interruption without exposing half-written archives. |
| 06 | Reliable accessible UI | Validate HTTP status/response shape, retain stale data visibly, report per-action errors, prevent duplicate actions, and support keyboard, status announcements, reduced motion and touch targets. |
| 07 | Bounded preflight | Public-address-safe bounded sitemap/link discovery, page-template groups and traps/unknown-scope warnings. Its own time/byte/page budget is enforced. |
| 08 | Sample size forecasts | Estimate shared/marginal stored bytes from representative browser captures and relevant history. Return a range, sample count, assumptions and unknowns; update from measured actual size. |
| 09 | Byte/disk budgets | Enforce WARC size threshold and scratch/destination headroom, with media/resource bounds where supported; retain partial work and explain any packaging/active-request overshoot. |
| 10 | Capture presets | Faithful default; explicit Balanced and Reader settings, each editable. Show changed blocking, interaction and media choices. Reader exports identify themselves as derivatives. |
| 11 | Page selection | Multiple seeds, path/query inclusion/exclusion and rule previews; page scope stays independent of asset dependencies. |
| 12 | Ads and trackers | Upstream ad blocking plus per-resource/domain rules and allowlist exceptions. Freeze selected rules in capture provenance and report intentional omissions. |
| 13 | Media/variants | Full/poster/no-media choices and explicit autofetch/autoplay/alternate-image policy. Explain fidelity tradeoffs and report measured stored bytes. |
| 14 | Behaviour editor | Bounded scrolling, clicking and load-more, selector rules, load delays, behavior timeout, language and viewport. Replay selected menus/tabs without live-site access. |
| 15 | Resource inspector | Inspect resources by URL, MIME, domain, status, digest and stored size; distinguish unique storage, transfer and shared page attribution. Totals reconcile with file bytes. |
| 16 | Visual element selection | Isolated archived-page preview; choose scoped CSS selectors with matched elements and reversible rules. Map/request dependencies conservatively, never claim all hidden content is unused. |
| 17 | Clean replay | Save replay-only display rules and allow original/clean switching without changing original file hashes; make zero stored-byte savings explicit. |
| 18 | Compact WACZ export | New validated, independently replayable derivative with selected pages/resources, dependency closure, rebuilt WARC indexes/hashes and an omission/provenance report; preserve the source. |
| 19 | Offline QA | Upstream crawl/replay screenshot/text/resource checks plus selected interaction checks with live traffic unavailable. Persist results, scope, timestamp and untested dimensions. |
| 20 | Targeted repair | Select failed/missing URLs for bounded recapture; produce a timestamped repair version and preserve the original. Open the repaired archive without a full recrawl. |
| 21 | Archive search/deep links | Search captured titles/text and open the matching original URL and capture time in replay; reuse existing global Search extraction where possible. |
| 22 | Library organisation | Server-side paging/filtering/sorting, title/tags/collection/favorite/notes and selected-archive details. Find archives beyond the first 100 jobs; keep active work above Kiwix. |
| 23 | Recipes/batches | Versioned owner-scoped reusable recipes and bounded multi-seed/batch submission with exact software/settings provenance. |
| 24 | Timeline/diffs | Group captures by source host and compare pages/text/resources; distinguish missing coverage from website changes and retain links to both snapshots. |
| 25 | Scheduled updates | Owner-scoped opt-in interval schedules processed by the existing worker with explicit budgets, duplicate prevention and persistent last-run results; disabling prevents future runs. |
| 26 | Cross-capture dedupe | Reduce repeated snapshot storage with explicit archive dependencies, dependency-aware replay and retention; self-contained export resolves references. Do not skip all resources because HTML is unchanged. |
| 27 | Import/reconciliation | Validate bounded WACZ uploads, deduplicate exact imports by hash and reconcile retained files without guessing another user's ownership. Imported archives work without recapture. |
| 28 | Offline/reader exports | Download standalone WACZ and readable Markdown/HTML export; identify fidelity limits and verify the output with the server unavailable. Browser pinning, when offered, reports quota/completion/eviction. |
| 29 | Integrity/retention | Persist fixity check results, preview reclaimable bytes/dependencies and use restorable trash. History cleanup never deletes files; no automatic irreversible deletion. |
| 30 | Private capture profiles | Isolated owner-scoped profile references and import/use lifecycle; no credentials in recipes, logs or other users' responses. Verify isolation with synthetic profile data; no live credential operations. |

## Shared HTTP contract

### Binding corrections from independent review

1. **Publication custody (WA-PLAN-01):** Before any published payload, persist an
   intent containing owner, destination, source job, expected hash and visibility.
   Allocate staging/destination names exclusively, fsync file and containing
   directory, finalize the catalogue idempotently, then remove scratch. Recovery
   completes known intents; legacy files without ownership evidence stay unclaimed.
2. **Durable resume (WA-PLAN-02):** Save periodic checkpoints and resumable WARC
   material in a persistent worker-owned checkpoint directory under stateRoot,
   rather than relying on disposable cache. Atomic state transitions prevent two
   attempts resuming together. Resume never passes --overwrite or deletes saved
   material. Page/byte limits are cumulative; time is bounded per attempt with
   accumulated runtime reported. `/resume` additionally accepts bounded
   `additionalPages`, `additionalMinutes`, `additionalBytes`; an exhausted budget
   without an explicit valid extension returns a useful conflict. A published
   partial version remains immutable while the next attempt resumes its checkpoint.
3. **Network boundary (WA-PLAN-03):** API discovery uses a dedicated fetcher with
   proxies disabled, automatic redirects disabled, all resolved addresses checked,
   validated addresses pinned through the actual connection, and every redirect
   revalidated. Bound inflated bytes, URL count, sitemap recursion and total time.
   Browser sampling runs as a queued worker operation behind the existing egress
   firewall, never an unrestricted API-side browser. Add `POST /api/samples`
   returning jobId; completed samples expose a measured estimate. Profile-backed
   discovery/samples also run through this worker boundary.
4. **Profile lifecycle (WA-PLAN-04):** `POST /api/profiles/import?name=NAME` accepts
   bounded raw profile archive bytes into private staging and queues validation.
   Reject absolute/traversing paths, symlinks/hardlinks/devices, excessive entry
   count and inflated size before upstream tar sees the archive. Store immutable
   accepted material with a digest; mount only the selected profile read-only and
   use fresh writable browser state per attempt. Recheck owner, expiry, revocation
   and digest at execution for captures/samples/repairs/resumes/schedules. Fail
   closed on loading failure. No live profile is created during validation.
5. **Private visibility (WA-PLAN-05):** Existing shared captures keep their current
   access. Every profile-backed capture and its descendants are private, stored
   outside the shared archive tree and global Search consumers. A private
   data-pool root is accessible only to the API/worker service identities, with
   explicit backup inclusion. Profile data stays in private persistent state.
   No automatic promotion from private to shared is offered.
6. **Dedupe identity (WA-PLAN-06):** Dependency inputs are `(archiveId, sha256,
   authorizedLocalPath)` from the same owner and visibility. Resolve missing,
   changed or cyclic dependencies before replay/export. Record identity includes
   target URL, WARC date, record ID, request distinctions and archive/WARC location;
   URL alone is insufficient. Add engine operations for deduplication and
   standalone materialization with an explicit authorized dependency set. Serve
   a Multi-WACZ manifest at `/api/archives/:id/replay` with authorized hash-bound
   sources; its use must be validated against the pinned replay viewer. Standalone
   export must replay with parent sources unavailable.
7. **Repair composition (WA-PLAN-07):** Repair jobs carry parent ID/hash, selected
   targets, frozen recipe and budgets. Materialize a new complete derivative with
   untouched parent records plus successful repair records. Prefer repaired
   responses for selected targets via an explicit replay/index selection policy,
   while preserving their actual WARC dates and documenting mixed-time provenance.
   A patch-only capture is not a completed repair feature.
8. **Fixity versus browser QA (WA-PLAN-08):** File-only verification reports fixity
   separately. New captures record `--screenshot view` and `--text
   to-pages,to-warc,final-to-warc` for comparable baselines. Queue browser QA using
   the pinned crawler, with selected interaction steps and observable assertions.
   Live origins must be unavailable even through service workers; archive delivery
   remains allowed. Missing legacy baselines and unavailable browser execution
   produce `not-run` checks, never inferred passes. The API `verify` action may
   return `{jobId}` for asynchronous work. Archive mutations (exports/imports/QA)
   are queued to the writer worker; the API retains read-only payload access.
9. **Bounded responses (WA-PLAN-09):** Archive list rows contain summaries only:
   metadata, counts, size and verification summary. Detailed report inventories
   live behind paginated endpoints. Persist large reports separately, bound parse
   memory and response bytes, and do not serialize all captured text in polling.
10. **Rollback (WA-PLAN-10):** Previous binaries cannot read expanded states/scopes.
    Rollback preserves the new database and parks newer work; use the maintained
    compatible fallback binary or an explicit export of legacy-compatible records
    into a separate rollback database. Never point old binaries at expanded rows
    and never delete the new database to make rollback appear successful.

All JSON uses camelCase. User identity continues to come only from the trusted
auth gateway. Same-origin JSON checks protect every mutation. IDs are opaque safe
path segments. Unknown or inaccessible records return 404. Pagination defaults to
50, caps at 100; offset is nonnegative. Search/filtering applies before paging.

### Capture

`POST /api/jobs` retains the existing request fields and adds optional `options`:

```typescript
type CaptureOptions = {
  preset: 'faithful' | 'balanced' | 'reader';
  depth: number; // -1 means bounded only by other limits; page always depth 0
  seeds: string[];
  include: string[]; exclude: string[]; // page URL regexes
  blockAds: boolean;
  blockRules: string[]; allowRules: string[]; // resource URL patterns
  media: 'full' | 'posters' | 'none';
  behaviors: string[]; // autoscroll, autoplay, autofetch, autoclick, siteSpecific
  clickSelector: string;
  behaviorTimeoutSeconds: number;
  postLoadDelaySeconds: number;
  viewportWidth: number; viewportHeight: number; language: string;
  sizeLimitBytes?: number;
  maxResourceBytes?: number;
  diskReserveBytes: number;
  selectors: SelectorRule[];
  profileId?: string;
  deduplicate: boolean;
};
type SelectorRule = {
  selector: string; action: 'hide' | 'block'; urlPrefix?: string;
};
```

Old stored requests deserialize with defaults. `scope` additionally permits
`page-spa` and `domain`. `POST /api/jobs/:id/pause`, `/stop`, `/resume` use `{}`;
`/cancel` is retained with explicit discard semantics. Added job states are
`paused`, `partial`, `packaging`. Jobs expose optional `archiveId`, `stopReason`,
`bytesDownloaded`, `bytesStored`, `canResume`, `coverage` and `estimate`.

`POST /api/preflight` takes the same capture request and returns:

```typescript
type Estimate = {
  lowerBytes: number; upperBytes: number; expectedBytes: number;
  samplePages: number; discoveredPages: number; unknownScope: boolean;
  sharedBytes: number; marginalPageBytes: number; peakDiskBytes: number;
  assumptions: string[]; warnings: string[];
};
type Preflight = {
  urls: string[]; groups: { prefix: string; pages: number }[];
  estimate: Estimate; warnings: string[];
};
```

Discovery alone is labelled a discovery estimate; only actual measured browser
samples may be called browser-sampled. Add an explicit sampling job if browser
capture cannot fit within the bounded request path. Never fetch private network
addresses through preflight, redirects, sitemaps, profiles or resource repair.

### Archives

`GET /api/archives?q=&offset=&limit=&sort=&favorite=&collection=&trashed=` returns
`{ items: Archive[], total, offset, limit }`.

```typescript
type Archive = {
  id: string; createdAt: string; updatedAt: string; createdBy: string;
  url: string; title: string; archiveFile: string; archiveBytes: number;
  sha256: string; tags: string[]; collection: string; favorite: boolean;
  notes: string; trashed: boolean; parentId?: string;
  captureStatus: 'complete' | 'partial' | 'imported' | 'derived' | 'repair';
  stopReason?: string; request?: CreateJobRequest;
  report?: ArchiveReport; verification?: Verification;
  cleanRules: SelectorRule[]; dependencies: string[];
};
```

- `GET /api/archives/:id` returns Archive. `PATCH` edits title, tags, collection,
  favorite, notes and cleanRules only. `DELETE` moves metadata to restorable
  trash; `POST /restore` restores. No permanent deletion in this release.
- `GET /api/archives/:id/wacz` serves defensive byte ranges, `?download=1` attachment.
- `GET /api/archives/:id/pages?q=&offset=&limit=` returns paginated PageRecord.
- `GET /api/archives/:id/resources?…` returns paginated ResourceRecord with
  `q`, `mime` and `domain` filters.
- `POST /api/archives/:id/verify` starts/records bounded fixity/offline QA. Return
  explicit pending/unsupported dimensions; never fabricate successful QA.
- `POST /api/archives/:id/repair` accepts `{ urls: string[] }` and returns jobId.
- `POST /api/archives/:id/export` accepts ExportOptions and returns a newly
  catalogued derivative (`archiveId`) or downloadable reading export URL.
- `GET /api/archives/:id/compare?other=ID` returns ComparisonReport.
- `GET /api/archives/:id/preview?url=…` serves an isolated, sanitized element
  selection preview; no original script runs in the app's authenticated origin.
- `GET /api/archives/:id/reader?format=markdown|html` exports captured readable
  content. Reader output clearly identifies source and capture timestamp.
- `POST /api/archives/import?filename=NAME` accepts bounded raw WACZ bytes.
  `POST /api/archives/reconcile` reports unclaimed files and restores only
  attributable records; explicit imports establish the importing user's copy.
- `GET /api/archives/search?q=` returns paginated matching captured pages with
  archiveId, URL, title, capture timestamp, snippet and replayUrl.

### Recipes, schedules and profiles

`GET/POST /api/recipes`, `GET/PATCH/DELETE /api/recipes/:id` store owner-scoped
`{ id, name, version, request, createdAt, updatedAt }`; version increments on edit.
`POST /api/recipes/:id/run` queues the frozen request.

`GET/POST /api/schedules`, `PATCH/DELETE /api/schedules/:id` store
`{ id, recipeId, intervalMinutes, enabled, nextRunAt, lastRunAt?, lastJobId?, lastError? }`.
Minimum interval 60 minutes. One due schedule produces at most one active job;
advancing it and recording its job is atomic. Nothing is enabled by default.

`GET/POST /api/profiles`, `DELETE /api/profiles/:id` expose owner-scoped
`{ id, name, createdAt, updatedAt, expiresAt?, available }`. Profile material is
imported as a bounded archive separately from JSON metadata and kept outside
exports/recipes/logs with restrictive permissions. No JSON response includes it.

## Archive engine contract

Keep pure/blocked file analysis in `archive_engine/`, imported by
`src/lib.rs` using `#[path = "../archive_engine/mod.rs"]` to allow an exclusive
feature-directory writer without creating a new service or workspace crate.
Use blocking-handler isolation or `spawn_blocking` for archive CPU/file work.

The engine owns serde-serializable camelCase structs and these public operations:

```rust
inspect_archive(path: &Path) -> Result<ArchiveReport, String>
verify_archive(path: &Path) -> Result<Verification, String>
export_archive(source: &Path, destination: &Path, options: &ExportOptions)
    -> Result<ArchiveReport, String>
compare_archives(left: &Path, right: &Path) -> Result<ComparisonReport, String>
reader_export(path: &Path, format: &str) -> Result<String, String>
preview_page(path: &Path, url: &str) -> Result<String, String>
estimate_size(samples: &[PageSample], discovered_pages: u64, page_limit: u32,
              unknown_scope: bool) -> Estimate
```

`ArchiveReport`: archiveBytes, sha256, title, description, pages (PageRecord),
resources (ResourceRecord), uniquePayloadBytes, duplicatePayloadBytes,
metadataBytes, warnings, dependencies.
`PageRecord`: url, title, ts, text, bytes, status, resourceUrls.
`ResourceRecord`: url, mime, status, bytes, digest, domain, pages.
`Verification`: valid, checkedAt, checks (`{ name, status, details }`), warnings.
`ExportOptions`: includeUrls, excludeUrls, excludeDomains, excludeMimePrefixes,
removeSelectors, title, deduplicate (all lists/defaults optional).
`ComparisonReport`: addedPages, removedPages, changedPages, unchangedPages,
addedResources, removedResources, changedResources, warnings.
`PageSample`: url, bytes, sharedBytes, resourceDigests (digest -> stored bytes),
measured (bool).

Any necessary contract correction is recorded here and communicated before the
other writers depend on it. Export must not drop shared resources merely because
one excluded page referenced them. Revisit dependencies must be retained or
resolved into a standalone output. Unsupported transformations must fail clearly
and leave originals intact, rather than falsely reporting a compact export.

## Verification and rollout

The user explicitly requested testing the complete application. Run the owning
Rust integration tests and frontend check, then browser journeys against the real
API with isolated state, WACZ fixtures and the actual crawler when available.
Cover URL/preflight/settings -> capture -> library -> replay -> cleanup/export,
pause/limits/resume, history cleanup, paging, metadata, import, comparisons,
schedules and profile ownership. Inspect 1280px and 390px layouts and last-control
reachability. Offline replay must block live origins, not merely disconnect the
browser from the API that supplies the archive.

New automated regression coverage is justified specifically for archive loss on
interruption, corrupt/partial publication, unsafe imported paths/ZIP inflation,
cross-user archive/profile disclosure and derived-export corruption. Other
features use existing checks and direct isolated acceptance exercises. Record
actual commands, fixture/crawler versions, measured output sizes, failures and
unverified dimensions in a final validation receipt beside this plan.

Migrations are additive. Rollback uses the previous committed binaries and
retained originals; do not roll a newer database back by deleting data. Preserve
backup/persistence/authentication boundaries and the default compute allocation.
