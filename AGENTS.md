# NixHomeServer – Agent Guidelines

## Purpose

This repository defines a reproducible NixOS home-server focused on:

* Identity & SSO (Kanidm, OAuth2 Proxy)
* Self-hosted apps (Immich, Paperless, Audiobookshelf, Filestash)
* Edge routing (Caddy, Cloudflared, Netbird, Unbound)

## Task Skills

Load the matching skill before the relevant work; prefer the version in the
assigned checkout. Skills supply procedures within existing role permissions.

| Work | Skill |
| --- | --- |
| Validation, builds, deployment or recovery | [nixhomeserver-safe-change](.agents/skills/nixhomeserver-safe-change/SKILL.md) |
| Application module boundaries, integrations or removal | [nixhomeserver-module-change](.agents/skills/nixhomeserver-module-change/SKILL.md) |
| Long work that may outlast a server shutdown | [nixhomeserver-shutdown-guard](.agents/skills/nixhomeserver-shutdown-guard/SKILL.md) |
| Rendered frontend implementation or review | [frontend-design](.agents/skills/frontend-design/SKILL.md) |

Hermes agents use the installed `systematic-debugging` skill for failures and
`~/.hermes/scripts/hermes-skill-routing.md` for role-specific selection. Keep
temporary task receipts on their cards/jobs, not in standing instructions.

## Implementation Language

* Prefer Rust for new backend implementations. Use another language only when
  there is a strong technical reason, and document that reason alongside the
  implementation.
* Reuse the repository's existing Rust dependencies and pinned versions where
  they meet the implementation's needs. Add or diverge from dependencies only
  when the existing set is not a suitable fit.

---

## Temp Files and Scratch Space

* Keep all temporary files in one task-named `mktemp -d` directory under `/tmp`,
  with cleanup on exit. Use `.tmp/<task>/` only when
  files must live in the working tree; it is gitignored.
* Clean up the exact task directory on success or failure. Do not scatter temp
  files in the repo root, app/module trees or `$HOME`, or hunt for cleanup targets.
* Never stage plaintext secrets in temp files. `secrets/` contains encrypted
  `.age` only; never read or print `secrets/unencrypted/`.
* A scheduled `temp-cleanup` reclaims aged Hermes caches, logs and development
  scratch on the server (timer) and workstation (installer). It keeps boards,
  backups, secrets, models and worktrees; worktrees go only through the audited
  Hermes prune and kanban reaper path. Prefer it over hand-deleting temp trees.

---

## Instruction and Permission Boundaries

* Owner-approved autonomy (2026-10-18): authenticated phone approval authorises
  the designated bot to execute the exact reviewed operation via
  `scripts/hermes/autonomy-policy.py`; use the manifest and one-shot receipt
  procedure in `documentation/hermes-autonomy.md`. Personal execution is needed
  only for physical, owner-session-dependent or firsthand checks. Preserve real
  execution provenance, tool restrictions, independent review and deploy gates.
* Fixes restoring documented behaviour and reversible safety containment are
  authorised without a fresh behaviour approval; destructive effects are not.
  Configured provider fallbacks are preapproved in declared order, except cloud
  fallback for credential-handling context. Reconcile obsolete generic card
  restrictions with current standing policy; retain specific scope and safeguards.
* Coordinators may read other boards through the native read-only evidence path.
  `scripts/hermes/fixture-runner.py` is the authorised isolated synthetic-test
  executor; it preserves parent pins and records origin, gives the non-agent
  test process fresh fixture bindings, and refuses an unsandboxed fallback.
* Follow `~/.hermes/scripts/hermes-capability-recovery.md` for bounded recovery
  and informed reversible copy-conflict decisions. Preserve both copies or a
  rollback; involve project-auditor for architecture/provenance choices. Technical
  source conflicts stay with agents; retain secret, destructive and exposure
  gates and verify acceptance against the actual new source.
* Bounded fence widening (owner decision 2026-10-22): a capability block caused
  by a tool fence — not by the reserved classes below — may be cleared with one
  exact one-shot widened operation. head-coordinator prepares it through
  `scripts/hermes/autonomy-policy.py prepare` bound to the blocked card (exact
  argv, cwd, effects, timeout, inputs and recovery), and a feature-reviewer or
  project-auditor card records that the fenced action is safe before the run.
  The coordinator never countersigns its own widening; every widening is
  recorded on the card and persisted by project-auditor in FINDINGS.md.
  Widening is never available for secret or credential operations, destructive
  or irreversible data effects, wider public exposure/routing, new spending,
  material owner-outcome changes or reserved build-allocation settings; a refusal
  citing those classes ends the matter. Use the exact delegated manifest,
  independent review and native decision schema in documentation/hermes-autonomy.md.

