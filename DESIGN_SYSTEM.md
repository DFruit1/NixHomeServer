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
| — | — | — | — |
