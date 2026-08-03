# Custom application build graph and validation cache

- Status: accepted
- Date: 2026-08-03

## Context

The first-party applications previously coupled Rust compilation to frontend
and runtime files, gave Mail Archive UI and Media Manager separate pnpm fetch
derivations for identical dependency manifests, and ran full-check derivations
one at a time. Small UI, test, or runtime-script edits therefore invalidated
more work than their behavior required. Deploy-time workstation garbage
collection could also discard useful validation outputs regardless of store
pressure.

The host currently enables Homepage, YouTube Downloader, Mail Archive UI,
Media Manager, Mkvmaker, and Homepage's Kanidm Canary. Groundwater, Bonsai,
Kiwix, and Beszel are not part of its routine evaluation or check set.

## Decision

Rust applications have three explicit layers:

1. A manifest-derived Cargo dependency artifact that is independent of ordinary
   source edits.
2. A Rust-only backend package built from production sources. Top-level
   integration tests are excluded by default, and Mail's in-tree `src/tests.rs`
   is also excluded.
3. A cheap runtime assembly derivation that copies the immutable backend and
   adds frontends, runtime scripts, and wrappers.

Mail Archive UI, Media Manager, and Mkvmaker expose `backendPackage` as well as
their assembled `package`. Full check sources remain available to fmt, clippy,
and nextest. Frontend sources and Mkvmaker's `auto_import.py` are runtime inputs,
not Rust compiler inputs.

Mail and Media assert byte-identical pnpm lockfiles and equivalent dependency
and tool declarations after removing the package name. They use one shared
`fetchPnpmDeps` derivation and a common frontend builder, while keeping
application-specific output assertions and installation destinations.
Homepage and YouTube Downloader use production source filters that omit build
output, dependency directories, and test-only artifacts. Homepage E2E remains
on its separate Playwright source path.

Full host validation evaluates the enabled check set once and submits all
eligible derivations to one `nix build --json` invocation. Shell and Homepage
E2E gates follow. Temporary indirect roots protect outputs during validation;
only a completely passing host-scoped run replaces the stable roots under the
user state directory. Repository-wide `--all-apps` results never displace this
daily warm set.

Workstation GC is an explicit `never`, `capacity`, or `always` policy. Capacity
mode reuses the server's threshold helper and maintenance locking. The legacy
boolean remains a compatibility input, but an explicit mode wins.

## Measurements and experiments

Measurements used the dirty working tree as the functional baseline and kept
generated data outside Git. The workstation and server each expose four logical
CPUs; wall time, CPU time, peak RSS, closure size, NAR size, and derivation plans
were recorded. Three-run medians were used where repeatable output derivations
could be created without relying on `nix build --rebuild`; Crane check outputs
are not byte-stable under that flag.

Deterministic boundary changes were retained directly. The shared Mail/Media
pnpm input resolves to one dependency derivation. YouTube Downloader's parallel
client/server build reduced its three-run median from 35.32s to 18.52s (47.6%)
with similar 421--425 MiB peak RSS, so it was retained. Homepage parallelism was
rejected because the server/SSG build consumes client output and failed the
404-page generation path.

Synthetic derivation probes confirmed the intended invalidation boundaries. A
Mail frontend edit changed only its frontend and runtime assembly derivations;
its backend, Cargo artifacts, and Rust tests stayed identical. Editing Mail's
`src/tests.rs` changed nextest only. A Rust backend edit changed backend,
assembly, and checks while leaving Cargo artifacts identical. Editing
Mkvmaker's `auto_import.py` changed assembly only, and a Homepage E2E edit left
the production Homepage derivation unchanged.

System SQLite was retained for Mail and Media. Cold dependency build phases
fell from 164s to 141s for Mail (14.0%) and from 205s to 139s for Media (32.2%).
All 92 Mail and 49 Media Rust tests passed, including migration,
reconciliation, WAL, catalog scanning, and HTTP behavior. Both binaries link
the pinned Nixpkgs SQLite dynamically. Backend closures changed from 53.0 to
56.7 MiB for Mail and from 59.0 to 60.6 MiB for Media; the small shared-library
increase was accepted in exchange for the measured cold-build reduction.

Independent clippy and nextest derivations remain independently schedulable.
Chaining was rejected because aggregate Nix scheduling already runs them in
parallel and no repeatable 10% full-check improvement was demonstrated.

Headless HandBrake was retained. Its cold build phase completed in 54s versus
79s for the GTK build, a 31.6% reduction. `HandBrakeCLI --version` and a basic
Matroska conversion passed, and removing the GUI did not grow the Mkvmaker
closure.

The narrow `mkvpropedit` package was also retained. The pinned upstream Rake
build exposes the stable `apps:mkvpropedit` target; that target completed in
684s. A warmed full CLI build was still compiling unrelated merge and input
targets when stopped at 779.26s, establishing a conservative improvement of at
least 12.2%. The narrow binary changed a copied Matroska title and `ffprobe`
read the expected value. The final assembled Mkvmaker closure is 1.5 GiB,
down from the 1.6 GiB baseline.

The selected personal build mode is recorded after the allocation benchmark
below; the generic example remains `remote`.

The first live capacity probe found the workstation above threshold after the
benchmark downloads and correctly serialized collection with the maintenance
lock. The post-collection probe reported `decision=skip`,
`trigger_reason=below_threshold`, 21.5 GB of store data, and 39% filesystem use.

## Consequences

- Frontend and runtime-only edits no longer invalidate Rust backend compilation.
- Rust test-only edits do not change production package derivations.
- Enabled host checks stay warm across capacity collection while the latest
  validation remains reachable.
- Full validation exposes concurrency to Nix in one scheduling decision.
- The custom assembly layer is intentionally cheap and duplicates only the
  backend package's output files, not its compiler work.

## Rejected and deferred alternatives

- A repository-wide Cargo workspace or pnpm workspace is deferred; it would
  couple applications that currently version and deploy independently.
- Node was not downgraded, and the Kanidm Canary protocol was not replaced with
  raw internal HTTP.
- Homepage client/server parallelism and chained Rust checks did not pass their
  behavioral or performance gates.
- Python-to-Rust importer work is outside this build-graph decision.
