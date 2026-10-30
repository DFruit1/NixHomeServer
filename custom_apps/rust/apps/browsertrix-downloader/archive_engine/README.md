# Archive engine integration

Call CPU/file operations on the writer worker or `spawn_blocking`, with owner
checks in the caller. Public original types and seven operations retain the plan
contract. `verify_archive` is file fixity only: browser QA dimensions are
`not-run`, and unresolved revisits do not qualify as standalone verification.

Bounds: 32 GiB archive files, 64 GiB total ZIP inflation and a separate
64 GiB total WARC inflation budget; record bodies up to 2 GiB plus 64 KiB
HTTP allowance; at most 128 records and 2 GiB + 192 KiB inflation per gzip
member. Those ceilings cover the app's current maximum 16 GiB WARC capture
budget and 2 GiB resource budget. WARC members must use ZIP STORE for random
access. Bodies and manifest hashes stream in 64 KiB buffers; inventories keep
lazy source locations, not payloads. Source bytes are hash-checked before/after
inspection, and each lazily read body is checked against its scanned block hash.
A cumulative 256 GiB lazy reread budget prevents gzip seek amplification.

The bounded in-memory limits are 50,000 records/pages/index rows, 10,000 raw ZIP
members, 32 MiB central directory, 1,024-byte member paths, 64 KiB headers,
4 MiB manifest, 32 MiB each
for ZIP page/index metadata, combined WARC/HTTP header inventory, inflated CDX,
and extracted text/link inventory. Dependency metadata is capped at 256 MiB
across at most 16 explicitly authorized archives. Reader output is capped at
256 MiB. HTML analysis is limited to 2 MiB, 50,000 nodes and depth 128;
individual eager text/resource decoding is bounded at 32 MiB. Large binary
responses stay streamed through inspection, verification, dedupe, materialization
and export rather than going through the text decoder. ZIP64 STORE output is
written record by record to destination staging, then validated before publish.
Unsupported input layouts/encodings fail clearly; no member is extracted by an
archive-controlled path and no inventory is silently truncated.

Optional DOM/text analysis does not invalidate otherwise valid original records.
HTML above 2 MiB or beyond the DOM/decode/aggregate analysis bounds stays intact;
inspection reports omissions, retains bounded native page text/title, and keeps
asset closure conservative. Nonempty Browsertrix rendered text is authoritative
over response-HTML text. Native page IDs and nearest same-URL timestamps merge
subsecond response records without manufacturing duplicate page rows. Preview
and selector rewriting still refuse HTML beyond the explicit analysis bounds.
Export records optional analysis omissions in provenance; resource-to-page
attribution has a separate 32 MiB budget with explicit omissions, preserving all
resource inventory rows.

Storage fields count compressed gzip spans once, apportioned across records in
a shared member. Unique/duplicate bytes plus metadata bytes equal ZIP file bytes.
Decoded transfer sizes are not represented as stored sizes. HTML references
provide conservative page attribution; dynamic script dependencies are unknown.
SHA-256 manifest hashes are mandatory; legacy SHA-1 WARC digests are reported as
unverified, while actual payload SHA-256 is computed for inventories/dedupe.

Additive operations, reexported at module root:

```rust
AuthorizedDependency { archive_id: String, sha256: String,
                       authorized_local_path: PathBuf }
deduplicate_archive(source: &Path, destination: &Path,
                    dependencies: &[AuthorizedDependency]) -> Result<ArchiveReport, String>
materialize_archive(source: &Path, destination: &Path,
                    dependencies: &[AuthorizedDependency], options: &ExportOptions)
                    -> Result<ArchiveReport, String>
compose_repair(parent: &Path, repair: &Path, destination: &Path,
               dependencies: &[AuthorizedDependency], targets: &[String])
               -> Result<ArchiveReport, String>
preview_document(path: &Path, url: &str) -> Result<PreviewDocument, String>
reader_export_authorized(path: &Path, format: &str,
                         dependencies: &[AuthorizedDependency]) -> Result<String, String>
preview_document_authorized(path: &Path, url: &str,
                            dependencies: &[AuthorizedDependency]) -> Result<PreviewDocument, String>
compare_archives_authorized(left: &Path, left_dependencies: &[AuthorizedDependency],
                            right: &Path, right_dependencies: &[AuthorizedDependency])
                            -> Result<ComparisonReport, String>
PreviewDocument { html: String, content_security_policy: String }
```

