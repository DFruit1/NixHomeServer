# Repository cleanup audit

Audited 2026-11-12 against `36f4e87fdae9e9e4088b7b63093a683a816494db`.

## Scope and method

Inventoried all 1,888 tracked paths. Checked the application catalog and module
imports, Rust workspace membership and dependency declarations, application
manifests, source-file and exported-symbol references, static assets, scripts,
and duplicated files. Followed candidate references into their consumers before
removing anything. Tests, framework entry points, convention-discovered files,
and dynamically selected assets were not classified as dead from missing literal
references alone.

This is a static repository audit, not proof of production usage. Generated
output, dependency trees, bulk fixtures, and plaintext secrets were excluded.
Vendored tooling and the retired-skills archive were inventoried, not treated
as active project instructions or exhaustively audited internally. No live
server inspection, full repository gate, deployment, or Android release ran.
Concurrent edits outside this cleanup were preserved.

## Removed

Every affected existing file matched its committed copy before editing or
removal. All removed content is recoverable from the revision above; no
untracked or unpublished content was deleted.

| Location | Removed content and evidence |
| --- | --- |
| `custom_apps/node/apps/homepage/src/components/AppSetupCard.tsx` | Component with no imports, re-exports, or dynamic consumers in the app. |
| Homepage `src/client/styles.css` | The five `.app-setup-grid` / `.app-setup-card` rules belonging only to that component. Shared `.steps` and `.open-link` styles remain. |
| Homepage `src/components/dashboard/registry.tsx` | Uncalled `findWidgetDefinition`; the widget registry itself remains in use. |
| Homepage `src/shared/ui-types.ts` | Unreferenced `NavigateHandler`, `GuideChangeHandler`, and `PublicKeyInputHandler` types. |
| YouTube Downloader `src/server/paths.ts` | Uncalled `uniqueFolder` wrapper; the active `allocateUniqueFolder` implementation remains. |
| YouTube Downloader `src/shared/types.ts` | Unreferenced `CreateJobResponse` type; runtime response behavior is unchanged. |
| Browsertrix frontend `src/shared/url.ts` | Unreferenced `CRAWL_SCOPES` constant. |
| Groundwater frontend `src/config.ts` | Unreferenced `DANGER_COMMANDS` and `CFG_LABELS` constants. The active command allowlist `CFG_KEYS` remains. |
| Media Manager frontend | Uncalled `sourceStatusClass` in `health-source-recommendation.ts` and unreferenced `EditorTab` in `item-editor-helpers.ts`. |
| `custom_apps/Cargo.toml` | Unused synchronous `postgres` workspace dependency declaration. Members use `tokio-postgres`; no lockfile or member dependency changed. |
| `modules/Core_Modules/kanidm/assets/` | Old `audiobooks.svg`, `files.svg`, `mail.svg`, `passwords.svg`, `photos.svg`, and `videos.svg`, with no file references or directory-based loader. Identity facets reference `assets/apps/`; `launcher.nix` selects approved Homepage assets via each catalog card. The referenced `portal.svg` remains. |

## Retained candidates and constraints

- **AI Office path adapters:** `custom_apps/rust/apps/ai-tools/src/main.rs`
  explicitly retains legacy adapters/tests and suppresses dead-code warnings for
  `office` and `office_write`. Some path-resolution and path-based conversion
  methods are candidates for a focused follow-up. Do not delete those modules
  wholesale: `office_tools.rs` still uses `office::Converter` and `format_for`,
  and the gateway uses `office_write::Helper`. Keep the identity-free denial
  handlers and broker authorization checks. Retiring the old path entry points
  needs a call-level review that preserves existing security coverage.
- **Ventoy helper:** `scripts/helpers/normalize-ventoy-kernel-cmdline.sh` has no
  tracked callers or documentation references. It translates `vtinit=` to
  `init=`. It may be a standalone recovery utility; repository evidence cannot
  establish whether an external boot/recovery procedure invokes it. Retained.
- **Older Homepage CSS:** selectors such as `.admin-accordion*`,
  `.admin-command-category*`, `.group-picker*`, `.folder-grid`, and
  `.getting-started-checklist` have no exact class-token references outside the
  stylesheet. These are candidates, not confirmed dead styles: review compound
  selectors, dynamically generated names, and cascade effects before removal.
- **Retired skills:** `documentation/archive/skills/` is already an archive
  (23 tracked files). It can remain outside active discovery. No further archive
  copy was created; Git already preserves the removed source in this cleanup.
