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

## Git Tracking

* Ensure all new git files (except for those in .gitignore) are tracked as soon as they are created to avoid visibility issues during nix rebuilds
* Avoid tracking huge files and directories that do not need to be tracked, such as build directories or caches
* Do not track plaintext secrets or other sensitive information

---

## Rebuild Command

* Prefer the guarded deploy helper for rebuild. 
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
