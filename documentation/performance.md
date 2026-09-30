# Performance behavior and validation

Production Rust packages and Qwik frontend assets have separate source inputs
from their validation derivations. Editing Rust integration tests, Mail Archive's
`src/tests.rs`, frontend tests, test fixtures or Vitest configuration reruns the
appropriate checks without rebuilding the production package. Runtime source,
dependency manifests and explicitly embedded assets still invalidate builds.
Frontend typechecking, formatting (where supported) and tests remain separate
flake checks; production builds validate their required output files.

Media Manager initially requests up to 200 catalog items per root. Each completed
root becomes visible independently; Load more requests up to 500 additional
items per root. Filtering waits 150ms after input and searches the catalog,
including items beyond loaded pages. Cursors are scoped to the current search;
older responses cannot replace a newer search or category. Refresh keeps the
active filter, and searching keeps the selected metadata editor and its unsaved
draft mounted. Linked items load directly, and folder links use their URL root
to resolve ownership even when the folder is outside the loaded page.

Directory queries use the existing root/owner/path index with literal path
ranges, including Unicode and SQL wildcard characters. Reconciliation prepares
its writes once and updates only changed catalog records. Root scan freshness
still advances when no item changes; classification changes still update items.

Mail Archive retains only one attachment page as Rust display records. SQLite
stores compact candidate keys and ranks, applies ordering/counting/pagination in
one read transaction, and decodes the final page. Complex MIME, sender-priority
and Notmuch matching reuse the existing predicates through a SQLite function.
These predicates still inspect candidates, so this bounds retained memory rather
than promising constant-time search. Matching downloads remain unpaginated.

Search persists each Solr batch (at most 200 documents) in one PostgreSQL
transaction, polling writes concurrently to pipeline database requests. Solr
still receives documents first. A PostgreSQL error rolls back the entire batch;
the next pass may safely replay the idempotent Solr writes.

Browsertrix uses the existing shared blocking-handler mechanism with a 16-request
admission budget, as Media Manager already does. YouTube Downloader keeps its
SQLite connection on a reusable Node worker. Its queue accepts at most 128 pending
database operations, rejects excess work, and drains accepted work at shutdown.
Transactions and job claims execute as single worker operations.

Repository script tests share a run-scoped Nix evaluation cache. A per-key lock
coalesces concurrent misses; failed evaluations never become cache entries.
Expression, output mode, repository/flake references and the exported environment
identify a cached result. Tests that mutate a fixture at the same path must use a
fresh cache directory. The runner evaluates the default host once.

Protected Caddy hosts encode JavaScript, CSS, JSON files and selected listing
APIs (`/api/v1/items`, `/api/jobs`) with zstd/gzip. Authentication paths and media
streams retain their existing behavior. Caddy's content-type and minimum-size
checks still apply; byte-range responses remain uncompressed.

## Validation

Run `scripts/validate-repo.sh --full` for repository evaluation, derivation checks,
the shell regression suite and Homepage end-to-end checks. It does not activate
the server. Application tests cover pagination/search races, durable links,
literal directory ranges, unchanged rescans, attachment ordering/triage and
SQLite worker responsiveness, admission, rollback and shutdown.

The optional Search database regression requires a **disposable** PostgreSQL
fixture, creates its own schema and uses a local HTTP Solr stub:

```sh
SEARCH_BATCH_TEST_DATABASE_URL='postgresql://user@127.0.0.1:port/postgres' \
  cargo test --manifest-path custom_apps/Cargo.toml -p search \
  postgres_batch_rolls_back -- --ignored --nocapture
```

It verifies rollback of all 200 documents after a rejected row, recovery on the
same client and replay without duplicates. Local Caddy smoke checks also verify
compression round-trips and uncompressed 206 range responses. Browser inspection
uses desktop and phone widths with long titles and independently scrollable
lists. Live latency and deployment duration should be measured after a separately
authorized deployment; fixture results are not production speed measurements.