The caller authorizes dependency paths against owner and visibility. Raw hex
SHA-256 is checked against the same snapshot parsed. Manifest ID/hash bindings,
missing dependencies, cycles and WARC reference identity are checked. Destinations
must not exist: output is staged exclusively, validated, fsynced and published
without overwriting. Failed transformations leave the source intact. Cross-capture
dedupe writes actual identical-payload revisits, keeping response headers and CDX
request distinctions. Standalone materialization resolves dependencies. Repair
replaces successful selected URLs in the derivative's index, retains other parent
records and patch assets, and records mixed-time provenance without altering dates.
Authorized reader/preview/comparison views use the same hash/graph checks and
lazy hydration, without temporary archive publication or payload writes. Legacy
signatures remain wrappers supplying empty dependency sets. Missing/changed
bindings fail closed, including when a source already has native page text.

The backend sends `preview_document.content_security_policy` as the exact HTTP
CSP header. It contains a random trusted-picker nonce and `sandbox allow-scripts`.
The frontend also sets iframe `sandbox="allow-scripts"` with no same-origin grant.
The preview uses HTML5 DOM parsing/serialization, removes archived scripts and
active navigation, retains layout/inline styles, inlines up to 1 MiB captured
linked CSS and 4 MiB raster images (512 KiB each). Its security boundary is the
opaque sandbox and default-deny CSP; it must never be hosted without those.
External CSS imports/backgrounds/fonts, active media and dynamic scripts are
blocked, so visual fidelity is bounded. No separate authenticated resource route
is required. The trusted picker sends only:

```js
{ type: 'web-archives:selection', selector, url, matches: 1 }
```

Selectors identify unique original DOM paths or IDs; they are computed before
removal. The parent checks `event.source`, `event.origin === 'null'`, exact URL,
selector length <=512 and finite bounded matches. `preview_page` remains the
plan's String-returning wrapper and embeds CSP in HTML, but the HTTP header and
iframe sandbox remain required. This picker is not full replay or browser QA.

Derived selector removal supports comma lists, tag/ID/class/attribute selectors,
descendants, child combinators and numeric `:nth-child`. Other syntax fails
explicitly. CSS removal applies only to a new export, never the original. All
non-page resources remain unless explicitly filtered; no byte savings are
inferred from hidden DOM. Resource exclusions and source hashes are in provenance.

`Estimate.measured` is additive, defaults false, and is true only when measured
samples exist. Discovery alone reports unknown bytes with upper/peak `u64::MAX`.
Unknown scope without a page bound is unbounded. Stored samples do not measure
transfer bytes; the forecast says so and describes its range/peak assumptions.

Risk tests cover import corruption, unsafe paths/inflation, immutable originals,
shared resource loss, unsupported transformations, revisit rehydration with the
parent unavailable, mixed-time repair, and archive-script exclusion from preview.
The opt-in ignored real-fixture check requires `WEB_ARCHIVES_FIXTURE` and is run
explicitly, rather than claiming a missing crawler fixture as successful coverage.
Actual Browsertrix 1.14.3 output (100,502 bytes, 3 pages, 15 resources) passed file
fixity and a selector-derived export (92,753 bytes), preserving URN screenshot/text
index keys. Static checks do not establish ReplayWeb.page browser correctness.

