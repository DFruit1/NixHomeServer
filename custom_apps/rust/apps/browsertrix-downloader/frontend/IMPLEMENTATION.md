# Web Archives frontend handoff

This is implementation evidence, not independent acceptance. The frontend is
contract-ready; backend/engine integration and genuine capture/replay acceptance
belong to the parent task. No deployments, credentials, spending, routing changes,
pushes or subagents were used.

## Scope and interface

Owned path: `custom_apps/rust/apps/browsertrix-downloader/frontend/` only.
Base: `25350ffb387bef40355405ee4753cdd7cc131711`. Binding corrections were read
from the parent's updated expansion plan at `a1f0be6560b308ad12eaf7d4e0a109ca482382c4`.

The default workspace is a durable archive library. New capture is a separate
form; active work and disposable history appear above Kiwix. Archive detail is
stable at `/?archive=ID&url=CAPTURED_URL&ts=TIMESTAMP`. Captured-text search links
include the selected original URL and timestamp. Invalid/authentication-changing
session reads hide archive data until the session is verified again.

Material design decisions for the parent to record in global DESIGN_SYSTEM.md:

- Retain the app's system font and light/dark blue-neutral tokens; use semantic
  forms, restrained dividers and meaningful archive/job rows.
- Keep library-first navigation. Put capture limits and optional discovery before
  editable presets, page/resource/selector rules, behaviours and private profiles.
- Use one archive workspace with Overview, Pages, Resources, Clean view, Export,
  Verify & repair, and Timeline tools. Pagination and inventories stay on server.
- Use page scrolling, wrapping navigation, 44px controls, explicit labels, visible
  focus, live action status/errors and reduced-motion support. No fixed-height
  editor scroller hides the final control. Replay/selection iframes are bounded.
- Avoid inferred metrics: measured archive bytes, record attribution, unique
  payloads and transfer bytes are labelled separately. Clean display saves 0
  stored bytes; trash retains files and reclaims 0 bytes.

No global design or plan files were edited by this frontend task.

## Feature coverage in source

| Features | Frontend implementation |
| --- | --- |
| 01, 21, 22 | Durable summary library, server search/paging/filter/sort, captured-text search and stable page/time links; title/tags/collection/favorite/notes edit in detail. |
| 02, 04, 05 | Active packaging/partial/paused states, reported coverage/errors/stop reasons; separate pause, stop-save, bounded resume and explicit discard; publication/fixity are not inferred from crawl completion. |
| 03, 09–14 | Scope/SPA hashes, depth, seeds, page/time/byte/resource/reserve budgets, presets, regex scope preview, resource/allow/selector rules, media/alternate-image choices, bounded behaviours, click/load-more, viewport/language. |
| 06 | Status/shape guards, per-action pending/errors, retained stale lists, aborted superseded reads, sequential non-overlapping polling, keyboard forms/labels/live regions/touch/reduced motion. |
| 07, 08 | Distinct bounded discovery and queued browser sample actions; ranges, assumptions, warnings, unknown scope, peak disk, shared/marginal stored bytes; only explicit `measured:true` is labelled browser sampled. |
| 15, 16, 17 | Paginated page/resource inspection and attribution; sandboxed selection preview with strict source/origin/message checks; scoped reversible hide rules; separate original/clean viewer identities and original hashes preserved. |
| 18, 26, 28 | Compact/standalone export selections, URL/domain/MIME exclusions, selector transformation and deduplication options; queued derivative results; dependency links and source-download warning; reader/standalone downloads. |
| 19, 20 | Separate queued fixity/browser-QA actions and per-dimension persisted results; frozen or explicitly overridden bounded interaction checks; selected failed/missing URLs queue repair. |
| 23, 25 | Versioned recipe create/edit/run/delete, multi-seed bounded batch, opt-in schedules create/enable/disable/interval edit/remove with last-run/error evidence. |
| 24 | Host-filtered paginated timeline and pairwise comparison; links to both snapshots and warnings that missing coverage is not proof of a live website change. |
| 27, 29 | Raw WACZ upload queues import; retained-file reconciliation; restorable trash/restore and fixity reporting; no permanent deletion control. |
| 30 | Owner-scoped profile metadata/reference listing, unavailable/expired selection exclusion, raw private material import queue, revocation; metadata alone does not imply usable material. |

