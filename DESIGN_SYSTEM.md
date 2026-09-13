# Design System

Living record of this repo's frontend design decisions. Maintained by the
`frontend-design` skill workflow (`.agents/skills/frontend-design/SKILL.md`).

Rules for keeping this file useful:

- **Tokens and existing components first.** Before introducing new spacing,
  colours, radii, typography, shadows or components, check the target app's
  styles file and this page. Record anything deliberate here so future agents
  (and the Impeccable detectors) treat it as an intentional project choice, not
  drift.
- **No invented UI.** Metrics, badges, helper text, cards or dashboard panels
  only when they materially help a task or decision (see the anti-slop rules in
  the frontend-design skill).
- **Detector exceptions.** When a deliberate choice trips an Impeccable detector
  rule, add a narrowly scoped exception in `.impeccable/config.json`
  (`detector.ignoreRules` / `ignoreFiles` / `ignoreValues`) and note it in the
  decisions ledger below. Do not change the design to silence a detector.

## Surfaces

| App | Path | Stack | Primary styles |
|---|---|---|---|
| media-manager | `custom_apps/rust/apps/media-manager/frontend/` | Qwik 1.16 + Vite (TSX) | `src/styles.css` |
| mail-archive-ui | `custom_apps/rust/apps/mail-archive-ui/frontend/` | Qwik 1.16 + Vite (TSX) | `src/styles.css` |
| homepage | `custom_apps/node/apps/homepage/` | Qwik 1.16 + Vite (TSX) | `src/client/styles.css` |
| groundwater-logger | `custom_apps/node/apps/groundwater-logger/` | Qwik 1.16 + Vite (TSX) | `src/client/styles.css` |
| youtube-downloader | `custom_apps/node/apps/youtube-downloader/` | Qwik 1.16 + Vite (TSX) | `src/client/styles.css` |
| browsertrix-downloader | `custom_apps/rust/apps/browsertrix-downloader/frontend/` | Qwik 1.16 + Vite (TSX) | `src/client/styles.css` |
| search | `custom_apps/rust/apps/search/` | Single-file vanilla HTML/CSS/JS | `src/ui.html` |

There is currently no shared cross-app token file; each surface owns its styles.
Do not introduce one casually — if two surfaces drift apart, align the older one
to the newer deliberate choice and record it here.

## Deliberate design decisions

Ledger of intentional choices that override generic kit/skill/detector
preferences. Empty by design: add entries as they are made, never retro-fit
assumptions.

