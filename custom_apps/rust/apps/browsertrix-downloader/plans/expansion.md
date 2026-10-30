# Web Archives implementation plan

Status: implemented and validated on `feature/web-archives-expansion`.
Baseline: `ff550b82549c`. Live activation belongs to the deployment coordinator.

Independent plan review: one read-only pass at `13cb1b6`. Findings
WA-PLAN-01 through WA-PLAN-10 are accepted; the binding corrections below
supersede the corresponding initial sketches. The validation receipt records
implementation evidence and subsequent independent review dispositions.

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

Integration prerequisite repair: the maintained directory-claim helper gains an
optional exact-scope `release DIR...`. It keeps unfinished work under the same
owner, refuses dirty released scopes, holds the existing operation lock and
updates holder requests atomically. A dependency handoff reproduced the existing
all-or-nothing release deadlock. Independent review and the focused ownership
suite precede its use; no installed runtime is changed. For the regex manifest
window, the backend writer may acquire the app parent and `@shared-files`
together after the other holders release, preserving its unfinished source.
It then validates and commits the dependency input in its assigned checkout.

## Feature and acceptance ledger

Module review at `514cf7c` found WA-MOD-001 through WA-MOD-003. Corrections
accepted at `d1c1b15` by module review round 2: remove Search's service-group
membership and retain its narrow shared-tree ACL; add the private root to actual Kopia snapshot roots with a
scoped policy that includes WACZ while preserving model exclusions; mount the
profile root inaccessible in the API namespace. The two focused module checks
pass. An isolated Kopia 0.23.1 repository restored the 54,088-byte synthetic WACZ
byte-for-byte under that policy while excluding a synthetic GGUF. No live backup
or credential store was used.

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
   material. Page/byte/time limits are cumulative; native attempts receive only the
   remaining time, with accumulated runtime reported. An interrupted attempt
   conservatively charges its persisted deadline to prevent restart budget resets.
   This tightens the initial per-attempt time sketch after a reproduced pause/
   restart budget reset. `/resume` additionally accepts bounded
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
  sizeLimitBytes?: number | null;
  maxResourceBytes?: number | null;
  diskReserveBytes: number;
  selectors: SelectorRule[];
  profileId?: string;
  deduplicate: boolean;
  alternateImages: boolean;
  interactions: { selector: string; assertion: 'visible' | 'hidden' | 'text'; expected: string }[];
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
Explicit JSON null disables optional byte thresholds; omission retains defaults.
Pause/stop apply to capture, sample and repair operations. File operations reject
those controls with 409 and cancellation guidance; packaging is noncancellable.

`POST /api/preflight` takes the same capture request and returns:

