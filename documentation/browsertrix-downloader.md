# Browsertrix Downloader

Browsertrix Downloader is a first-party queue and archive interface around the
published Browsertrix Crawler container. The crawler and ReplayWeb.page remain
upstream components; the Rust API, queue worker, Qwik interface, authentication
boundary, storage layout, and NixOS services are repository-owned code.

## Runtime layout

The module deliberately splits request handling from crawling:

- `browsertrix-downloader.service` serves the authenticated API, frontend, and
  WACZ byte ranges. It can write SQLite state and only read completed archives.
- `browsertrix-downloader-worker.service` claims queued jobs and launches one
  rootless Podman crawl at a time. Its separate system user owns the rootless
  container state and has an automatically allocated subordinate UID/GID range.
- `browsertrix-downloader-egress-policy.service` rejects crawler traffic to
  local, private, link-local, NetBird, multicast, documentation, and reserved
  address ranges. The crawler uses rootless `slirp4netns`, not host networking.
- `browsertrix-downloader-oauth2-proxy.service` admits members of the Kanidm
  `web-archive-users` group and supplies the trusted identity headers.

The crawler image must use an immutable `sha256` manifest digest. When updating
it, verify the published version and multi-architecture digest, update
`repo.browsertrixDownloader.crawlerImage`, and rerun the package and module
checks.

## Data and recovery

Persistent queue state and rootless container storage live under
`/var/lib/browsertrix-downloader`. Resumable crawl state and WARCs live in its
worker-owned `checkpoints` directory; only disposable scratch belongs under
`/var/cache/browsertrix-downloader`. Shared captures remain in the data pool at
`_Shared/_WebArchives`. Profile-backed captures and their derivatives use
`repo.browsertrixDownloader.paths.privateArchiveRoot`, outside the shared tree.
Both payload roots remain when the application is disabled or removed.

The archive catalogue survives job-history cleanup. Publication records an
owner-bound intent before copying, validates fixity and indexes, publishes
exclusively and finalizes catalogue state before scratch cleanup. Reconciliation
recovers known intents; retained files without ownership evidence remain
unclaimed and require explicit import. Never assign orphan files to the first
user who opens the library.

Pause retains checkpoints, stop saves partial work, and discard is a separate
action. Resume keeps the frozen recipe and accumulated page/WARC/time budgets;
exhausted limits require an explicit bounded extension. Published partial
versions remain immutable. A stopped or interrupted capture is not evidence
that the entire website was archived.

Backups include the logical SQLite dump and persistent state. The private payload
root is an actual Kopia snapshot root with a scoped policy that includes WACZ;
the global bulk-data exclusion still applies to shared WACZ. Search has
read-only ACL access to shared captures and never joins the private service
group. The API cannot access or replace accepted profile material; the worker
mounts the selected immutable profile into fresh per-attempt browser storage.

## Capture and library tools

The library supports server-side search, pagination, tags, collections,
favourites, notes, capture timelines and comparisons. Captured-text results
include original URL/time replay links. Reusable recipes and opt-in schedules
freeze capture settings; disabling a schedule prevents future submissions.

Discovery has separate time, byte and URL bounds. Its estimate describes the
selected recipe and known scope, not an exact total for an arbitrary dynamic
website. Queued browser samples supply measured stored bytes. The UI separates
shared and marginal storage, transfer bytes, WARC bytes and peak disk headroom.
Unattributed dynamic resources, browser baselines and packaging remain explicit
uncertain overhead in the sample projection; they are not silently omitted.

Faithful, Balanced and Reader presets expose editable scope/depth, SPA hashes,
multiple seeds, path/query patterns, resource rules, media choices, viewport,
language and bounded behaviours. Lossy choices are opt-in. Hidden components
can be needed by later interaction; hiding a DOM element does not imply that
its dependencies can be deleted.

The isolated element picker saves reversible display rules. Clean replay changes
presentation and saves zero stored bytes. Compact exports create new WACZ files
with rebuilt indexes/hashes and provenance; originals remain intact. Captures
with cross-archive deduplication retain hash-bound dependencies. Download a
standalone export before taking one of those archives away from the server.
Reader HTML/Markdown is a labelled derivative with reduced fidelity.

Fixity verification and offline browser QA are separate operations. Browser QA
reports page/resource, screenshot/text baseline and selected interaction results
independently, including unavailable baselines and untested dimensions. A valid
ZIP/hash does not imply correct replay. Targeted repair creates a complete new
version with mixed-time provenance, retaining untouched pages and the original.

The [implementation plan](../custom_apps/rust/apps/browsertrix-downloader/plans/expansion.md)
records the complete 30-feature scope, API contracts and acceptance evidence.
Rollback must preserve expanded catalogue/checkpoint state and the new private
storage boundary. Previous binaries cannot consume every new scope/status; never
point an incompatible binary at the expanded database or resume profile-backed
work with an older crawler adapter.

For a deliberately selected legacy read-only service, use the current package's
maintenance command against a stopped service or consistent database snapshot:

```bash
browsertrix-downloader-legacy-export SOURCE_DB /canonical/private/NEW_LEGACY_DB
```

The destination parent must be caller-owned and not group/world writable. The
command creates an exclusive mode-0600 database and returns JSON counts of
exported and parked records, with reasons. It preserves the source database and
copies only compatible completed shared standalone history. Private captures,
new scopes/statuses, dependencies and unfinished work stay parked in the newer
source. It copies no payloads and enables no legacy worker. Retain the current
Nix private-storage and service-group isolation during binary rollback; never
substitute the legacy export for the preserved expanded database.

## Kiwix archives (optional integration)

When the Kiwix module is enabled alongside Browsertrix Downloader, the
`grant_archives_access_to_kiwix_library` integration exposes uploaded ZIM
files on the Web Archives page:

- The API lists ZIM files from the read-only Kiwix library root
  (`repo.kiwix.paths.libraryRoot`) at `GET /api/zims` and streams individual
  files, with byte ranges, from `GET /api/zims/{name}`. Downloads use the
  same `?download=1` convention as WACZ archives.
- A dedicated `kiwix-serve-archives.service` instance serves the same Kiwix
  library under `archives.<domain>/zim/` with `--urlRootLocation=/zim`, so
  the Kiwix reader runs in the same authenticated origin. The auth gateway
  routes that path prefix after the same OIDC and group checks as the rest
  of the application.
- The integration is gated on both modules: removing either module drops the
  reader instance, environment wiring, route, and read access without
  touching the other application. The `wiki.<domain>` Kiwix host keeps
  working independently with its own `kiwix-users` gate.

## Useful checks

```bash
systemctl status browsertrix-downloader browsertrix-downloader-worker
journalctl -u browsertrix-downloader -u browsertrix-downloader-worker --since today
scripts/tests/test-browsertrix-downloader-module.sh
scripts/tests/test-kiwix-web-archives-integration.sh
cargo test --manifest-path custom_apps/Cargo.toml -p browsertrix-downloader
```

The worker pulls the pinned image on first start, so initial startup can take
several minutes and requires roughly 1 GB of compressed download capacity.
