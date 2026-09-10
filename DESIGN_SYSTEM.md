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
| Neutral 3px left "tile" border on `.item-card` list rows | media-manager, mail-archive-ui | Deliberate, commented list-row treatment that reads as a tile, not a panel | — |