```typescript
type Estimate = {
  measured: boolean;
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
`{ items: ArchiveSummary[], total, offset, limit }`. Summaries contain metadata
and counts only; full page/resource inventories never appear in polling lists.

```typescript
type Archive = {
  id: string; createdAt: string; updatedAt: string; createdBy: string;
  url: string; title: string; archiveFile: string; archiveBytes: number;
  sha256: string; tags: string[]; collection: string; favorite: boolean;
  notes: string; trashed: boolean; parentId?: string;
  captureStatus: 'complete' | 'partial' | 'imported' | 'derived' | 'repair';
  stopReason?: string; request?: CreateJobRequest;
  report?: { uniquePayloadBytes: number; duplicatePayloadBytes: number;
             metadataBytes: number; warnings: string[] };
  verification?: Verification;
  cleanRules: SelectorRule[]; dependencies: string[];
};
```

- `GET /api/archives/:id` returns Archive. `PATCH` edits title, tags, collection,
  favorite, notes and cleanRules only. `DELETE` moves metadata to restorable
  trash; `POST /restore` restores. No permanent deletion in this release.
- `GET /api/archives/:id/wacz` serves defensive byte ranges, `?download=1` attachment.
- `GET /api/archives/:id/replay.json` serves the authorized hash-bound Multi-WACZ
  manifest; `/replay` remains an alias. The pinned viewer requires the JSON suffix.
- `GET /api/archives/:id/pages?q=&offset=&limit=` returns paginated PageRecord.
- `GET /api/archives/:id/coverage?offset=&limit=` returns bounded persisted
  skipped-page, intentional-resource-omission and captured-HTTP-error receipts.
- `GET /api/archives/:id/resources?…` returns paginated ResourceRecord with
  `q`, `mime` and `domain` filters.
- `POST /api/archives/:id/verify` starts/records bounded fixity/offline QA. Return
  explicit pending/unsupported dimensions; never fabricate successful QA.
- `POST /api/archives/:id/repair` accepts `{ urls: string[] }` and returns jobId.
- `POST /api/archives/:id/export` accepts ExportOptions and returns a newly
  queued worker job (`jobId`); the completed job identifies the new derivative.
  Reader exports use the separate read endpoint.
- `GET /api/archives/:id/compare?other=ID` returns ComparisonReport.
- `GET /api/archives/:id/preview?url=…` serves an isolated, sanitized element
  selection preview; no original script runs in the app's authenticated origin.
- `GET /api/archives/:id/reader?format=markdown|html` exports captured readable
  content. Reader output clearly identifies source and capture timestamp. The API
  caps output at 8 MiB before allocation, retains analysis permits through body
  consumption, and directs larger exports to standalone WACZ. Pure worker-side
  engine limits are separately documented in the engine README.
- `POST /api/archives/import?filename=NAME` accepts bounded raw WACZ bytes.
  Uploads stream into exclusive staging; the WACZ cap is 128 MiB and profile
  material cap is 32 MiB.
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

Migrations are additive, but old binaries cannot read expanded scope/status
values. The explicit `browsertrix-downloader-legacy-export SOURCE_DB NEW_DB`
maintenance tool preserves the newer source and exports only compatible completed
shared standalone history to an exclusive private database. All incompatible,
private, dependent and unfinished work remains parked. Retain the new Nix
private-storage boundary and do not enable an old worker against profile data.
Never roll a newer database back by deleting data. Preserve backup/persistence/
authentication boundaries and the default compute allocation.

## Integration evidence (current checkpoints)

All 30 proposals above are implemented. The integrated Rust gate passed 69 tests;
all five opt-in checks were executed with actual fixtures/runtime. Frontend checks
passed 13 tests, typecheck and production replay staging. The following evidence
and the validation receipt define the tested boundaries.

| Proposals | Implemented boundary | Observed qualification |
| --- | --- | --- |
| 01, 04, 05, 22, 27, 29 | Separate catalogue, owner-bound publication intent/recovery, paged inventories/coverage, metadata, imports, trash | Real API imported the 18-resource fixture; paging, metadata, fixity and export completed. Removing all terminal job history preserved the archive and its SHA-256. Other-user detail, payload, preview and mutation requests returned 404. |
| 02, 03, 09, 11 | Durable native checkpoints, explicit cumulative budgets/extensions, SPA/depth and multiple seeds | Actual native partial one-page capture resumed with an explicit two-page extension and completed all three pages in two attempts and 14 cumulative seconds. The partial hash and parent lineage remained intact. Restart/discard and unsupported file-control races passed independent backend review. |
| 07, 08 | DNS-pinned bounded discovery and queued browser samples | Actual 3-page sample freezes target 30. Projection includes document/assets once and reports uncertain dynamic-resource, baseline and packaging overhead separately; transfer remains a different measurement. |
| 10, 12, 13, 14, 23, 25 | Editable presets, native resource/media/behaviour driver, owner recipes and opt-in schedules | Existing app tests and direct recipe/schedule execution checks pass. Fixture UI preserves SPA hashes, multiple seeds and editable settings. |
| 06, 15, 16, 17, 21, 24 | Library-first UI, resource/coverage tools, sandbox picker, clean replay, search/deep links and comparisons | Frontend review rounds 1–2 resolved WA-FE-001–003; round 3 qualified first-use replay/report guards and identified coverage retry. Correction `410d9f1` passed direct initial-load/next-page failure-and-retry browser checks. Real original → clean → original preserved story/hash and toggled advert display; mobile width 390 had no page overflow and footer remained reachable. |
| 18, 20, 26, 28 | Streamed WACZ transforms, repair composition, hash-authorized dependencies, standalone and Reader exports | 335,577,660-byte fixture with five 64 MiB bodies completed inspect/export/fixity/source-preservation/preview/Reader at 15,872 KiB peak RSS (debug run 1,220.6 s). Final text/view refinements passed focused checks separately. Three MiB inline-JSON HTML retains records/native rendered baseline; DOM transforms explicitly refuse their 2 MiB limit. Source/dependency hashes and graphs are checked for pure views too. |
| 19 | Queued native offline browser QA, separate file/resource/baseline/interaction results | Pinned 1.14.3 with `--network=none --pull=never`: 3/3 pages, screenshots and text passed, zero changed/missing resources. Separate two menu/tab assertions passed. Intentionally removing a captured favicon produced the expected exact resource-fidelity failure while page/baseline/assertion checks passed; captured original HTTP 404 remains distinguishable. |
| 30 | Immutable selected profile, fresh browser state, private roots and revocation checks | Synthetic sequential Alice, Bob and unprofiled captures returned their own cookie/storage values or empty state. Revoked/expired queued profiles failed before container launch; concurrent import cannot undo revocation. No live credential material was used. |

Engine file operations have explicit format/resource ceilings, documented in
[`archive_engine/README.md`](../archive_engine/README.md). Large-file success does
not establish a benchmark at the maximum configured ceiling. Picker/Reader are
bounded views, and forecasts remain heuristic ranges for a bounded recipe.
Independent module review accepted private ACLs, actual backup-root policy and
API profile mounts; isolated Kopia restored a synthetic WACZ byte-for-byte while
excluding a synthetic GGUF. No live service switch or real credential change has
been performed by this workstream.

The [validation receipt](validation.md) records actual native, API, replay,
network-boundary and resource-use evidence, including failures and their scope.
