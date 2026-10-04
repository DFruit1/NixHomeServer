# NixHomeServer – Agent Guidelines

## Purpose

This repository defines a reproducible NixOS home-server focused on:

* Identity & SSO (Kanidm, OAuth2 Proxy)
* Self-hosted apps (Immich, Paperless, Audiobookshelf, Filestash)
* Edge routing (Caddy, Cloudflared, Netbird, Unbound)

---

## Implementation Language

* Prefer Rust for new backend implementations. Use another language only when
  there is a strong technical reason, and document that reason alongside the
  implementation.
* Reuse the repository's existing Rust dependencies and pinned versions where
  they meet the implementation's needs. Add or diverge from dependencies only
  when the existing set is not a suitable fit.

---

## Git Tracking and Committing

* Ensure all new git files (except for those in .gitignore) are tracked as soon as they are created to avoid visibility issues during nix rebuilds
* Avoid tracking huge files and directories that do not need to be tracked, such as build directories or caches
* Do not track plaintext secrets or other sensitive information
* Agents are authorized to stage, commit, and push their own completed work
  without asking on each change. Commit and push autonomously once a logical
  unit of work is complete and its applicable validation gate passes.
* Before every commit, inspect `git status --short` and `git diff`, then stage
  only the files that belong to the change. Never `git add -A`, `git commit -a`,
  or stash/reset unrelated work. Leave pre-existing user changes untouched and
  uncommitted unless they are explicitly part of the task.
* Do not commit or push work that fails the relevant gate (`validate-repo.sh`,
  `validate-repo.sh --full`, or the owning app/frontend test).
* One logical change per commit is the default, but multiple changes may be
  merged into the same commit when that simplifies the history. A block of work
  bounded by a time period (for example a session or a day) is an acceptable
  commit boundary in place of individual features or hunks.
* Commit messages: imperative subject, ~72-column wrap, conventional prefix
  where it fits (`feat:`, `fix:`, `docs:`, `test:`, `refactor:`, `chore:`) or a
  domain prefix (`opencloud:`, `media-manager:`, `kanidm:`). Add a body when the
  reason is not obvious from the subject.
* Prefer committing validated work before starting a guarded deploy so the
  helper's recorded tested source hash corresponds to a commit.
* Push to the configured upstream after committing. If the branch has no
  upstream, push with `-u origin <branch>`. Verify the remote and branch are the
  intended target, and never push secrets.
* Never amend, rebase, force-push, skip hooks, or rewrite published history
  unless the user explicitly asks. Never force-push a shared branch.
* Do not create empty commits, and do not commit generated artifacts, caches,
  `target/`, `dist/`, `node_modules/`, or `result` links.

---

## Rebuild Command

* Prefer the guarded deploy helper for rebuild. 
* Use the guarded helper's default allocation so the dashboard-selected build
  mode applies: run `nix run .#deploy -- --action test|switch` (or
  `scripts/deploy.sh` with the same arguments) without `--build-mode`,
  `--build-locally`, or `--build-host`. Do not run raw `nixos-rebuild` for an
  ordinary rebuild; it bypasses the dashboard and silently falls back to the
  `vars.nix` default.
* Rebuilds including nix drv and rust build artifacts should be done on the remote server when possible.
* The deployed bootstrap sudo password is stored as the root-only agenix
secret `serverBootstrapSudoPassword`, which materializes at
`/run/agenix/serverBootstrapSudoPassword` on the server. If an interactive sudo
prompt is unavoidable, refer to that secret rather than relying on memory.

---

## Android Releases

* After validating a release build of any Android APK, publish it to the private
  F-Droid repository and its IPFS mirror. Use the app's `pnpm release:android`
  command, which builds, signs, publishes, and verifies both indexes. Use
  `--build-only` only for intermediate validation builds; it does not complete
  a release. Do not leave a completed release APK unpublished or ask whether to
  publish it.
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

Private application hosts such as Photos and Videos are served through the
LAN/NetBird DNS and are not public Cloudflare routes. If a phone can reach an
application over NetBird but a host that previously worked stops responding on
home Wi-Fi, first suspect the phone's resolver or VPN state rather than the
NixOS service. Toggle Wi-Fi off and on; if needed, connect NetBird, confirm the
application works, disconnect NetBird, and retry. This can force the phone to
reinitialize its VPN/DNS state and restore the normal Wi-Fi resolver.

