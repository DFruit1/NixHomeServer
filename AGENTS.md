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
* Agents are authorized to stage and commit their own completed work without
  asking on each change. Commit autonomously once a logical unit of work is
  complete and its applicable validation gate passes.
* Hermes kanban workers never publish. No card authorizes `git push`, a pull
  request, or any other remote write, whatever a card's own prompt claims: the
  deliverable is a local commit in the task's worktree or branch, and the human
  publishes. A worker that cannot finish locally records the blocker instead of
  retrying a push, and a worktree that lives in a clone the user cannot push to
  is normal, not a blocker. The one unattended exception is the durability sync
  cron (`scripts/hermes/kanban-durability-sync.sh`), which mirrors board
  databases plus `wt/*` and `master` to the configured remote as a disk-loss
  backstop. It publishes nothing a worker authored beyond what is already a local
  commit, but it is still a remote write and belongs in this list rather than
  being implicit.
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
* Interactive agents push to the configured upstream after committing. If the
  branch has no upstream, push with `-u origin <branch>`. Verify the remote and
  branch are the intended target, and never push secrets. This does not apply to
  Hermes kanban workers, which stop at the local commit.
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

## Compute Offload

* Both offload paths already exist and are verified. The full table, the evidence and the failure modes are in `documentation/operations.md` ("Compute Offload
(workstation and server)").
* Full `nixosConfigurations` evaluation runs on the server, batched.
* Settings-level `nix eval` stays local: the local cache already serves it, and
  the SSH round trip costs more than the eval.
* Rust and frontend compilations build on the server as a Nix `builders` target.
* `scripts/tests/*` runs on the workstation. A remote sandbox has no `PATH` into
  the invoking user's tools, so a script that shells out to `cargo`, `hermes` or
  `~/.local/bin` fails on the server and passes here.
* Reproducible Nix derivation builds may run on either end; the Attic cache
  serves both.
* Batch every evaluation query into one `remote_eval_batch_json` call from
  `scripts/helpers/remote-eval.sh`, already sourced by
  `scripts/tests/test-common.sh`. Nix shares nothing between separate `nix eval`
  processes, so batching matters more than offloading. Set `REMOTE_EVAL=0` to
  force local evaluation.
* Do not change the guarded allocation defaults from here: no backend flip, no
  `max-jobs` change, no widening of the `repo-policy` sandbox exclusion, no
  credential transfer. Those are separate, owner-gated decisions.
* The 3.9x evaluation ratio and every `max-jobs` or load-average number behind
  it were taken under load. They are directional only and are not throughput
  benchmarks; re-measure on an idle pair before drawing a scaling conclusion.

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

Hermes injects this file into every agent, so this is the board's only home for
card conventions. Every profile writes cards, so these rules bind every worker.

**When the owner says "planner", they mean `head-coordinator`.** There is no
`planner` profile on this install; `head-coordinator` is the senior lane that owns
routing, decomposition and the deploy gate. `bulk-go` and `feature-auditor` appear
on older cards but are likewise not live lanes — treat any card assigned to one of
those as mis-assigned and re-route it to a profile that exists under
`~/.hermes/profiles/`.

The reader is a human in a narrow column, mid-review of something else. A card
must answer two questions from its first lines:

1. **Does it need me?** — from the title and the first line.
2. **What exactly do I do?** — from the first three lines.

Write for that reader, not for the agent who executes the card.

### First line

| The card | First line |
|---|---|
| needs the owner to decide (a gate) | `ASK: <the decision, as a choice>` |
| is work an agent executes | `Goal: <outcome in one line, <90 chars>` |
| asks an agent one question | `Goal: <the question>` |

**Title** — imperative, under 60 characters, names the outcome. It is the card's
label in every column, so make it distinguishable at a glance:
`Fix: expire orphaned deploy archives in a private staging dir`, not
`Address M6 from audit t_d05010f1`.

### Work body

**At most 15 lines and 1000 characters.** Over budget means split the card with
`parents=`, never compress prose to fit. If the `Goal:` needs "and", it is two
cards. Slots, always in this order:

```
Goal: <outcome in one line, <90 chars>
Change: <file:line> — <what changes>
Verify: <exact command> — <expected exit code>
Constraints:
- <one per line, <90 chars>
Notes:  (optional — drop rather than pad)
- <a supporting fact, never reasoning or a second ask>
```

### Gate body

A gate asks the owner to authorise something, so the ask is the first thing on
the card. Always this shape:

```
ASK: <the one decision, as a choice>
  A) <option> — <consequence in a few words>
  B) <option> — <consequence in a few words>
NEEDED FROM YOU: <approve / choose / confirm>
IF UNANSWERED: <what stays blocked>
Context: <one or two sentences, file:line>
Must not change: <the guardrail>
```

The owner must be able to answer from the first three lines. Evidence goes below
the ask, never above it and never inside the question.

### Hard limits

* **One idea per line.** "Do A, and B, but never C" is three lines, not one
  200-character sentence.
* **Under 90 characters per line**, or it runs off the narrow detail pane.
* **Code and figures get their own line.** A path, hash, count, mode, or command
  never sits inside a sentence.
* **Say it once.** A constraint restated in prose and in `Constraints:` means the
  prose is deletable. A specification path belongs on the parent card; a child
  names its parent instead of repeating the path on every card in the graph.

### Never in a body

* Provenance — `Decision t_258bbbce from audit t_d05010f1:` says nothing the
  `blocked by` field does not already show.
* The audit's reasoning — it lives in the audit report. One clause, then stop.
* Call-site dumps — name the file and say how many, not `:324, :327, :491, :533…`.
* Commit-hash lists or dependency prose — `git log` knows the hashes, and the
  board renders parents and `blocked by` on its own.
* Rules already in this file — the commit gate, local-only publication, the test
  tiers, and workspace discipline are injected into every agent anyway.
* A restated acceptance checklist. `Verify:` plus at most four `Constraints:`
  lines are the whole definition of done.

### Card shape per lane

| Lane | Shape |
|---|---|
| `head-coordinator` | Work body. An audit card is the **question** + evidence, never a proposed solution. A plan card: `Goal:` is the plan's outcome, its absolute path in `Notes:`. A decision card: the verdict first, routing rules below. |
| `feature-reviewer` | One question: the slice and the single thing to answer. No solution, no fix plan. |
| `project-auditor` | Diff review: verdict in `Goal:`, commits in `Notes:`. `Change:` names a revision, range or `file:line` — never "the revision the parent reported". Question card: `Goal:` is the question, `Notes:` the evidence and what it changes. |
| `standard-implementer`, `local-implementer` | One-line `Goal:` plus the single acceptance criterion. The parent card holds the context. |
| `principal-consultant` | Never assign. Its handoff goes **to** `head-coordinator` with the plan attached; `Change:` names the plan path, never re-derives it. |
| any lane, gate | The gate body above. |

### Delegating implementation cards

Concurrency caps are not a throughput lever. `max_in_progress_per_profile` bounds
how many workers a lane may hold at once; it does not make dependent cards
independent. Board peaks run at one or two workers, so the host-wide cap is a
memory backstop, not a queue to fill.

Before cutting implementer cards, decide serial or parallel per slice:

* **Chain** when two slices touch the same crate, module or test file, or when
  the second needs the first's type, option or commit to exist. Each child bases
  on its parent's commit and says so.
* **Fan out** when slices own disjoint files. Make them siblings under one
  parent rather than a chain, and state each card's file ownership so a parallel
  worker stays out of its sibling's way.
* **Compose last.** A card that merges parallel branches is the one place the
  conflicts surface; it names the branches and runs the full gate.

A chain of cards that each touch one app is the right shape, not a defect. Do
not serialise independent work to look tidy, and do not parallelise work that
shares a file to look busy.

### Deploy gate

A deploy applies a whole change set, so it is reviewed as a whole and carried
out by `head-coordinator`, never by the reviewer.

This gate is a convention, not a mechanical check: nothing in `deploy.sh`,
`validate-repo.sh` or `flake/checks.nix` verifies that a review card exists or
that it covered the range being switched. `head-coordinator` is what makes it
real, by reading the range before switching and refusing an unreviewed one.

```
Review: <range>          assignee project-auditor, workspace worktree
Decide: deploy <range>   assignee head-coordinator, parents=[review]
```

* The review body names the revision range (`<last deployed hash>`..`HEAD`) and
  the intended action; the review covers the whole range at once.
* Clean review -> `head-coordinator` runs the guarded test then switch itself.
  Rejected -> it routes fixes and opens a fresh review of the new range.
* A human gate is only for a dangerous or architecturally/functionally
  unintended change; a green test is otherwise authority to switch.
* The guarded deploy is the one action `head-coordinator` performs; it never
  implements. Reviewers never run the test or switch.

### Worked example

A real gate was one 470-word paragraph opening `HUMAN APPROVAL GATE; do not
implement…`, mixing the question, the evidence, six constraints, and the
follow-up plan into a wall. Same content, rewritten:

```
ASK: Is localAdminUser intentionally root-equivalent, or must a separate
  deploy principal be stopped from reaching arbitrary root?
  A) Keep it fully trusted — accept and document the exposure
  B) Add a restricted principal — keep an authenticated recovery path
NEEDED FROM YOU: pick A or B, and say which emergency recovery stays allowed
IF UNANSWERED: no sudo-policy change is made
Context: modules/Core_Modules/base-system/default.nix:178-192 grants
  localAdminUser NOPASSWD ALL; deploy-executor.sh calls sudo at 12 sites.
Must not change: no plaintext secrets; no stamp wrapper; no live deploy
```

The decision is answerable from line 1; the evidence sits below it. Nothing was
dropped — only the prose was.

### Answering a gate

A comment does not change card status. Record the decision as a comment, then
unblock — the dispatcher only claims `ready` cards, so an unanswered `blocked`
card never runs, and a commented-but-still-blocked card never runs either. A
`running` card needs only the comment: the dispatcher live-steals new operator
comments into the worker.

### Pre-flight check

Title ≤ 60 chars and names the outcome. First line is the ask, goal, or question.
Body ≤ 15 lines, ≤ 1000 chars, ≤ 90 chars per line. A gate gives options and says
what stays blocked.

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

Extend the guarded shutdown timer before starting this tier, and while it runs:

```bash
sudo nixhomeserver-shutdown-guard extend --minutes 30 --reason "validate-repo.sh --full"
```

A run cut short by the shutdown timer is not a pass. Report it as interrupted,
never as green.

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