Controls invoke the documented endpoint or display its returned error/pending
state. Their existence does not establish that the concurrent backend implements
the operation correctly. There are no successful placeholder export/QA results.

## Exact additive contract expectations

`src/shared/types.ts` and runtime guards in `src/shared/api.ts` are the complete
frontend expectations. Important integration details:

- Lists of jobs, recipes, schedules and profiles retain their array response.
  Archive summaries, captured text search, page/resource inventories are
  `{items,total,offset,limit}`. Limit is 1–100; UI requests 25 rows.
- Archive summaries require id, createdAt, updatedAt, url, title, archiveBytes,
  tags, collection, favorite, trashed and captureStatus. Optional visibility,
  pageCount and resourceCount are consumed if present. No inventory is needed in
  list responses. Archive report summaries may omit pages/resources; their
  remaining byte/hash/description/warning/dependency fields are validated.
- Library accepts additive `tag`; sort values sent are `newest`, `oldest`,
  `title`, `size`. Filters are sent before paging. Host timeline uses server
  `q=hostname` plus exact client host filtering; its pager total is the server
  search total and can include filtered other-host matches.
- Capture options add `alternateImages:boolean` and
  `interactions:{selector,assertion,expected}[]`, assertion visible/hidden/text.
  At most 20 checks. Visible/hidden expected values are CSS selectors; text is a
  substring of the clicked element's text. Default limits follow the inspected
  backend defaults: depth1, WARC2GiB, reserve512MiB, post-load0s, viewport1280x900,
  behaviour90s. Blank byte/resource limits send explicit JSON null, not omission.
- `POST /api/samples` returns `{jobId}`. Estimates may add `measured:boolean` and
  `method:string`. Sample count alone never establishes browser measurement.
- Resume body is `{additionalPages,additionalMinutes,additionalBytes}`;
  extensions default to zero. UI bounds extensions at 500 pages/120 minutes;
  byte extension is entered as MiB and sent as bytes.
- Verify sends `{mode:'fixity'|'browser',url,interactions?}`. Omitted interactions
  inherit the frozen recipe; explicit `[]` means none. Response accepts `{jobId}`
  or a persisted Verification for compatibility. Queued work stays pending.
- Export/import accept queued `{jobId}`; compatible completed results may carry
  archiveId/downloadUrl. Download URL responses must be same-origin `/api/` URLs.
- Profile import is raw bytes at `POST /api/profiles/import?name=NAME`, returning
  `{jobId}`. Metadata creation uses POST /api/profiles but remains unusable until
  `available:true` reports accepted, unexpired material.
- Preview iframe is `sandbox="allow-scripts"` with no same-origin/forms/popups.
  The backend's trusted selection script posts
  `{type:'web-archives:selection',selector,url,matches}`. The UI requires opaque
  origin `null`, exact iframe `event.source`, exact requested URL, selector ≤1000
  chars and integer matches 1–10000. Selector syntax is validated again. Original
  scripts and external fetches must be disabled by the backend preview/CSP.
- Replay source is ABSOLUTE same-origin `/api/archives/:id/replay.json`, since the
  pinned loader calls `new URL(sourceUrl)` without a base and requires a JSON
  filename for Multi-WACZ discovery. Keep `embed=full`
  whenever config/customColl is set. Page/time selection is in the viewer hash.
- customColl SHA-256 identity includes username, archive ID/hash, display mode
  and saved rules. Original/clean are distinct; original→clean→original is stable
  in the security unit check. `noCache=1` is requested; no browser pinning is offered.
- Clean script is frontend-owned `public/replay/clean.js`, explicitly copied to
  `dist/replay/clean.js` by stage:replay. Merely copying it under dist/client would
  not satisfy the backend replay route. Injection URL rules live in its fragment;
  apostrophes and HTML delimiters are encoded. It validates querySelectorAll,
  scopes WB_wombat_location/_WB_wombat_location, then sets only display:none with
  style.setProperty. It fails closed without the replay location. No raw CSS/HTML
  is built from selectors; no API fetch or archive rewrite occurs in this script.