If the reset helps, check that the phone's Wi-Fi DNS is the home router or the
server's LAN DNS, and that the phone is not on a guest or client-isolated SSID.
Do not publish a private application hostname or alter the Cloudflare tunnel as
a workaround without first confirming the DNS and LAN path.

---

## Module Structure
* Modules are individual applications and their configuration. The repo should be designed in such a way that removal of a module does not break any functionality whatsoever 
* Core_Modules are always assumed to exist in the config and aren't normally modified or removed. Therefore, other modules and config can always assume these modules will exist.
* Impermanence should always be centrally defined within core modules to prevent accidental data deletion on module removal. Module data should be persisted unless explicitly removed within the central impermanence module. 

---

## Kanban Card Authoring

Hermes injects this file into every agent working in a checkout or worktree, so
this is the single home for the board's card conventions. Any profile may create
a card — the dispatcher appends the kanban lifecycle tools to every worker, not
just the orchestrator — so these rules bind all of them.

The first reader of a card is a human deciding whether to approve it, in a
column view, usually mid-review of something else. Write for that reader.

### Budget

**Title** — imperative, under 60 characters, names the outcome. It is the
card's label in every column, so it must be distinguishable at a glance from its
siblings. `Fix: expire orphaned deploy archives in a private staging dir`, not
`Address M6 from audit t_d05010f1`.

**Body** — at most **15 lines and 1000 characters**. Fixed slots, in this order,
so the eye lands in the same place on every card:

```
Goal: <one line, under 90 chars — the concrete change or decision>
Change: <file:line> — <what changes>
Verify: <exact command> — <expected exit code>
Constraints:
- <one per line, under 90 chars>
Notes:
- <hash, count, or figure the ask itself does not need>
```

`Notes:` is optional. Drop it rather than pad it.

### If it does not fit, split it

A card that overruns the budget is two cards. Split it with `parents=` and let
the dependency do the waiting — never compress prose to fit. Bundling is the
defect, not verbosity: if the `Goal` line needs the word "and", it is two asks.

### Prose hygiene

* **Code and figures never sit inside a sentence.** A path, hash, count, file
  mode, or command gets its own line or a `Notes:` bullet. Woven into a clause,
  the reader has to parse it back out before they can act on the sentence.
* **One idea per line.** "Do A, and B, but never C" is three lines, not one
  200-character sentence.
* **Keep lines under 90 characters** so they wrap in a narrow detail pane instead
  of running off it.
* **Say it once.** A constraint restated in `Constraints:` and again in a
  paragraph means the paragraph is deletable.

### Never in a body

* Provenance — `Decision t_258bbbce from audit t_d05010f1:` says nothing the
  `blocked by` field does not already show.
* The audit's reasoning — it lives in the audit report. One clause, then move on.
* Call-site dumps — `sudo call sites: :324, :327, :491, :533…` is unreadable at a
  glance and redundant with grep. Name the file and say how many.
* Commit-hash lists or dependency prose — `git log` knows the hashes, and the
  board renders parents and `blocked by` on its own.
* Rules already in this file — the commit and push gate, the test tiers, and
  workspace discipline are injected into every agent regardless.
* An acceptance checklist that restates the body. The `Verify:` line plus at most
  four `Constraints:` lines are the whole definition of done.

### Card shape per lane

| Lane | Shape |
|---|---|
| `planner` | Implementation cards use the slots above. An audit card states the **question**, not a proposed solution, plus the evidence already in hand. A card carrying an attached `project-review` plan is implemented from that plan: the `Goal:` is the plan's outcome and `Notes:` carries its `REVIEWER:` / `HUMAN:` questions, never a re-derivation. |
| `feature-auditor` | The body is a question: name the slice and the single question to answer. No solution, no fix plan. |
| `reviewer` | A diff review puts the verdict in `Goal:` and the commits in `Notes:`. A **question card** is one bounded question instead: `Goal:` is the question, `Notes:` is the evidence and what the answer changes. Same slot order either way. |
| `bulk-go`, `local-impl` | A follow-up card is a one-line `Goal:` plus the single acceptance criterion the new work must satisfy. The parent card already holds the context. |
| `project-review` | Never assign a card to it; it runs by hand in a conversation. Its one handoff card goes **to** `planner` and carries the plan as an attachment, so `Change:` names the attached plan rather than inlining it. |
| any lane, human gate | Use the template below. |

