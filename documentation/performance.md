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

Repository script tests share the Nix evaluation cache of their invoking gate.
A per-key lock coalesces concurrent misses; failed evaluations never become
cache entries. Expression, output mode, repository/flake references and the
exported environment identify a cached result. Directory lifetime is the
caller's decision: `validate-repo.sh` keys its persistent cache directory by
the repository content hash, so entries from an older revision become
unreachable instead of stale (falling back to a run-scoped temp directory when
Git cannot enumerate the worktree), while a test that mutates a fixture at the
same path must supply a fresh run-scoped cache directory. The runner evaluates
the default host once.

Protected Caddy hosts compress text responses with `encode zstd gzip`, relying
on Caddy's default response matcher: it selects bodies by Content-Type (HTML,
JavaScript, CSS, JSON, SVG, XML, wasm, source maps) with a 512-byte minimum,
skips bodies marked `no-transform`, and never touches audio/video, so
audio/video streams keep byte-range semantics. Encoding is deliberately not
gated on a request-path matcher, which would leave extensionless document
routes (`/`, `/services/...`) uncompressed. Hosts that terminate their own
virtual host (Immich, Jellyfin, Paperless, Audiobookshelf, Kavita, Vaultwarden,
Forgejo, OpenCloud, IPFS, F-Droid, the Kanidm UI, File Sync, the YouTube
Downloader API host and the Files share host) use the same plain
`encode zstd gzip`. Authentication paths retain their existing behavior.

## Frontend delivery

Every Qwik app builds with the default entry strategy (per-symbol/segment
chunking). No app forces `entryStrategy: { type: "single" }`, which collapsed all
routes and views into one bundle. Frontend builds validate their required
outputs but do not assert a specific chunk count, so code splitting can change
without editing checks.

Static asset responses set `Cache-Control` from the filename: content-hashed
assets (Vite `name-HASH.ext`, `/assets/*`, `/build/*`) are
`public, max-age=31536000, immutable`; HTML is `no-cache` so deployments are
picked up; other files get `public, max-age=3600`. The shared Rust helper
`homelab_common::cache_control_for_path` and the Node
`staticCacheControl` in `custom_apps/node/shared/http-protocol.ts` own this
decision. Service workers remain `no-cache`.

## Shared platform tuning

PostgreSQL server settings are decided centrally in `system-resources.nix`
(gated on `config.services.postgresql.enable`) because one cluster backs both
Search and Immich; optional modules must not each set their own. Redis/Valkey
instances created by Immich and Paperless receive `maxmemory` and
`maxmemory-policy` bounds in the same file, gated on the owning app's option
rather than on the `services.redis.servers` set being defined (which would
recurse). macOS-style `vm.swappiness`, `vm.max_map_count`, dirty-ratio and file
descriptor sysctls live next to the existing inotify limits.

Long-running or bursty services (qbittorrent, forgejo, the media-manager
scanner, the Paperless snapshot job) carry `MemoryHigh`/`MemoryMax` and, for
the maintenance jobs, `Nice`/`CPUWeight`/`IOWeight` scheduling. The Paperless
database snapshot runs every 15 minutes rather than every 2, because duplicate
detection tolerates a stale snapshot and the job copies the whole database.

Long-running network-facing services that were previously uncapped are bounded
in the same central block: `ipfs` (512M/1G), `opencloud` (2G/4G), `search-solr`
(4G/6G), `cloudflared-tunnel-*` (1G/2G), `syncthing` (512M/1G), `caddy`
(512M/1G), `homepage` (256M/512M) and `kanidm` (512M/1G). Each value comes from
read-only observation on this host (`systemctl show <unit> -p MemoryCurrent -p
MemoryPeak`) plus the sizing options already in the configuration; `MemoryMax`
is roughly twice the observed peak so an expected burst never becomes an
OOM-kill. `search-solr` must keep headroom above the module's 2g `solrMaxHeap`
for JVM native and metaspace overhead. Jellyfin keeps its existing 1G/2G caps
because transcoding is the one workload whose burst does not appear in
`MemoryPeak`. Short-lived bootstrap and oneshot units stay uncapped, and
optional apps are gated on their own enable so a removed module never leaves a
cap behind.

