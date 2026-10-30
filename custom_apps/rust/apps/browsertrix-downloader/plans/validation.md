# Web Archives validation receipt

Status: implemented, integrated and validated; no required backend or engine
review findings remain open. Application-code checkpoint: `c32f6de958b926a7150f0443c74d760ba9d14d7f`.
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
  the accepted backend correction and its separate review. Root reran the native
  profile matrix in 19.38 seconds and native resume in 16.15 seconds after those
  backend corrections. The later control guard only rejects unsupported
  pause/stop on file operations and leaves native capture controls intact.

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
  Final identity-preserving writer outputs are 101,596-byte selector export,
  53,470-byte dependent and 101,807-byte materialized standalone; independent
  native-pair verification retained all 18 resources and both original hashes.
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
- A fresh actual API/worker journey at `084df51` captured the isolated site,
  recaptured only its selected deep page, composed a complete three-page repair,
  exported a 61,813-byte standalone, and passed Reader/fixity checks. Parent and
  repair IDs remained distinct and the original SHA-256 stayed unchanged. Both
  the untouched homepage (story/image) and repaired deep page rendered through
  the pinned viewer. Clearing job history preserved the source. The subsequent
  backend change only adds the unsupported file-control rejection.
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
  A final run against the 109,406-byte native fixture projected 30 pages at
  581,520 bytes with range 109,406–4,238,280; its broader unknown-scope range
  explicitly includes 56,364 bytes of uncertain package/baseline overhead.
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

## Final checks and independent review

The owning app gate passed **69 tests, zero failures, five ignored** at `c32f6de`:

```sh
CARGO_TARGET_DIR=/home/dsaw/.t3/worktrees/NixOS/t3-dc8b342f/custom_apps/target \
  cargo test --locked --offline --manifest-path custom_apps/Cargo.toml \
  -p browsertrix-downloader --quiet
```

The five opt-ins were explicitly executed separately: native fixture-pair
transformation, native browser QA, measured forecast, synthetic private profiles
and native checkpoint resume. QA was additionally run with deliberately missing
content. Root's final QA reruns measured three-page success in 24.19 seconds and
the expected negative resource failure with both interaction assertions passing
in 12.06 seconds. No skipped opt-in is represented as an automatic pass.

Frontend `pnpm check` passed typecheck, **13 tests**, production build and replay
asset staging. JavaScript syntax, focused Nix checks, changed-source formatting,
diff checks and the pinned UI detector also passed. Application tests close the
earlier interrupted ENOSPC gates; no repository-wide gate was substituted.

| Scope | Exact accepted checkpoint and disposition |
| --- | --- |
| Plan | Review at `13cb1b6`; WA-PLAN-01–10 became binding corrections at `a1f0be6`, with implementation evidence above. |
| Claim helper prerequisite | `bfec700`, one independent pass, 22 focused tests; accepted. No installed runtime change. |
| Private Nix storage/backup integration | `d1c1b15`, round 2 accepted WA-MOD-001–003 corrections. |
| Frontend filters/reference races | `155f1fd`, round 2 accepted WA-FE-001–003. Integration round 3 qualified replay/bootstrap/report handling and found WA-FE004 coverage retry; `410d9f1` fixed it with direct browser evidence. That last mechanical correction is available to the coordinator's whole-set review rather than a fourth ordinary frontend round. |
| Backend custody/memory/controls | `c32f6de`, round 3 approved; WA-BE001–005 fixed. Backend `src/` tree `e2f5f6a7f3fabfb0467dd554ef849ce85db0629d`, `tests/` tree `bda981c280c524a874c45cc2e9caaa4eadc06ff2`. |
| WACZ engine | `084df51`, round 4 approved; WA-ENG001–005 and WA-INT001 fixed. Engine tree `1ed6a20144b74df7e2e1bbf2dab9f183225187e3`. Round 4 was a bounded extension for reproduced capture-data misattribution; 22 focused tests, native pair and 24 additional identity/re-export checks passed. |

Reader API output is capped at 8 MiB before allocation. Aggregate permits remain
held through blocking analysis and response-body consumption/drop; uploads stream
with existing caps. Four concurrent 128 MiB uploads measured approximately
47 MiB high-water RSS in the rework harness, not a whole-process guarantee.
Independent memory-budget/lease/cancellation regressions passed.

Maximum-size benchmarking, a repository-wide suite, production egress/service
activation and a live backup restore have not been performed by this workstream.
Same-URL/same-second ambiguity within a single gzip member remains explicitly
rejected. Picker fidelity and transformations retain their documented bounds;
size forecasts remain heuristic. The deployment coordinator owns whole-set
review and guarded activation; feature publication does not activate services.

## Workstream cleanup

All delegated writers and reviewers finished. Directory claims were released;
the integration checkout is clean. Task-owned browser sessions, HTTP servers,
API/worker processes and isolated container storage were stopped and removed.
Legacy host-PID test descendants were identified by their exact task-storage
conmon ancestry and stopped; unrelated processes were untouched. The managed
temporary directory was removed after all consumers finished. Only the completed
engine task's duplicate Cargo cache was reclaimed; source worktrees and the
primary validated app cache remain. Final observed free space was 4.9 GiB on
`/home` and 4.3 GiB on `/tmp`; the interrupted app gates were rerun successfully.