The corrected positive Browsertrix fixture (109,406 bytes, 3 pages, 18 resources)
also passed inspection/fixity, actual selector export and output validation.
The final derivative is 101,382 bytes (8,024 saved), retaining all 18 resources
while removing the advertisement DOM/text. The compact risk fixture measured
134,171 -> 4,045 bytes (130,126 saved); cross-capture payload dedupe measured
133,568 -> 4,646 bytes (128,922 saved), and standalone rehydration remained valid
after physically removing its parent fixture.
Focused risk checks cover a 3 MiB SPA response with native rendered text, native
subsecond baseline merging, 3,000 revisits, source mutation, and authorized views
with valid, missing, unbound and changed dependency inputs. A measured 320 MiB
binary fixture completed inspect/export/verify with 15,872 KiB peak RSS in the
debug test process (1,220.59 seconds); the output was 335,653,513 bytes, with the
source unchanged. This is bounded streaming evidence, not a throughput target
or a measurement at the 32 GiB ceiling. The per-record pipeline was exercised
before the final optional-text and authorized-view refinements.

The generated preview was rendered in an opaque sandbox with its exact HTTP CSP
in Chromium at 1280x800 and 390x844. Captured CSS/raster image rendered, one trusted
picker script remained, originally hidden panels stayed hidden, and selecting
the story delivered the documented message with origin `null`. The measured
mobile reload requested only the local wrapper and preview document; no live
origin requests occurred and no horizontal overflow appeared. The collaborative
preview snapshot timed out twice, so this bounded check used the repository's
Playwright CLI fallback. This checks the isolated picker, not full app browser
QA or independent acceptance of ReplayWeb.page integration.


The streaming implementation supersedes the initial 256 MiB archive/body
retention checkpoint. The qualified no-savings error remains exactly
`No matching response payloads in authorized captures`, also exported as
`NO_MATCHING_PAYLOADS`; callers may fall back only on that discriminator, after
all source/dependency validation has passed. Other errors remain fatal.

WARC/manifest SHA-256 supports hexadecimal and Base32 encodings; payloads are
hashed after HTTP transfer decoding, before content decoding. CDX digests,
capture timestamps and actual gzip spans are cross-checked. Original lookup keys
(including Browsertrix URN screenshots/text and request distinctions) are retained.
Compressed CDX requires a complete `.idx` mapping; each exact gzip block, lookup
key, optional digest and coverage are validated. The normal derivative uses
uncompressed `indexes/index.cdxj` as tested with the pinned replay viewer.

The many-revisit risk fixture exercises 3,000 matching payload references through
local dedupe and standalone materialization, guarding against quadratic resolver
cutoffs producing invalid outputs. Source-record lookup uses stable IDs or
URL/date tuples plus digest, transport and location checks; URL alone never
identifies a reference.

Engine review corrections (WA-ENG-001 through WA-ENG-004; WA-INT001):