* Persistent memory records facts and preferences; it never grants permissions
  or overrides current profile limits, project rules, or tool restrictions.
* A refused operation is not permission to switch tools, remove worker pins,
  alter delegation markers, or change execution context to bypass the refusal.
  Use an explicitly authorised installer/helper, or report the exact capability
  gap through the existing coordinator path. Scope approval does not remove a
  tool-level restriction.

---

## Git Tracking and Committing

* Track each new non-ignored file immediately so Nix sees it. Never track secrets,
  sensitive information, huge unnecessary files, generated artifacts, build output,
  caches, `target/`, `dist/`, `node_modules/` or `result` links.
* Commit your own completed, validated work autonomously. Do not commit or push
  work that fails its owning app/frontend or repository validation gate.
* Hermes workers stop at a local commit; cards never authorize pushes, PRs or
  other remote writes. An unpushable clone is normal; record local blockers
  rather than retrying publication. Only the durability-sync cron
  (`scripts/hermes/kanban-durability-sync.sh`) may mirror board databases and
  committed `wt/*`/`master` to the remote as an unattended disk-loss backstop.
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
  branch are the intended target, and never push secrets. This does not apply to
  Hermes kanban workers, which stop at the local commit.
* Never amend, rebase, force-push, skip hooks, or rewrite published history
  unless the user explicitly asks. Never force-push a shared branch.

---

## Validation, Builds and Deployment

