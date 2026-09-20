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
| Missing-image placeholders show checked source availability and device upload controls; subtitle inspection, search, upload and timing tools live in the selected video's metadata editor | media-manager | Keep related data management beside the selected media; image mutations retain preview and confirmation | — |
| Free metadata access uses a green solid badge; key/account requirements use a brown dashed badge with explicit labels | media-manager | Requirements differ in both colour and appearance without relying on colour alone | — |
| Neutral 3px left "tile" border on `.item-card` list rows | media-manager, mail-archive-ui | Deliberate, commented list-row treatment that reads as a tile, not a panel | — |
| The selected item editor header names the file (or folder) | media-manager | The tree highlight is offscreen once the mobile detail pane sits above the catalog list, so the edited target must be explicit | — |
| Guided rename lives in the metadata editor as a "File organization" section; there is no dedicated Rename view | media-manager | One surface edits both metadata and file name, and removes a redundant top-level view | — |
| The library detail pane exposes only Play and Metadata actions; the Metadata action reveals a single editor holding the remote sources and the edit fields | media-manager | Replaces the Explore/Metadata/Rename/Subtitles tab strip and the extra quick actions with one predictable entry point, identical from the library and from Metadata health's "Review metadata" link | — |
| Remote metadata sources render as collapsed accordions grouped in one card above the metadata fields, each with a one-line summary and a short provider badge | media-manager | Full provider panels were several screens tall on phones; collapsed rows keep the sources discoverable without burying the fields | — |
| Subtitle management is a collapsed disclosure inside the metadata editor for video items | media-manager | Keeps subtitle tools available without a separate top-level tab or extra action button | — |
| The media image itself opens cover replacement; there are no dedicated Edit image or Edit title quick actions | media-manager | Shortcut buttons duplicated the image and the Metadata tab; image mutations keep their preview and confirmation | — |
| Provider lookup fields prefill with the item's title and author, never ISBN, and stay cleared when emptied | media-manager | Lookups are title-first, and typed/cleared input must not be silently overwritten | — |
| Opening a metadata comparison or a remote artwork preview reveals it at the top of the viewport | media-manager | Both render below long candidate lists and otherwise land offscreen on phones | — |
| The editor header marks a file or folder with an icon (no `FILE`/`FOLDER` word) and keeps the name left-aligned and vertically centred | media-manager | The name is the edited target; the icon carries the type without a label competing with it | — |
| Portable metadata is a single opt-in checkbox with a `?` help panel; the preview action and its "Sources:" note appear only once a draft exists and the preview button is centred | media-manager | Replaces the Advanced consumer/modification-target cards and the always-on preview control with one decision and its explanation | — |
| Every media application declares a `sourcePriority` read order (sources and priority) in the registry; the sidecar help lists each consumer's declaration | media-manager | Users can see exactly where Jellyfin, Audiobookshelf, or Kavita reads metadata and in what order | — |
| Search filters are paired select controls (user, source, content type, date range) plus facet chips for user/source/kind/type and cross-source author, tag, series, and year dimensions; access is admin-only rather than per-source | search (`src/ui.html`) | Admins search everything and narrow with filters; the selects give precise control while the chips expose the result-set composition at a glance. Extractors' differing metadata keys are normalised into one facet vocabulary so every source participates, and the facets live in Solr dynamic fields so adding a dimension needs no schema rebuild. The kind dimension separates emails, books, web pages and archives using the extractor's `kind`. Facet values are rendered via DOM APIs, never interpolated into markup. | — |
| Search results present one uniform card for every source: source badge, title, a highlighted body snippet, a type/owner/date line, then a compact `Label: value` metadata line | search (`src/ui.html`) | Indexed sources (mail, paperless, FreshRSS, browsertrix) and runtime-federated sources (Kiwix native Xapian) are indistinguishable to the user; body text and key metadata appear for all. Unknown metadata keys are title-cased so a new source needs no UI change. | — |
| Keys & Secrets groups Syncthing, FreshRSS and Kavita under one "App passwords" heading with each app as a subheader, and keeps SFTP/SSHFS keys under a separate "Device keys" heading | homepage (`src/routes/keys`) | The three app credential types are one concept for non-technical users; a single group with app subheaders conveys more with less text, while device keys stay distinct because they belong to the user's hardware rather than an app. | — |
| The vault "Checking vault status…" hint is rendered only on the client (`loading` starts false and is set by the client task), never in SSR output | homepage (`src/routes/keys/index.tsx`) | The server cannot know the vault status during SSR; emitting the hint in the server HTML left a stale "Checking vault status…" node after hydration even when the vault was unlocked. | — |
| The vault gate shows the Kanidm logo and a lock/unlock status pill that changes with the unlock state | homepage (`VaultGate.tsx`, `public/logos/kanidm.svg`) | The second sign-in is a Kanidm identity check, so attributing it to Kanidm and showing the lock state as a symbol plus text makes the security model legible without relying on colour. | — |
| SFTP device keys are generated natively in the browser (Web Crypto Ed25519, OpenSSH encoding) with the private key downloaded locally; only the public key is sent to the server | homepage (`VaultSshKeysCard.tsx`, `src/shared/ssh-keygen.ts`) | Non-technical users should not need to run `ssh-keygen`; generating on-device keeps the private key off the server while the server only ever stores the public key. | — |

Media health defaults to every visible library and automatically inspects all bounded API pages, with at most three libraries scanning concurrently. Results use effective titles, grouped field comparisons, labelled source alternatives, and collapsible file paths. Audio results group by album (parent folder) into one article per album with per-file review links, so a 30-file audiobook never renders 30 separate warnings; grouped problems carry their affected files inline. Filename-derived guesses remain fallback metadata but do not create conflicts with actual metadata sources. On phones, current and proposed values stack rather than requiring horizontal scrolling. Scan failures preserve other libraries' results and mark totals as incomplete.

The library category controls reuse sidebar symbols in one evenly spaced row. Dual trees use larger centered symbols; selecting a personal or shared item narrows its tree to 45% of the available desktop columns and gives the detail column the full height beside it. Labels appear below icons on hover or keyboard focus and remain visible on phones. Folder metadata starts with Basics/Advanced and the draft action on one row; detailed source inspection lives under Advanced. Audiobook, podcast, and music folders add a Track order table reusing the metadata-comparison table: one row per file with filename, tag, playlist, and effective positions, plus one grouped warning per problem with affected files. Editor cards retain their natural height within the desktop detail scroller, while phones use page scrolling.
