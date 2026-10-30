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