- Both modes use `sw-clean.js`, a small wrapper around the pinned worker. Its
  proxy exception accepts only GET for the exact local `clean.js` path, without
  query parameters or redirects; every other request uses upstream replay
  handling. This is needed because per-collection injectScripts does not update
  the upstream worker's proxy allowlist. The wrapper never permits a live origin.

Root integration checks: `pnpm check` now passes 13 tests, including a regression
for the strict script proxy boundary, plus production replay staging. Actual
ReplayWeb.page 2.5.2 rendered the synthetic Multi-WACZ manifest and applied the
scoped hide rule while preserving text and the original payload. The earlier
child-only limitations below describe its original handoff; final integrated
acceptance is recorded by the parent plan.

## Checks and fixture-only browser evidence

- `pnpm install --frozen-lockfile` used existing pins; no dependencies added.
- `pnpm check`: typecheck of all src, 12 tests in two files, production build and
  replay staging. Nine original URL tests plus three security regression cases.
- New-test risk basis: untrusted archive/sibling-frame messages or selector text
  could inject script/CSS or reuse private/clean viewer state. The tests reject
  wrong source/origin/URL and oversized messages; separate owner/mode identities;
  encode injected script URLs; exercise the actual clean asset in a bounded VM
  and prove style-property changes only for valid scoped selectors.
- `node --check public/replay/clean.js`; `git diff --check`.
- Pinned Impeccable detector on changed root/components: `[]` (no findings).
- T3 preview opened/navigated but two snapshot attempts failed identically:
  `Preview automation snapshot timed out after 15000ms.` The tab was closed.
- Documented Playwright CLI fallback ran `/usr/bin/chromium`, using one local
  fixture API and task-specific temporary directory. No real server was used.
- Desktop1280: server library next page (26–50/62), visible stale-data retention
  on503; discovery/settings/capture queue preserving SPA hash and multi-seeds;
  metadata save; page paging (26–31/31); URL selection into export; resource MIME
  filter; export/repair/fixity/browser-QA pending requests; sandbox selection,
  scoped rule save; host timeline and comparison. Measured scrollWidth1280.
- Mobile390x844 dark/reduced-motion: recipe run/version edit; disabled schedule
  create and enable/disable; metadata-only profile unavailability; expanded
  capture settings and reachable final queue control; isolated selection;
  restorable trash and restore requests. Measured detail scrollWidth390.
- Final mobile journey exercised pause, resume(+10pages,+5minutes,+20971520bytes),
  stop-save and explicit discard (fixture confirmation accepted), synthetic raw
  upload→queued import, reconciliation, captured-text deep link with archive/url/ts.
  Measured width390/scrollWidth390/scrollHeight6761/clientHeight844, zero unlabelled
  form controls, zero visible buttons shorter than43px, final footer reachable.
- Fixture work found and fixed proxy structuredClone submission failure, stale
  derived pager labels, shadowed per-mode QA notices and multiline-draft trimming.

## Remaining acceptance and limitations

- No real concurrent backend/engine acceptance was run in this child worktree.
  Actual authenticated status/shape compatibility, archive custody, private
  isolation, profile validation, worker queue completion, exact sort/filter
  semantics, resume/checkpoint retention, and retained-job cleanup need integration.
- Actual WACZ replay, Multi-WACZ dependency resolution, injected clean-rule
  behaviour in the real pinned service worker, and original→clean→original browser
  roundtrip remain for the parent's genuine replay journey. The unit test proves
  identities/config separation, not working viewer replay or service-worker reuse.
- No genuine browser sampling, screenshot/text/resource offline QA, standalone
  compact export, repair composition, fixity analysis or server-unavailable reader
  export was claimed. Raw upload fixtures prove queued API wiring only, not valid
  archive/profile parsing or successful import. Unsupported transforms must fail.
- The bounded fixture journey did not click every delete/revoke/interval editor,
  execute browser profile import, verify actual download bytes, or prove polling
  behavior under a deliberately slow real backend. These controls are typed,
  compiled and wired, but their actual effects remain integration work.
- There is no browser storage pinning or permanent deletion. Timeline host
  filtering uses the server query's total as explained above. Whole-suite Rust,
  Nix evaluation, real server activation and deployment are outside this child's
  owned path and were not run.

Task-only servers, browser session and the exact temporary directory are cleaned
up before handoff. Source is committed locally and the directory claim released.