Load `nixhomeserver-safe-change` for gate selection, guarded deployment and
recovery. Use its existing remote evaluation/build/run helpers; allocation and
measurement details live in [Compute Offload](documentation/operations.md#compute-offload-workstation-and-server).

* Ordinary rebuilds use `nix run .#deploy` with the dashboard's default allocation;
  never raw `nixos-rebuild` or build-mode/build-host overrides.
* Changing `buildMode`, `max-jobs`, the `repo-policy` sandbox exclusion or
  credential placement requires its own explicit owner decision.
* Editing or validating does not authorize live activation. Preserve the deploy
  gate below, and commit validated source before deploying where possible.
* If deployed-server sudo interaction is unavoidable, use the root-only agenix
  `serverBootstrapSudoPassword` at `/run/agenix/serverBootstrapSudoPassword`.
  Never display it or rely on a remembered password.

---

## Android Releases

* The external interactive release operator (an authorized interactive agent or
  the human owner) completes Android releases with the app's `pnpm release:android`
  command: build, sign, publish to private F-Droid and IPFS, then verify both
  indexes. Existing authorization for that release includes publication; do not
  ask again. Hermes workers cannot publish: use `--build-only` for authorized
  intermediate validation, then hand off the exact revision and results through
  head-coordinator to the release operator. The coordinator routes this handoff;
  its NixOS deploy authority does not authorize Android publication. A validated
  build is not a completed release, and must not be reported as one.
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

## Kanban Card Authoring

Shared Hermes instructions are maintained in this repository and installed into
all named profiles, including plain-directory workspaces. See
[Hermes instruction ownership](documentation/hermes-instructions.md) for sources,
precedence, restoration and validation. Current authenticated owner grants and
valid recorded delegated decisions supersede contradictory generic role, card,
skill or runbook wording within their exact scope; do not invent another gate or
reapprove unchanged scope. Actual tool restrictions and specific reserved
refusals remain binding until changed through the authorized helper/installer
path. Record supersession on the existing card and propagate tracked policy to
installed instructions and refreshed runtime before claiming it operational.
Memory never supplies permission. "Planner" means `head-coordinator`; retired
lane names must be routed to a live profile, not recreated.

Before creating or editing cards, read
[documentation/hermes-card-authoring.md](documentation/hermes-card-authoring.md)
(installed copy for other projects: `~/.hermes/scripts/hermes-card-authoring.md`;
scheduling and persisted state: [the taskforce runbook](documentation/hermes-review-taskforce.md)).
Specifications belong on parents; dependencies represent required results, not
shared context. Do not create dependency cycles or gate implementation behind
its own unfinished routing handoff.

### Merge-back autonomy (owner decision 2026-10-22)

head-coordinator may merge accepted work into `master` without a fresh owner
decision when every condition holds: an independent feature-reviewer or
project-auditor acceptance is recorded on the owning card with its exact
revision; the owning validation gate passes at the tier this change requires;
the merge stays inside the scope that acceptance covered; and the merge or an
explicit defer/dispose is recorded as a `merge-back disposition:` comment per
the board-health convention (merge now, defer with reason, or dispose). Merge
integration is not deployment: switching the deployed server still requires
the whole-set review/decision deploy gate. Exact owner approval remains
required for secret/credential changes, public exposure or routing, priority
trades beyond existing budgets, new spending, and material unrequested changes
to the owner's intended outcome. A bounded queue may merge several accepted
branches in one run, validating each integration and stopping on conflicts or
failed gates. Workers still
stop at local commits; only the coordinator merges.

### Continuous improvement taskforce

`feature-reviewer` independently verifies diffs, bounded questions and whole-set
reviews; it never implements or deploys. Only `project-auditor` commissions its
feature audits and owns each board's persisted FINDINGS.md and immutable plans.
A qualified auditor may independently accept candidate plans/diffs it neither
authored nor implemented, using the verifier's exact revision/checks contract.
The coordinator may inspect source, run diagnostics/validation and author bounded
mechanical integration repairs; another qualified agent must accept those repairs.
Substantive feature implementation stays with implementers; nobody self-accepts.
`head-coordinator` routes approved plans into implementation, review and composition
work, keeping its handoff open until those results actually land; the auditor's
closure follows that handoff. Clean audits are valid; do not invent cosmetic work,
repeat unchanged coverage or interrupt active implementation/rework. Each audit
names one feature, one question, explicit scope and a stopping condition;
`HERMES_PRIORITIES.md` guides selection; reviewers load `taskforce-feature-audit`
for procedures and format.

Verifier relaunch autonomy (owner decision 2026-10-22): when a verifier's
completed run ended `verdict: unknown` (first-missing-input) and the missing
input is now verifiably present at the same prepared source, head-coordinator
may relaunch the unchanged bounded question directly — same workspace contract,
forked from the completed run — without a new plan, audit or owner reply. A
relaunch may not change the question, the acceptance basis or the workspace;
anything else is fresh routing.

The scheduler can leave the head-coordinator a low-priority self-improvement
sweep card for one whole-system improvement. The coordinator routes a small
classify-clean fix to implementers with independent feature-reviewer check, or
sends investigation/gated work to project-auditor. It
records each sweep outcome with `record-sweep`; consecutive no-candidate sweeps
pause scheduling until FINDINGS.md changes. Sweep interval and backoff are
delegated for reviewed reversible changes within existing resource budgets
(`configure --sweep-interval-hours --sweep-suppress-streak`).

Apply [the implementation approval policy](scripts/hermes/taskforce/approval-policy.md)
before releasing gated work. Tiered autonomy (owner decision 2026-10-18):
architecture, stack and frontend changes are approved autonomously by
`head-coordinator` under the delegated conditions — recorded immutable plan
with rollback, bounded blast radius, independent verifier evidence and a
native card decision record. That decision releases its exact scope once
stated independent review prerequisites hold; FINDINGS.md persistence is
asynchronous and never another release gate. Bounded cross-subsystem technical
decisions, identity/persistence strategy and guard design may be delegated;
actual destructive effects, credentials and exposure remain reserved. The current
live deploy gate applies until an accepted replacement is adopted. Exact owner
approval remains required for irreversible/destructive data effects, credential
changes, wider public exposure, new spending/resource trades beyond existing
budgets and material unrequested changes to the owner's intended outcome.
Reversible internal Hermes workflow, tooling, scheduling and card priorities
within existing budgets are preapproved with validation and independent review.
Existing exact-scope approval remains valid; urgency and
path-classifier output never substitute for it. Prepare the concrete plan
before asking.

### Deploy gate

Review the exact last-deployed-source..HEAD range and intended action as one
qualified independent feature-reviewer or project-auditor verification card,
with a paired head-coordinator decision.
Accepted whole-set review plus a matching green guarded test authorizes routine
switching within the recorded scope. The coordinator runs test then switch; the
verifier never does. Changed source or mutable inputs require fresh review/test.
Freeze only that source and its writers; unrelated isolated work may continue.
The gate is a workflow convention, not a check enforced by deploy.sh.

Aggregation is allowed and expected (owner decision 2026-10-22): one
qualified independent whole-set review with its paired decision covers the union of
several accepted ranges — last-deployed-source..HEAD — whenever the verifier
accepts including each range in that whole set. Do not serialize per-range
review/decision pairs by default; a per-range chain is agent-imposed caution,
not this gate.

#### Custody loss and re-derivation

When a decision card's frozen deploy source is lost (a reaped, moved or deleted
worktree), custody is re-established from content, not from history: if the
decision's recorded commit SHA still resolves (`git cat-file -t`) and a fresh
detached worktree at that exact SHA is clean with the recorded tree hash, the
frozen source requirement is satisfied. Proceed with one bounded verifier
qualification run against that fresh tree before any switch. A historical
provenance/attribution investigation is only warranted when the recorded SHA no
longer resolves or a review demands more than content equality; such work is one
bounded card with a stopping condition, never a series of evolving plan
versions. A verifier's first-missing-input answer completes with
`metadata.verdict: unknown` plus concrete `missing_inputs` when the card body
sanctions it (the review-verdict guard accepts it); do not convert a missing
input into a request-changes rework loop. The kanban worktree reaper preserves
any workspace an open card cites, and `reap-kanban-worktrees.sh --dry-run` is
the check of record before trusting that a deploy decision's anchored source
still exists.