### Approval gates

A gate is the worst case, because a human is being asked to authorise something
irreversible. Put the question first, with options:

```
Decision needed: <the question, as a choice>
Options:
  A) <option> — <consequence in a few words>
  B) <option> — <consequence in a few words>
If neither: <what you would need to design the third>
Context: <one or two sentences, with file:line>
Constraints: <what must not change>
```

Do not bury the question under the evidence that produced it.

### Worked example

A real 4,364-character card opened like this:

> **Design and scope** — Use exactly /var/lib/nixhomeserver-deploy-archives as
> the dedicated sibling archive directory, outside root-only
> /var/lib/nixhomeserver-deploy. Preserve root:root 0700 transaction/stamp
> ancestry and root-only stamp files. Archive directory remains 0700 owned by
> configured localAdminUser; staged archives remain 0600. Keep independent
> systemd-tmpfiles mM:48h expiry, immediate constrained cleanup and fail-closed
> no-fallback behavior. Do not widen sudo, add ACLs, chmod/chown existing
> deploy-state, switch SSH to root, or add raw rebuild workarounds.
>
> **Baseline** — Current tested composition on wt/t_75be1a28 is base efee182
> plus 5e1a9672fca556aba47f552d01816a4360e74865, 0c25462a…, 37c2f008…,
> d0994df5…, e9310b3a…

Four sentences of chained imperatives, six inline negatives, five hashes, and a
whole section of hashes `git log` already knows. The same card:

```
Goal: Move deploy archives out of root-only state into a sibling namespace.
Change: modules/Core_Modules/deploy/default.nix:412 — namespace + tmpfiles mM:48h
Verify: bash scripts/tests/test-deploy-archive-permissions.sh — 0
Constraints:
- Archive dir 0700 localAdminUser; staged archives 0600
- Root:root 0700 transaction/stamp ancestry unchanged
- No sudo widening, ACLs, chown of existing state, or root SSH
- Fail closed; no /tmp fallback
Notes:
- Baseline on wt/t_75be1a28: efee182 5e1a967 0c25462 37c2f00 d0994df e9310b3
- New path needs rollout; offline tests do not establish live safety
```

Eleven lines. Every constraint survived; the prose did not.

### Answering a gate

A comment does not change card status. Record the decision as a comment, then
unblock — the dispatcher only claims `ready` cards, so an unanswered `blocked`
card never runs, and a commented-but-still-blocked card never runs either. A
`running` card needs only the comment: the dispatcher live-steals new operator
comments into the worker.

### Triage auto-decompose is off

The gateway can write cards from a hardcoded prompt inside the upstream hermes
clone, which cannot read this file. That path is disabled with
`kanban.auto_decompose: false` in `~/.hermes/config.yaml`, so every card on the
board is written by an agent that has read this section. Leave it off; the
`hermes kanban specify` and `decompose` verbs have the same blind spot.

---

## Repo Map (read this before exploring)

* `modules/catalog.nix` — single source of truth for apps, integrations, owned secrets, and guarded services. Start here for any app change.
* `modules/<app>/` — one directory per removable application. Facets: `default.nix`, `identity.nix`, `networking.nix`, `filepaths.nix`, `services.nix`, `bootstrap.nix`, `package.nix`, `backups.nix`. Read `default.nix` + the facet you are changing; do not read all facets.
* `modules/Core_Modules/` — always-present platform services (storage, impermanence, kanidm, kopia, backups, monitoring, auth-gateway). Treat as trusted invariants.
* `modules/Integrations/` — behavior gated on multiple optional apps; never imported unconditionally.
* `lib/` — validation and derived-value helpers (`derive-vars.nix`, `identity-access.nix`, `*validation.nix`).
* `flake/` — system/package/check/app assembly. `checks.nix` wires the test gates.
* `custom_apps/` — first-party apps: `rust/apps/*` (media-manager, mail-archive-ui, kanidm-canary-bootstrap), `node/apps/*` (homepage, groundwater-logger, youtube-downloader), `mkvmaker`.
* `.agents/skills/` + `.agents/vendor/` — agent skills and vendored toolkits. `skills/frontend-design/` owns all frontend work; `skills/impeccable/` is the review/QA layer; `vendor/ux-ui-kit/` is the vendored UI/UX Kit knowledge base.
* `DESIGN_SYSTEM.md` — living record of frontend surfaces and deliberate design decisions; the precedent Impeccable detectors must respect.
* `.impeccable/config.json` — shared Impeccable config; narrowly scoped detector exceptions live here.
* `scripts/` — deploy, admin, helpers, and `tests/` (shell regression suite). `tests/test-common.sh` holds shared helpers; `validate-repo.sh` is the gate.
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