- Raw ZIP/ZIP64 end records, directory byte/count bounds, raw duplicate names,
  local-header identities and member spans are checked before constructing the
  ZIP crate's allocating inventory. The ZIP reader constructs metadata from the
  same frozen directory snapshot, with payload bytes unavailable to its fallback
  end-record scanner. This adds at most 32 MiB plus 65,633 bytes for the frozen
  directory/footer, alongside the bounded crate inventory; it does not retain
  WARC payloads. Preflight names total at most 10,000 × 1,024 bytes and are dropped
  before crate construction. Normal ZIP64 end records and STORE output remain
  supported. Split/prefixed/trailing-junk archives, changing Unicode path
  overrides, non-UTF8 names and ambiguous nested end signatures in directory
  metadata are rejected explicitly. The layout reference is
  [PKWARE APPNOTE 6.3.10](https://pkware.cachefly.net/webdocs/casestudies/APPNOTE.TXT),
  sections 4.3 and 4.5.3.
- CDX keys must agree with the WARC URL and supported CDX method/requestBody
  distinction. Query sorting, `www`/numbered prefixes, default ports, fragment
  removal, native URNs and request-query decoding follow the crawler's pinned
  [warcio 2.4.11 implementation](https://github.com/webrecorder/warcio.js/blob/v2.4.11/src/lib/utils.ts).
  CDX and compressed block keys must be sorted for native range lookup. Valid
  original keys and request metadata remain unchanged on export.
- Repair composition publishes successful responses for replaced target URLs;
  later failed alternatives and their page metadata cannot shadow the repair.
  Failed-only targets keep their parent records. Other parent records, patch
  assets, actual capture dates and mixed-time provenance remain.
- Include-page selection uses actual page inventory rather than HTML MIME.
  Non-page HTML stays a resource. Embedded iframe/frame/object document closure
  is retained even when those documents also appear in page inventory. Scripts,
  event handlers, srcdoc and unavailable/bounded analysis retain page inventory
  conservatively. Explicit resource exclusions still apply and are recorded.
- Dependent output adds `datapackage.relation.requires` entries with
  `filename: <archive_id>.wacz` and `hash: sha256:<immutable hash>`, matching the
  backend's MultiWACZ resource names. The pinned viewer reads those filenames for
  dependency fallback:
  [wabac 2.27.2 WACZFile](https://github.com/webrecorder/wabac.js/blob/v2.27.2/src/wacz/waczfile.ts),
  [MultiWACZ lookup](https://github.com/webrecorder/wabac.js/blob/v2.27.2/src/wacz/multiwacz.ts).
  Imports require exact agreement with the engine's dependency ID/hash map;
  relations alone never authorize access or trigger a fetch. Legacy engine
  dependency manifests without relations remain inspectable/materializable with
  explicit authorized inputs and a standard-replay warning. Standalone output
  has no required dependencies.

Six focused risk regressions cover pre-allocation ZIP exhaustion/corruption,
lookup-key corruption, failed repair replacement, shared HTML resource loss and
unauthorized dependency relations, plus reader response-memory amplification.
The focused engine run passes 19 tests, with
the opt-in native test run separately. With the real 109,406-byte crawler fixture,
the corrected selector derivative is 101,464 bytes and retains all 18 resources.
With its older native parent, dedupe produces 53,334 bytes and authorized
materialization produces 101,675 bytes; verification and both original hashes
pass. Set `WEB_ARCHIVES_PARENT` alongside `WEB_ARCHIVES_FIXTURE` to include that
native-pair check in `archive_engine_real_crawler_derivative_corruption_check`.
These are file/engine checks. The integration owner performs the final native
ReplayWeb.page dependency replay and independent round-2 review on the committed
candidate. The prior 335,653,513-byte streaming measurement above was not rerun;
the payload pipeline and limits remain unchanged.

The additive API for a caller holding aggregate response-lifetime permits is:

```rust
pub fn reader_export_authorized_limited(
    path: &Path,
    format: &str,
    dependencies: &[AuthorizedDependency],
    max_output_bytes: usize,
) -> Result<String, String>;
```

It caps output at `min(max_output_bytes, 256 MiB)` and retained source/dependency
metadata plus optional text/link analysis at `min(max_output_bytes, 32 MiB)`.
Metadata accounting measures inventory bytes rather than allocator/RSS overhead;
loading can temporarily hold one additional archive under the ordinary per-file
limits before rejecting the aggregate. This is not a process-memory guarantee.
It checks the complete escaped HTML/Markdown output length before allocating the
response, then reserves exactly that length and writes directly, with no escaped
page-sized temporary or formatted duplicate. Archive inventories and report
resources are dropped before response allocation. Both text and framing count,
including the HTML footer. Limits return errors rather than truncating output.
The existing reader functions retain their signatures and legacy limits. The
backend must use the limited entry point with a small response cap and hold its
aggregate permit until the HTTP body is drained or dropped; engine output bounds
alone do not limit how many slow bodies the server retains. The regression checks
high-expansion native text, exact HTML/Markdown byte boundaries, aggregate
dependency metadata rejection, and original hash preservation.