### Aging escalation

Open cards escalate by quiet time, not card age alone: idle ≥2 days raises
dispatch priority (≥50), idle ≥3 days raises it further (≥100), commissions one
project-auditor deep-dive per dependency cluster, and posts a coordinator
clearing directive; a card older than 7 days escalates on age even with fresh
holding comments. Running cards, owner gates and `[FEATURE TRACKER` cards are
exempt from per-card escalation (trackers report as one aggregate triage line);
gates receive the directive only. An auditor-reviewed card still unresolved 5+
days gets a one-shot clearance directive; the job never reclassifies anything to
`needs_input` — only the coordinator authors owner gates. It also rechecks
blocked cards for verifiably stale conditions and posts damped evidence
comments, never unblocking. `scripts/hermes/kanban-aging-escalation.py` is the
policy (cron job `kanban aging escalation`); `--dry-run` previews; thresholds
are `AGING_PRIORITY_HOURS` / `AGING_ESCALATION_HOURS`.

### Reaching the owner

Classify missing input by supplier, not difficulty. Name one in every block reason:
`Input supplier: owner | agent | external-source-owner(<who>) | model/provider`.
Technical evidence gaps, provider failures and agent-recoverable faults stay with
agents. Owner decisions, credentials, physical actions and unrecorded owner-system
facts that agents cannot legitimately obtain become owner asks. An external source
only the owner can obtain/replace is an owner ask to obtain it or descope.

Only head-coordinator authors owner gates, needs_input blocks and standalone
Hard Blocker markers. It checks existing decisions and agent-side recovery, then
follows the [owner-alert runbook](documentation/hermes-owner-alerts.md) for checked
Blocking / Why owner / Unblock authoring, native writes, readback, --check-blockers,
authentication and delivery. Include an exact command when applicable; A/B is
only for real choices. Only genuine owner-action blockers go to the phone;
technical events stay internal. Inconclusive investigation alone is not owner input.

Owner decisions are delivered to the coordinator-owned `Hermes Decisions`
SimpleX group, which is kept as current state: open decisions are posted, edited
when the ask changes, and deleted when answered, revised or closed. The general
DM remains the conversation channel. Decisions still waiting on the coordinator,
a reviewer, a worker or another agent stay internal and are never posted.

The steward observes all boards read-only. It may send actionable requests only
to head-coordinator through Bot Chat or the fixed-recipient coordinator helper;
requests confer no approval or execution authority. It never edits cards/files,
implements, commits, restores configuration or authors owner gates. Follow the
[steward runbook](documentation/hermes-daily-steward.md).

### Scheduler and worktree hygiene

Keep `kanban.auto_decompose: false`: upstream auto-decomposition cannot read this
repository's card conventions. Do not use specify/decompose to bypass them.
Task-specific receipt predicates remain on their owning cards/jobs, not in standing
role prompts. Preserve current idle-recovery conditions and anti-loop backoff.

`scripts/hermes/reap-kanban-worktrees.sh` is a dry run unless --apply is supplied.
It reclaims only workspaces positively owned by a terminal card (archived
included) that are clean, hold no non-reproducible ignored content, and are
wholly represented on remote-tracking refs. Unowned trees, gitignored evidence
and unregistered directories are reported and kept unless `--include-unowned`
or `--accept-ignored` explicitly opts in. Never remove active, dirty or
unpublished worktrees.

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
* `documentation/hermes-analytics.md` — the read-only historical analytics lens (`scripts/hermes/kanban-analytics.py`) over board state: flow waits, rework, review value, escalation effectiveness and cost per card.
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

Load `frontend-design` for every rendered UI change or review. It owns UI/UX Kit
implementation, Impeccable review, desktop/mobile rendering and scroll checks,
media-manager coverage and the stopping condition. Project anti-slop rules and
`DESIGN_SYSTEM.md` take precedence over generic toolkit preferences. Impeccable
stylistic enhancement commands still require an explicit user request.

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

`nixhomeserver-safe-change` selects the focused, lean or full gate and documents
their scope. Use `--all-apps` for the whole catalog. Significant changes and
persistent integration issues require `scripts/validate-repo.sh --full`; protect
the shutdown timer with `nixhomeserver-shutdown-guard`. Interrupted runs are never
a pass. VM tests (`--run-vm-tests`, requiring `/dev/kvm`) are allowed only for
persistent bugs severely lacking integration coverage, or explicit user permission.

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