* One skill owns all frontend work: `.agents/skills/frontend-design/SKILL.md`. Its
  project-level anti-slop rules take priority over both vendored packages below.
* UI/UX Kit (`.agents/vendor/ux-ui-kit/`, vendored from `plugin87/ux-ui-agent-skills`,
  MIT) is the primary design/build discipline: design tokens, components,
  accessibility, frameworks (Qwik adapter included), taste/anti-slop doctrine.
* Impeccable (`.agents/skills/impeccable/`, vendored from `pbakaus/impeccable`,
  Apache-2.0) is the post-implementation critic/QA layer: `critique` and
  `audit`/detector run after the main implementation is rendered; `layout` and
  `distill` run conditionally; stylistic enhancement commands (bolder, delight,
  animate, overdrive, ...) only on explicit user request.
* Deliberate project design decisions live in `DESIGN_SYSTEM.md` and win over
  generic kit/detector preferences; narrowly scoped detector exceptions go in
  `.impeccable/config.json`.
* The default target is consistently competent frontend quality — verify at one
  desktop and one mobile viewport, fix objective defects, then stop. Do not
  enter open-ended visual refinement loops.
* Always check frontends for out-of-bounds and unscrollable areas. Long lists,
  forms and editors must not be clipped by an `overflow: hidden` ancestor, and
  every scroll region must actually scroll: confirm in the rendered page that
  the page itself fits its viewport (`scrollHeight` vs `clientHeight`), that
  each scroll container has a bounded height with reachable content
  (`scrollHeight` vs `clientHeight`, scrolled to the end), and that the last
  element sits inside its container. Do this at a desktop and a mobile
  viewport; a green layout in the source is not evidence.

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

### Lean (default: `validate-repo.sh`)
Quick validation targeting newly added modules or large structural changes to the config.
Runs in 2-3 min against enabled applications only. Includes: module structure, removal
evaluation, hardening, config validation, bootstrap safety, secret structure, and
app-specific module tests for enabled apps.

Use `--all-apps` to test the complete application catalog.

### Full (`validate-repo.sh --full`)
Complete validation including heavy Nix evaluation, deploy transaction tests,
first-boot convergence, secret generation flows, Kopia wrapper validation, and
Playwright e2e. Runs in 10-15 min. Run before merging significant changes or when
diagnosing persistent integration issues.

### VM (`validate-repo.sh --run-vm-tests`)
Integration tests requiring VM boot (failure-alert, jellyfin-oidc).
Requires `/dev/kvm`. Runs in 5-15 min. **Only run when diagnosing persistent bugs
where integration test coverage would be severely hampered without VM validation,
or with explicit user permission.**

## Service-Access Canary

The authenticated Homepage canary (`modules/Core_Modules/homepage/canary.nix`)
logs in as `canary-user` and verifies every enabled private application host
after deploy. It is the only check that catches broken routing, DNS, or Kanidm
access for a newly added service.

* Every new user-facing app or other private browser host must have a canary
  target in `canary.nix`.
* `scripts/tests/test-canary-target-coverage.sh` (lean tier) fails when an
  enabled Caddy host is neither covered nor listed in
  `repo.canary.coverageExemptHosts`. Add an exemption only for surfaces that are
  not independently browser-loginable (identity provider, gateway login,
  embedded editors, public shares, API-only or device-local UIs) and document
  the reason.
* After deploying a new app, run the canary and inspect the rendered result:
  `sudo systemctl start homepage-canary.service && sudo homepage-canary-assert`.
  A green deploy is not proof of access.

## Media App UI Changes

* Any change to media-manager text or UI layout must consider mobile phone screens as well as desktop screens. Verify the rendered library and metadata views at a phone width (about 390px) and a desktop width (about 1280px), including long titles and folder names, wrapped labels, image placeholders, upload controls, and subtitle management. Fix clipping, horizontal overflow, and inaccessible touch controls before considering the change complete.