| Decision | Applies to | Rationale | Detector exception |
|---|---|---|---|
| Homepage tokens are app-local `:root` custom properties, not a shared cross-app token file | homepage (`src/client/styles.css`) | The repeated inline hex values were replaced with named tokens while preserving each distinct value (near-duplicate greys keep distinct `-muted`/`-soft`/`-cool` suffixed names) so rendered colors are pixel-identical. The no-shared-token-file rule above stands. | — |
| Shared Node server plumbing lives in `custom_apps/node/shared/` and is copied into each app as `src/shared/node-common/` | homepage, groundwater-logger, youtube-downloader | Deduplicates identical request-boundary code (same-origin, bounded body reads, JSON replies, static file serving). Plumbing only — no design tokens or visual CSS are shared. | — |
| Homepage uses Inter and a 3px left accent border on status cards | homepage | Owner-confirmed: the homepage service page is exactly as intended | `overused-font=inter` and `side-tab=*` scoped to `custom_apps/node/apps/homepage/**` |
| Fixed-height app shell: `main-content--library` fills the viewport with 55vh catalog scroll regions; empty states stay centered in the tall panel | media-manager | App-like fixed-viewport browsing layout, not a page of cards | — |
| On mobile (`≤920px`) the library panes stack with the detail pane (artwork + editor) ordered above the catalog list, and selecting an item/folder scrolls the window to the top | media-manager | When the desktop side-by-side panes collapse, the artwork belongs in view at the top instead of parked in the opposite/lower pane | — |
| Selected library titles and their containing folders wrap together; selecting a folder also wraps its visible file titles | media-manager | Long names must remain readable at desktop and phone widths | — |
| Missing-image placeholders show checked source availability and device upload controls; subtitle inspection, search, upload and timing tools live in the selected video's library tab | media-manager | Keep related data management beside the selected media; image mutations retain preview and confirmation | — |
| Free metadata access uses a green solid badge; key/account requirements use a brown dashed badge with explicit labels | media-manager | Requirements differ in both colour and appearance without relying on colour alone | — |
| Neutral 3px left "tile" border on `.item-card` list rows | media-manager, mail-archive-ui | Deliberate, commented list-row treatment that reads as a tile, not a panel | — |
| The selected item editor header names the file (or folder) above its tabs | media-manager | The tree highlight is offscreen once the mobile detail pane sits above the catalog list, so the edited target must be explicit | — |
| Guided rename lives in the Metadata tab as a "File organization" section; the editor has no dedicated Rename tab | media-manager | One surface edits both metadata and file name, and removes a redundant top-level tab | — |
| The media image itself opens cover replacement; there are no dedicated Edit image or Edit title quick actions | media-manager | Shortcut buttons duplicated the image and the Metadata tab; image mutations keep their preview and confirmation | — |
| Provider lookup fields prefill with the item's title and author, never ISBN, and stay cleared when emptied | media-manager | Lookups are title-first, and typed/cleared input must not be silently overwritten | — |
| Opening a metadata comparison or a remote artwork preview reveals it at the top of the viewport | media-manager | Both render below long candidate lists and otherwise land offscreen on phones | — |
| Search filters are paired select controls (user, source, content type, date range) plus facet chips for user/source/type and cross-source author, tag, series, and year dimensions; access is admin-only rather than per-source | search (`src/ui.html`) | Admins search everything and narrow with filters; the selects give precise control while the chips expose the result-set composition at a glance. Extractors' differing metadata keys are normalised into one facet vocabulary so every source participates, and the facets live in Solr dynamic fields so adding a dimension needs no schema rebuild. Facet values are rendered via DOM APIs, never interpolated into markup. | — |
| Search results present one uniform card for every source: source badge, title, a highlighted body snippet, a type/owner/date line, then a compact `Label: value` metadata line | search (`src/ui.html`) | Indexed sources (mail, paperless, FreshRSS, browsertrix) and runtime-federated sources (Kiwix native Xapian) are indistinguishable to the user; body text and key metadata appear for all. Unknown metadata keys are title-cased so a new source needs no UI change. | — |

Media health defaults to every visible library and automatically inspects all bounded API pages, with at most three libraries scanning concurrently. Results use effective titles, grouped field comparisons, labelled source alternatives, and collapsible file paths. Audio results group by album (parent folder) into one article per album with per-file review links, so a 30-file audiobook never renders 30 separate warnings; grouped problems carry their affected files inline. Filename-derived guesses remain fallback metadata but do not create conflicts with actual metadata sources. On phones, current and proposed values stack rather than requiring horizontal scrolling. Scan failures preserve other libraries' results and mark totals as incomplete.

The library category controls reuse sidebar symbols in one evenly spaced row. Dual trees use larger centered symbols; selecting a personal or shared item narrows its tree to 45% of the available desktop columns and gives the detail column the full height beside it. Labels appear below icons on hover or keyboard focus and remain visible on phones. Folder metadata starts with Basics/Advanced and the draft action on one row; detailed source inspection lives under Advanced. Audiobook, podcast, and music folders add a Track order table reusing the metadata-comparison table: one row per file with filename, tag, playlist, and effective positions, plus one grouped warning per problem with affected files. Editor cards retain their natural height within the desktop detail scroller, while phones use page scrolling.
