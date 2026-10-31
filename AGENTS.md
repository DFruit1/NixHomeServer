# NixHomeServer – Agent Guidelines

## Purpose

This repository defines a reproducible NixOS home-server focused on:

* Identity & SSO (Kanidm, OAuth2 Proxy)
* Self-hosted apps (Immich, Paperless, Audiobookshelf, Filestash)
* Edge routing (Caddy, Cloudflared, Netbird, Unbound)

## Task Skills

Load the matching skill before the relevant work; prefer the version in the
assigned checkout. Skills supply procedures within the authorized task scope.

| Work | Skill |
| --- | --- |
| Coding, debugging and focused application checks | [nixhomeserver-development](.agents/skills/nixhomeserver-development/SKILL.md) |
| Scoped code review and bounded re-review | [review-loop](.agents/skills/review-loop/SKILL.md) |
| Validation, builds, deployment or recovery | [nixhomeserver-safe-change](.agents/skills/nixhomeserver-safe-change/SKILL.md) |
| Gather unfinished work, complete and integrate it, then deploy | [nixhomeserver-finish-and-switch](.agents/skills/nixhomeserver-finish-and-switch/SKILL.md) |
| Application module boundaries, integrations or removal | [nixhomeserver-module-change](.agents/skills/nixhomeserver-module-change/SKILL.md) |
| Rendered frontend implementation or review | [frontend-design](.agents/skills/frontend-design/SKILL.md) |

Load only relevant skills and references. Shutdown protection is the safe-change
[procedure](.agents/skills/nixhomeserver-safe-change/references/shutdown.md).

---

## Implementation Language

* Prefer Rust for new backend implementations. Use another language only when
  there is a strong technical reason, and document that reason alongside the
  implementation.
* Reuse the repository's existing Rust dependencies and pinned versions where
  they meet the implementation's needs. Add or diverge from dependencies only
  when the existing set is not a suitable fit.

---

## Temp Files and Scratch Space

* Keep temporary files in one task-named `mktemp -d` directory under `/tmp`,
  with cleanup on exit. Use `.tmp/<task>/` only when files must live in the tree.
* Clean up only the exact task directory. Never delete active, dirty, or
  unpublished worktrees or another writer's scratch.
* Never stage plaintext secrets. `secrets/` contains encrypted `.age` only;
  never read or print `secrets/unencrypted/`.
* The scheduled `temp-cleanup` job reclaims only aged development scratch and
  generated output. It never invokes orchestration or prunes worktrees.

## Authority and Coordination

* T3 Code is the only project orchestrator. Use its task/thread tools for
  authorized delegation. Do not install, invoke, or restore other orchestration,
  role, queue, claim, hook, approval, or policy-enforcement systems.
* Current user instructions and this file govern work. Historical commits,
  archived plans, task receipts, external profiles, and persistent memory do
  not grant authority or supply standing policy. Do not load them as agent
  instructions or recreate retired workflows from them.
* Coordinate concurrent writers with isolated worktrees and stable handoffs.
  Preserve unrelated changes. A review task grants no deployment authority.
* Fixes restoring documented behavior and reversible containment are authorized;
  destructive data effects, credential changes, wider public exposure/routing,
  new spending, and reserved build-allocation changes need explicit approval.
* Repair ordinary technical prerequisites within the requested scope. Preserve
  provenance and rollback; never manufacture identity, bypass tool restrictions,
  overwrite shared work, or turn a rejected review into acceptance.
* Ask the user only for a missing owner decision, credentials, physical action,
  or fact unavailable through authorized evidence. Keep technical recovery with
  the acting agent. Do not send external messages without explicit instruction.

## Git Tracking and Committing

* Track each new non-ignored file immediately so Nix sees it. Never track secrets,
  sensitive information, huge unnecessary files, generated artifacts, build output,
  caches, `target/`, `dist/`, `node_modules/` or `result` links.
* Commit your own completed, validated work autonomously. Do not commit or push
  work that fails its owning app/frontend or repository validation gate.
* Before every commit, inspect `git status --short` and `git diff`, then stage
  only the files that belong to the change. Never `git add -A`, `git commit -a`,
  or stash/reset unrelated work. Leave pre-existing user changes untouched and
  uncommitted unless they are explicitly part of the task.
* Prefer one logical change per commit; a coherent session/day is also an
  acceptable boundary. Use an imperative conventional or domain-prefixed subject,
  ~72-column wrapping, and a body when the reason is not obvious. No empty commits.