## Deployment and validation efficiency

The workstation `localNixGCMode` default is `capacity`: the deploy helper only
collects the local Nix store when the main SSD is under pressure, preserving
Crane/shared dependency build reuse between deploys. Set it to `always` to
restore the unconditional `nix-store --gc`. The capacity GC script measures the
filesystem first and skips the full `du` store walk whenever filesystem pressure
alone already forces a collection.

`scripts/validate-repo.sh` reuses a persistent on-disk Nix evaluation cache
keyed by the repository content hash (bounded to the most recent generations),
instead of a temp directory deleted after each run. Batched test probes combine
independent expressions into one cached evaluation, and the guarded deploy
forces the host's full toplevel instantiation and reads the optional Homepage
canary flag in a single eval instead of two. The AI gate test only
compiles its crate when the owning `bonsai` app is enabled, reusing a
persistent incremental target directory. The CI workflow lets its parallel
`nix-eval-jobs` evaluation satisfy the guarded validation step, which runs with
`--skip-flake-check`, and uses the toolchain-free `.#eval` shell for
evaluation-only jobs.

First-party Rust crates keep `codegen-units = 1` in the shared release
profile while the dependency graph builds with 16 codegen units, and
clippy/nextest disable release LTO through cargo profile env config:
the shared dependency derivation loses about half a minute of wall
time on four cores, and the media-manager nextest build drops from
9m50s to 5m37s with identical results. mkvmaker is a workspace member
sharing the crane dependency artifacts and lockfile (workspace edition
2024, with `style_edition` pinned to 2021 so existing sources do not
reformat). YouTube Downloader's production source excludes `src-tauri`
(the desktop wrapper builds from its own source), and Groundwater
Logger uses the same clean-source filter as its siblings, so
build-only artifacts cannot churn the pinned pnpm dependencies.
Jellyfin serves the stock substituted package with only `index.html`
bind-mounted over it from a shadow derivation, so OIDC login-script
changes no longer force a full server rebuild. The server's
post-build Attic push runs for up to fifteen minutes with two upload
jobs and logs failures at warning priority, so a slow cache reads as
degraded service instead of a build error.

## Backend queries and indexing

Media Manager resolves artwork through the `catalog_items_artwork`
`(root_id, media_kind, relative_path)` index; item batches and mutation-plan
action counts use single grouped queries instead of per-row subqueries or point
lookups. Media playback and ranged responses stream from disk
(`tokio-util` `ReaderStream`) rather than buffering whole files, and catalog
connections set `synchronous=NORMAL`, `cache_size`, `mmap_size` and
`temp_store=MEMORY`. The insert-only `audit_events` table is indexed on
`created_at` and pruned during the scan run.

Media Manager serves artwork and metadata from shared in-process
caches: directory walks hit a 30-second candidate cache with ancestor
folder covers (name-matched levels win over nearer unmatched files)
and a short-lived miss cache keyed by item id, folder metadata lookups
memoize parsed JSON validated by (path, mtime, size), the frontend
HTML index is built once per process, and provider account lookups
share a client with a per-identity TTL. Mutation plans batch item
removals in chunks of 999 parameters.

Mail Archive checks `(mtime, size)` before parsing MIME or hashing a
message and runs the whole attachment refresh in one transaction, so
an unchanged rescan and a large refresh both avoid repeated
whole-store hashing and per-message fsyncs. It also memoizes each
notmuch search per (store, account, sync stamp, query) with a
five-minute TTL, so page transitions and filter
changes reuse one search instead of re-running notmuch and re-reading
headers; a mailbox sync turns the entry over via the stamp.
Attachment page previews are cached by (path, mtime, size) with a
1,000-entry eviction clock, and rendered Vite asset tags are read once
per process per dist directory.

YouTube Downloader hydrates `job_files` for a page of job rows through
one grouped query instead of one query per row, and the
completed-download duplicate lookup scans only the 200 newest jobs
backed by a `(created_by, status, updated_at)` index (schema migration
3), so a very long history cannot grow the scan. Groundwater Logger
caches the `/api/status` database summary for 45 seconds while MQTT
state stays live and SSE still pushes connection and message events
immediately.

Search indexes `documents(source_id, id)` for batched source paging.

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
