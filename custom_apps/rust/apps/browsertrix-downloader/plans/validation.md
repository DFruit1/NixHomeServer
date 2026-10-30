# Web Archives validation receipt

Status: final backend and engine corrections are under independent review.
This receipt supplements the [30-feature implementation plan](expansion.md).
Passing checks below establish their stated boundaries, not live deployment.

## Environment and provenance

- Source base: `ff550b82549ceeb5e6599a82be429cf7919d16c3`.
- Branch: `feature/web-archives-expansion`; root integration checkout is isolated
  from the deployed system and other feature worktrees.
- Browsertrix Crawler: local image
  `1fcae30dc72cdf604a33e2b854a6bf77ffe8ea8e469d3f900a6c3425d5e496fb`,
  independently checked OCI version 1.14.3, from the module's pinned image.
- ReplayWeb.page 2.5.2 / wabac 2.27.2; Chromium `/usr/bin/chromium`.
- Actual capture/QA used task-owned rootless Podman storage, `--pull=never`,
  private PID namespaces and isolated synthetic sites. Offline QA also used
  `--network=none`. No production credentials or profiles were imported.
- T3 preview snapshots failed twice with the same error:
  `Preview automation snapshot timed out after 15000ms.` Browser checks then
  used the documented Playwright CLI fallback, with task-owned browser sessions.

## Actual capture and preservation

The corrected native fixture contains three pages and 18 resources, including
menus, a hidden panel, an image, a valid favicon, a deep route and warmed dynamic
API content. Its original WACZ is 109,406 bytes, SHA-256
`8ff426f54c025bf5ccbf7860eea6df31a44eff3ad738718cce11662588cd2241`.

- Native page-limit resume: partial one-page capture, explicit extension by two,
  then completed three-page capture in two attempts and 14 cumulative seconds.
  The original partial's hash stayed unchanged; the new version retained its
  parent ID/hash. Checkpoint cleanup followed publication.
- Native offline QA: three of three page loads, screenshot baselines and text
  baselines passed, with zero missing/changed responses. No interactions were
  configured for that full-site run, so that dimension was explicitly not run.
- A separate homepage run passed both menu and tab click assertions. A derivative
  deliberately omitting the captured HTTP-200 favicon still passed page, text,
  screenshot and interaction checks but correctly failed resource fidelity.
  A captured original HTTP-404 response was separately classified as a captured
  error, rather than a missing replay payload.
- Synthetic Alice, Bob and unprofiled captures observed only their respective
  cookie/storage values or empty state. Expired and revoked queued profiles were
  rejected before container launch. Concurrent revocation/import is covered by
  the final backend correction and its separate review.

## WACZ processing and replay

- A 335,577,660-byte archive with five 64 MiB binary response bodies completed
  inspection, export, fixity, source-preservation, preview and Reader checks.
  Output was 335,653,513 bytes; peak RSS was 15,872 KiB, elapsed 1,220.6 seconds
  in a debug build. This measurement preceded the final text/view refinements;
  it is not a benchmark at the engine's maximum configured archive ceiling.
- A 3 MiB inline-JSON HTML page survives inspection, verification and unchanged
  export with resource digests and native rendered text intact. Optional DOM
  analysis reports its omission; preview/selector transformations reject their
  2 MiB limit before loading the body eagerly.
- Different-time native captures produced a 53,334-byte dependent WACZ and a
  101,675-byte materialized standalone. Both source hashes stayed unchanged.
  Actual pinned-viewer replay of the dependent capture rendered the story and
  image through hash-bound `relation.requires` parent lookup. Merely listing
  both archives in Multi-WACZ had previously failed and was corrected.
- A downloaded standalone was ingested through the viewer's file-input path,
  then replayed with the browser offline. Story, image, menu, hidden panel and
  captured API data worked; the explicitly removed advert remained absent.
- Actual original → clean → original switching changed advert display from
  visible to hidden to visible while the archive hash and 109,406-byte payload
  stayed unchanged. Clean display rules claim zero stored-byte savings.

## API, discovery and UI

- An isolated real API/worker accepted native WACZ import, metadata changes,
  paginated inventories, MIME filtering, captured-text search, queued standalone
  export and fixity. Clearing terminal history left archive download/replay and
  the original hash available. A second synthetic owner saw an empty library
  and received 404 for the first owner's detail, payload, preview and mutation.
- Discovery's network contract was exercised inside a fresh user/network
  namespace. A synthetic public address accepted a relative redirect; an
  otherwise unresolvable hostname succeeded only through validated address
  pinning. Redirect to loopback and a public-to-private second DNS answer were
  rejected before connection. Origin logs contained exactly the expected public
  requests, with zero private/proxy canary requests despite configured proxy
  environment variables. No host routes or live firewall rules were changed.
- A measured three-page sample retained the requested forecast target of 30.
  For a 60,302-byte capture, the three-page expected value was 60,302 bytes with
  range 60,302–132,650; the 30-page projection was 572,920 with range
  64,213–1,326,500. Unattributed dynamic/baseline payloads and package overhead
  remain explicit uncertainty, distinct from transfer bytes.
- Desktop 1280 px and mobile 390 px journeys checked capture settings, presets,
  SPA hashes, seeds, recipes, opt-in schedules, metadata, inventories, selector
  messages, export/repair/QA queues, trash/restore and deep links. Mobile content
  wrapped without horizontal page overflow and final controls remained reachable.
- First-use replay and worker upgrade with another tab open were checked.
  Bootstrap timeout appeared at approximately 20 seconds and Retry worked.
  Coverage failures retain stale rows visibly; explicit Retry reissues both
  initial-load and failed-next-page requests.

## Operational checks and rollback

- The two focused module checks passed with `REMOTE_EVAL=0`:
  `test-browsertrix-downloader-module.sh` and
  `test-kiwix-web-archives-integration.sh`.
- Independent module review accepted private storage ACLs, actual private Kopia
  snapshot inclusion and the API's inaccessible profile mount. Isolated Kopia
  0.23.1 restored a synthetic 54,088-byte WACZ byte-for-byte while excluding a
  synthetic GGUF under the scoped policy.
- Legacy export leaves the newer source database unchanged and creates an
  exclusive mode-0600 compatibility database. Its fixture exported one compatible
  completed shared standalone job and parked seven incompatible/private cases.
  Payloads and events are not copied. Keep the new private-storage boundary when
  using a fallback binary; never point an old worker at expanded/profile data.
- ENOSPC interrupted a cold build and one child's source write. Those attempts
  were not counted as passes. The child recovered its exact source from its
  committed checkpoint and intended edit, then reran its owning checks. Cleanup
  removed only task-owned reproducible outputs; final gates reuse known caches.

## Remaining qualification

The final receipt will record the corrected backend/engine revisions, their
independent review dispositions and the final integrated app test counts.
Maximum-size benchmarking, a repository-wide suite, production egress/service
activation and a live backup restore have not been performed by this workstream.
The deployment coordinator owns whole-set review and guarded activation.
