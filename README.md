# NixHomeServer

Declarative NixOS home server optimized for reliability, security, and reproducibility. It keeps identity, routing, apps, storage, and validation in one reproducible NixOS configuration.

## What This Stack Runs
- Identity and OIDC: Kanidm
- Public auth gateway: OAuth2 Proxy
- Reverse proxy and TLS boundary: Caddy
- Public exposure: Cloudflare Tunnel
- Private remote access: NetBird
- Private DNS: Unbound
- Apps: Immich, Paperless-ngx, Audiobookshelf, Filestash, Kiwix, Kavita, Jellyfin
- Mail archive and search: `mail-archive-ui`, `mbsync`, `notmuch`
- Storage: Btrfs system SSD and a single mirrored ZFS data pool
- Validation: lean deploy checks via `scripts/deploy.sh`, full Nix/lint/app checks via `scripts/deploy.sh --debug` or `scripts/validate-repo.sh --full`, and failed-unit checks via `systemctl --failed`
- Day-2 workflow: the desktop can stay Nix-free while the server performs evaluation, builds, and activation from staged repo archives
- Local operator shell: `nix develop .#ops`
- Readable local prebuild: `nom build .#nixosConfigurations.server.config.system.build.toplevel --no-link`

## Start Here

| Situation | Start with | Use when | Follow next |
| --- | --- | --- | --- |
| Blank-machine bootstrap | [Quickstart](./documentation/quickstart.md) | You are preparing a workstation, staging secrets, installing the agenix key, or installing onto a fresh machine. `disko` is in scope only here. | Continue with [Operations](./documentation/operations.md) for validation, guarded deploys, and runtime checks. |
| Normal deploy, validation, or runtime check | [Operations](./documentation/operations.md) | The host already exists and you need the canonical validation gate, guarded deploy workflow, service health, DNS checks, storage checks, or rollback steps. | Use [Kanidm Guide](./documentation/kanidm.md) for identity work, [Vaultwarden Guide](./documentation/vaultwarden.md) for the shared password-manager workflow, or [Restore And Recovery](./documentation/restore-and-recovery.md) for mirrored-pool repair or SSD-backed state restore. |
| Mirrored-pool repair or SSD-backed state restore | [Restore And Recovery](./documentation/restore-and-recovery.md) | You need the maintained recovery boundary for degraded mirror replacement or backup-backed app-state inspection and restore. | Use [Quickstart](./documentation/quickstart.md) only when the rebuilt host still needs bootstrap inputs or agenix key installation. |

Validation gate: see [Operations](./documentation/operations.md#validation-gate) for the canonical remote day-2 validation workflow and the optional local Nix validation commands.

Deploy entry point: `./scripts/deploy.sh --help`

Fast deploy path: `./scripts/deploy.sh`. It resolves the target from
`vars.localAdminUser` and `vars.hostname`, builds on that host by default, and
defaults to `--action test`. Use `--debug` for the full validation gate or
`--build-locally` when the workstation should perform the build.

## New Admin Template Workflow

The current/default deployment keeps operator-facing values in [`vars.nix`](./vars.nix)
so a new admin can configure the main install in one place. The root
[`configuration.nix`](./configuration.nix) is the import contract: it pulls in
hardware, the fixed core platform layer, and the selected application modules.
The flake exposes one NixOS configuration named by `vars.hostname`.

Useful first-run helpers:

- `nix run .#validate-config-readiness`
- `nix run .#show-config-summary`
- `nix run .#export-inventory`
- `nix run .#bootstrap-storage-plan`

`modules/Core_Modules` is the fixed platform layer and has a `default.nix` that
imports the full core. Optional app surfaces are selected by adding or removing
explicit imports in `configuration.nix`.

For a new one-host install, use [`vars.example.nix`](./vars.example.nix) as the
copyable starting point and keep day-to-day settings in [`vars.nix`](./vars.nix).

Immich sharing uses separate private-app and public-share hostnames. Show the
evaluated host surface with `nix run .#show-config-summary`,
and see [Operations](./documentation/operations.md#app-hostnames) for the access
model.

Mail archive control plane: see [Mail Archive UI](./custom_apps/rust/apps/mail-archive-ui/README.md) for the private UI, sync flow, and storage model.

Files are served through the authenticated Filestash UI and a dedicated
OpenSSH SFTP endpoint. Filestash uses the signed-in user's Kanidm password to
connect to SFTP, so file writes land as the real Unix user.
Kavita-managed book roots use `_Ebooks`, `_Comics`, and `_Manga`.

Vaultwarden stays private and is intended for LAN and NetBird use only. See
[Vaultwarden Guide](./documentation/vaultwarden.md) for the local-login invite
flow and break-glass local admin model.