* Prefer committing validated work before starting a guarded deploy so the
  helper's recorded tested source hash corresponds to a commit.
* Interactive agents push to the configured upstream after committing. If the
  branch has no upstream, push with `-u origin <branch>`. Verify the remote and
  branch are the intended target, and never push secrets.
* Never amend, rebase, force-push, skip hooks, or rewrite published history
  unless the user explicitly asks. Never force-push a shared branch.

---

## Validation, Builds and Deployment

Load `nixhomeserver-safe-change` for gate selection, guarded deployment and
recovery. Use its existing remote evaluation/build/run helpers; allocation and
measurement details live in [Compute Offload](documentation/operations.md#compute-offload-workstation-and-server).

* Default to limited local tests and verification of the changed files and
  behavior: focused regression/unit tests, syntax/lint checks, relevant Nix
  evaluation, and affected UI render checks. Documentation-only edits need
  only diff, link and instruction-consistency checks.
* Create or expand automated tests only for demonstrated repeated regressions
  or a concrete risk of catastrophic outcomes, such as unrecoverable deletion,
  hardware damage or leaked secrets. Record the supporting history or risk in
  the change. Otherwise use existing checks and direct verification.
  This creation rule is separate from execution scope; it does not authorize
  removing existing coverage or bypassing CI and release safety checks. It
  supersedes generic recipes that mandate a new test for every change.
* Run full test suites or broad validation only when the user explicitly asks
  for that scope. This includes repository-wide runners (even the lean gate),
  workspace/all-app tests, full flake checks, broad builds, end-to-end/VM suites,
  and remote validation. A generic request to fix, review, test or finish work
  does not request a full run. Broad or sensitive changes and focused failures
  do not automatically authorize escalation; report the coverage limit instead.
* This test-scope policy supersedes older blanket full-suite/gate requirements
  in skills and runbooks. Focused checks are the ordinary
  commit/review gate. Keep CI configuration and safety checks built into an
  explicitly requested deployment or release intact; such an operation does not
  authorize unrelated suites. Report exactly what ran and what remains untested.
* Ordinary rebuilds use `nix run .#deploy` with the dashboard's default allocation;
  never raw `nixos-rebuild` or build-mode/build-host overrides.
* Changing `buildMode`, `max-jobs`, the `repo-policy` sandbox exclusion or
  credential placement requires its own explicit owner decision.
* Editing or validating does not authorize live activation. Follow the deployment
  procedure below, and commit validated source before deploying where possible.
* If deployed-server sudo interaction is unavoidable, use the root-only agenix
  `serverBootstrapSudoPassword` at `/run/agenix/serverBootstrapSudoPassword`.
  Never display it or rely on a remembered password.

---

## Android Releases

* The external interactive release operator (an authorized interactive agent or
  the human owner) completes Android releases with the app's `pnpm release:android`
  command: build, sign, publish to private F-Droid and IPFS, then verify both
  indexes. Existing authorization for that release includes publication; do not
  ask again. For intermediate validation use `--build-only`; a validated build
  is not a completed release and must not be reported as one.
* Keep the Android version code higher than the published version and sign with
  the existing app key so phones can update the installed app.

---

## Native Browser for App Sign-in

* Always open OAuth/OIDC sign-in and other external links in the operating
  system's default browser through a native intent, never in an embedded WebView
  or an Android Chrome Custom Tab. Kanidm passkeys (WebAuthn) need a full
  browser context and fail to register or authenticate inside WebViews and
  Custom Tabs.
* In Tauri apps, call the opener with no `with` target
  (`open_url(url, None::<&str>)` / `openUrl(url)`). The `"inAppBrowser"` option
  maps to `CustomTabsIntent` on Android and must not be used for sign-in.

---

## Phone Wi-Fi Access Troubleshooting

Private hosts such as Photos and Videos use LAN/NetBird DNS. Confirm the phone's
resolver/VPN state and LAN path before changing services or exposure. Follow
[the phone Wi-Fi procedure](documentation/operations.md#phone-wi-fi-access).
Do not publish a private hostname or alter the Cloudflare tunnel as a workaround
without first confirming the DNS and LAN path.

---

## Module Structure

Load `nixhomeserver-module-change` for the application contract and removal checks.
Application removal must preserve unrelated functionality and retained data.
`Core_Modules` are always present; central impermanence owns persistence, which
remains until explicitly removed there.

### Model artifacts

* Store downloaded inference weights on the data pool under
  `${dataRoot}/<application>/models`, rather than in system-SSD persistence.
* Disabling or removing a model application retains its weights there as a
  reusable archive. Do not automatically delete archived model files.
* Keep model metadata, databases and configuration in central persistence and
  regular backups. Global Kopia policy excludes `*.gguf` and `*.gguf.part` from
  every snapshot root mirrored to MEGA. Irreplaceable or fine-tuned GGUF weights
  require a separate explicitly configured backup.

---

## Deployment Procedure

Editing or validation does not authorize live activation. For an explicitly
requested deployment, review the complete intended source change, resolve
required findings, and commit validated source before deployment where possible.
Use T3 Code for any authorized independent review; no external decision receipts,
role assignments, or task database are required.

From unchanged reviewed source, run `nix run .#deploy -- --action test`, then
`nix run .#deploy -- --action switch` only after a matching green test. Changed
source or mutable inputs require fresh affected review/checks and a new guarded
test. Retain health checks, tested-closure checks, boot-state checks and rollback
protection. Never bypass the helper or change allocation to obtain a pass.

## Repo Map (read this before exploring)

* `modules/catalog.nix` — single source of truth for apps, integrations, owned secrets, and guarded services. Start here for any app change.
* `modules/<app>/` — one directory per removable application. Facets: `default.nix`, `identity.nix`, `networking.nix`, `filepaths.nix`, `services.nix`, `bootstrap.nix`, `package.nix`, `backups.nix`. Read `default.nix` + the facet you are changing; do not read all facets.
* `modules/Core_Modules/` — always-present platform services (storage, impermanence, kanidm, kopia, backups, monitoring, auth-gateway). Treat as trusted invariants.
* `modules/Integrations/` — behavior gated on multiple optional apps; never imported unconditionally.
* `lib/` — validation and derived-value helpers (`derive-vars.nix`, `identity-access.nix`, `*validation.nix`).
* `flake/` — system/package/check/app assembly. `checks.nix` wires the test gates.
* `custom_apps/` — first-party apps: `rust/apps/*` (media-manager, mail-archive-ui, kanidm-canary-bootstrap), `node/apps/*` (homepage, groundwater-logger, youtube-downloader), `mkvmaker`.
* `.agents/skills/` — six project entrypoints; see [skill routing](documentation/agent-skills.md). `.agents/vendor/` holds non-discoverable UI knowledge and the pinned Impeccable detector, consumed only through frontend-design references.
* `DESIGN_SYSTEM.md` — living record of frontend surfaces and deliberate design decisions; the precedent Impeccable detectors must respect.
* `.impeccable/config.json` — shared Impeccable config; narrowly scoped detector exceptions live here.
* `scripts/` — deploy, admin, helpers, and `tests/` (shell regression suite). `tests/test-common.sh` holds shared helpers; `validate-repo.sh` provides opt-in repository gates.
* `secrets/` — agenix-managed encrypted `.age` files only. Never read or print plaintext `secrets/unencrypted/`.
* `documentation/` — operator runbooks. `operations.md` is the most commonly relevant.

## Do Not Read (unless debugging a specific issue)

These are large, generated, or low-signal. Target reads instead:

* Lock/dependency files: `Cargo.lock`, `pnpm-lock.yaml`, `flake.lock`, `nuget-deps.json`, `*.tsbuildinfo`.
* Generated frontend assets and bulk build output: `dist/`, `target/`, `node_modules/`, `*.map` files.
* Bulk fixture data: `modules/.../plugin-tests/*.cs` and `nuget-deps.json` unless working on that exact dependency.
* `secrets/unencrypted/` plaintext staging.
* `openapi.yaml`/generated schemas unless the API boundary is the task.

If a broad search is needed, prefer `rg`/`glob` (they skip gitignored files) over full-directory reads.

---

## Frontend Design Workflow

* Do not replace, redraw, restyle, or substitute any Homepage logo without the
  owner's explicit consent for that logo change. Preserve approved assets during
  unrelated work. Update logo regression pins only for explicitly approved changes.

Load `frontend-design` for every rendered UI change or review. It owns UI/UX Kit
implementation, focused review, desktop/mobile rendering and scroll checks,
media-manager coverage and the stopping condition. Project anti-slop rules and
`DESIGN_SYSTEM.md` take precedence over generic toolkit preferences. Impeccable
stylistic enhancement commands still require an explicit user request.

## UI Information Architecture and Restraint

This section refines the project anti-slop rules for information architecture.
It applies to every rendered surface, but is especially important for admin and
operations UIs (including the homepage Admin Dashboard), where dashboard sprawl
is the default failure mode.

Design for information value, task efficiency, and clarity rather than visual
fullness. A good interface does not need to fill every available space. The
Admin Dashboard exists only because of an explicit owner request for operational
visibility; that does not exempt its widgets from this rule.

- Every visible element must justify its presence by helping the user
  understand something important, make a decision, or perform an action.
  Otherwise omit it.
- Do not automatically introduce KPI cards, statistic counters, summary tiles,
  decorative panels, or dashboard-style layouts. A widget that only restates
  data already shown elsewhere is not justified.
- Use cards only where meaningful grouping, interaction, or visual separation
  is required. Do not use cards simply to make the UI look designed. Prefer
  coherent sections, well-structured tables, lists, forms, restrained dividers,
  and whitespace over grids of repetitive cards.
- Avoid unnecessary subtitles, eyebrow labels, helper descriptions, motivational
  copy, and one-line explanatory text below self-explanatory headings. Do not
  repeat the same information in a heading, subtitle, card, badge, and
  description.
- Do not invent statistics, counts, trends, or other UI content simply to
  occupy space or establish visual balance. If a real metric is unavailable,
  show "unknown" rather than a placeholder.
- Give primary user tasks visual priority. Secondary information should be
  visually quieter or progressively disclosed.
- Maintain useful information density. Minimalism means removing low-value
  elements, not making everything oversized or sparse.
- Do not add an overview, analytics, or status section unless a real user
  requirement exists and is recorded (for example in `DESIGN_SYSTEM.md` or the
  proposal). When modifying existing interfaces, preserve established
  functionality and information hierarchy unless a change is justified.
- Cross-check new widgets against the existing `/admins` command reference and
  service pages to avoid duplicating information that already has a home.

### Mandatory Design Review

Before finalising a UI, inspect every card, metric, label, description, and
decorative component. Ask: What concrete user need does this serve? Could the
interface communicate the same information more directly with fewer elements?

Remove or consolidate elements that fail this test. Prefer the simplest interface
that fully supports the intended workflows. This review complements, and does not
replace, the Impeccable `critique`/`audit` pass required by `frontend-design`.

---

## Performance Conventions

* Qwik apps build with the default entry strategy (per-symbol/segment chunking).
  Do not force `entryStrategy: { type: "single" }`; if a specific app needs it,
  document the build reason next to the config.
* Content-hashed static assets ship with immutable caching. Use
  `homelab_common::cache_control_for_path` (Rust) or `staticCacheControl`
  (`custom_apps/node/shared/http-protocol.ts`) rather than hardcoding headers.
  HTML must revalidate (`no-cache`); service workers stay `no-cache`.
* Services that terminate their own Caddy vhost must add `encode zstd gzip`;
  protected gateway hosts already compress text and API responses. Media streams
  keep byte-range semantics because compressible content types exclude them.
* Shared platform databases and caches are tuned centrally in
  `system-resources.nix`, gated on the owning app's option. Never read
  `services.redis.servers` inside a condition that defines it (recursion), and
  never set `services.postgresql.settings` from an optional module.
* Long-running or bursty services need `MemoryHigh`/`MemoryMax`, and maintenance
  jobs need `Nice`/`CPUWeight`/`IOWeight`. Keep expensive periodic work (full
  database copies, store walks) at the lowest cadence that satisfies its
  consumer, checked before the expensive operation, not after.

---

## Test Tiers

`nixhomeserver-safe-change` selects limited local checks by default. Repository
gates (`scripts/validate-repo.sh`, including lean), `--full`, `--all-apps` and VM
tests (`--run-vm-tests`, requiring `/dev/kvm`) require an explicit user request
for that scope. If a requested run is long, protect a pending shutdown through
the safe-change shutdown procedure. Interrupted runs are never a pass.

## Service-Access Canary

* Every new user-facing app or private browser host needs a target in
  `modules/Core_Modules/homepage/canary.nix`; follow `nixhomeserver-module-change`.
* `scripts/tests/test-canary-target-coverage.sh` (lean tier) fails when an
  enabled Caddy host is neither covered nor listed in
  `repo.canary.coverageExemptHosts`. Add an exemption only for surfaces that are
  not independently browser-loginable (identity provider, gateway login,
  embedded editors, public shares, API-only or device-local UIs) and document
  the reason.
* After deploying a new app, run and inspect the authenticated canary as required
  by `nixhomeserver-safe-change`. A green deploy is not proof of access.
