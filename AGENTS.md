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
