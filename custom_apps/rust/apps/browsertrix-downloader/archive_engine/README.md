# Archive engine integration

Call CPU/file operations on the writer worker or `spawn_blocking`, with owner
checks in the caller. Public original types and seven operations retain the plan
contract. `verify_archive` is file fixity only: browser QA dimensions are
`not-run`, and unresolved revisits do not qualify as standalone verification.

Bounds: 256 MiB archive/ZIP inflated bytes, a separate cumulative 256 MiB
WARC/index inflation budget, 32 MiB record, 50,000 records/pages/index rows,
10,000 ZIP members, 1,024-byte member paths, 64 KiB headers, 2 MiB HTML,
50,000 DOM nodes and depth 128. No member is extracted to disk. Unsupported
encodings and transformations fail explicitly. Large captures exceeding these
limits need a future streaming implementation; never silently truncate them.

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

The initial API checkpoint still has the 256 MiB aggregate parsing cap above.
A required streaming followup replaces it for ordinary multi-GiB captures while
preserving bounded per-record memory; this checkpoint alone is not final scope.