- **Duplicate logos:** Homepage, File Sync, and Kanidm keep matching logo files.
  Identity facets, branding checks, and separate app packaging reference them.
  Duplication alone does not make them safe to delete. Homepage logos, including
  `prowlarr.png` documented in `public/logos/SOURCES.md`, were left untouched
  under the explicit owner-consent rule.
- **Tests without literal callers:** Rust integration tests, C# test files, and
  frontend test files are convention-discovered. The Filestash transfers test is
  not named in the script runner, but it covers a current public-share boundary;
  lack of runner wiring is not evidence that the test or feature is obsolete.
- **Optional applications and migrations:** every removable application directory
  is registered in `modules/catalog.nix`. Disabled applications, database
  migrations, retired identity-group reconciliation, and model-archive migration
  code remain useful for re-enablement, upgrades, or recovery. No application,
  persistent data, secret, routing, or storage configuration was removed.

## Verification

- `pnpm run typecheck` passed in Homepage, YouTube Downloader, Browsertrix frontend,
  Groundwater frontend, and Media Manager frontend.
- Focused existing Vitest files passed: Homepage `homepageLogos.test.ts` (1) and
  `adminDashboard.test.ts` (32); YouTube Downloader `paths.test.ts` (7);
  Browsertrix `url.test.ts` (9); Groundwater `config.test.ts` (7);
  Media Manager `health-source-recommendation.test.ts` (6). Total: 62 tests.
- `cargo metadata --manifest-path custom_apps/Cargo.toml --no-deps
  --format-version 1 --locked --offline` passed.
- Reviewed the scoped diff, checked removed-symbol references and asset consumers,
  and ran `git diff --check`. Frontend changes have no intended rendered effect;
  no browser verification was performed.

Full builds, full suites, independent review, production usage, and externally
invoked scripts remain unverified. These checks establish the focused cleanup's
source consistency, not the absence of all possible dead code in the repository.

## Follow-up cleanup: 2026-11-12

Reviewed against `77ff92e08100b5d388a613c85290f53ad97f73b8`. Every changed
source file matched its committed copy before editing; concurrent Media Manager
and other unrelated work was excluded.

### Further removals

- Homepage: removed 113 unused selector entries (84 complete rules, 574 lines)
  for retired admin accordions, command categories, intent controls, group pickers,
  folder layouts, old setup checklists, and guide navigation. Checked their class
  names against tracked implementation files and inspected the actual class-name
  generators. Dynamic `is-*` states and `app-symbol--*` variants were retained.
  Mixed selector lists retain all their live selectors and declarations.
- AI Office: removed the unreachable `Converter::convert` and `convert_to`
  path-based wrappers. No call sites or tests invoked them; active Office tools
  call `convert_bytes` after broker authorization. Removed the unused
  `office_write::{MAX_INPUT_BYTES, MAX_WRITE_BYTES, HELPER_TIMEOUT}` constants
  and their unused `Duration` import. Runtime limits remain enforced by
  `office_io`, `office_process`, and the byte-based converter.
- Existing path-resolution and file-reading tests remain intact. Their tested
  helpers and the Office denial handlers were preserved. The remaining legacy
  adapters were not deleted merely because their current consumers are tests.

This resolves the older-CSS candidate above and removes only the confirmed
unreachable part of the Office candidate. The Ventoy helper and retained assets
remain unchanged.

### Focused verification

- PostCSS parsed the changed stylesheet. Comparing the original and resulting
  syntax trees confirmed all 615 retained selector entries keep exactly the
  same declarations, relative order, and enclosing media conditions.
- Homepage `pnpm run typecheck` passed; focused `adminDashboard.test.ts`,
  `homepageData.test.ts`, and `homepageLogos.test.ts` passed (42 tests).
- `cargo test --manifest-path custom_apps/Cargo.toml --locked --offline
  -p ai-tools office`: 32 passed, 1 existing ignored test requiring a user
  namespace/capability setup. The parser sandbox test also passed in its child
  process. No existing test was removed or weakened.
- The same Cargo command with filter `denial`: 5 passed.
- `cargo check --manifest-path custom_apps/Cargo.toml --locked --offline
  -p ai-tools` passed for the production configuration.
- `rustfmt --edition 2024 --check` passed for the two changed Rust files.
- Direct comparisons confirmed the active converter, helper implementation,
  and both existing Rust test modules are byte-for-byte unchanged.
- Scoped diff review and `git diff --check` passed. Changes have no intended
  rendered effect, so verification used source and CSS syntax-tree checks.

No full suites, remote validation, browser runs, independent review, live
activation, or Android release were performed.
