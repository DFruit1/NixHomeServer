# NixHomeServer

Declarative NixOS home server optimized for reliability, security, and reproducibility. It keeps identity, routing, apps, storage, and validation in one reproducible NixOS configuration.

## What This Stack Runs
- Identity and OIDC: Kanidm
- Public auth gateway: OAuth2 Proxy
- Reverse proxy and TLS boundary: Caddy
- Public exposure: Cloudflare Tunnel
- Private remote access: NetBird
- Private DNS: Unbound
- Apps: Immich, Paperless-ngx, Audiobookshelf, Copyparty, FileBrowser Quantum, Kiwix, Kavita, Jellyfin
- Mail archive and search: `mail-archive-ui`, `mbsync`, `notmuch`
- Storage: Btrfs system SSD and a single mirrored ZFS data pool
- Validation: lean deploy checks via `scripts/validate-repo.sh`, full Nix/lint/app checks via `scripts/validate-repo-remote.sh --host ... --full` or `scripts/validate-repo.sh --full`, and runtime checks via `scripts/check-runtime-readiness.sh`
- Day-2 workflow: the desktop can stay Nix-free while the server performs evaluation, builds, and activation from staged repo archives
- Local operator shell: `nix develop .#ops`
- Readable local prebuild: `nom build .#nixosConfigurations.server.config.system.build.toplevel --no-link`

## Start Here

| Situation | Start with | Use when | Follow next |
| --- | --- | --- | --- |
| Blank-machine bootstrap | [Quickstart](./documentation/quickstart.md) | You are preparing a workstation, staging secrets, installing the agenix key, or installing onto a fresh machine. `disko` is in scope only here. | Continue with [Operations](./documentation/operations.md) for validation, guarded deploys, and runtime checks. |
| Normal deploy, validation, or runtime check | [Operations](./documentation/operations.md) | The host already exists and you need the canonical validation gate, guarded deploy workflow, runtime readiness, DNS checks, storage checks, or rollback steps. | Use [Kanidm Guide](./documentation/kanidm.md) for identity work, [Vaultwarden Guide](./documentation/vaultwarden.md) for the shared password-manager workflow, or [Restore And Recovery](./documentation/restore-and-recovery.md) for mirrored-pool repair or SSD-backed state restore. |
| Mirrored-pool repair or SSD-backed state restore | [Restore And Recovery](./documentation/restore-and-recovery.md) | You need the maintained recovery boundary for degraded mirror replacement or backup-backed app-state inspection and restore. | Use [Quickstart](./documentation/quickstart.md) only when the rebuilt host still needs bootstrap inputs or agenix key installation. |

Validation gate: see [Operations](./documentation/operations.md#validation-gate) for the canonical remote day-2 validation workflow and the optional local Nix validation commands.

Deploy entry point: `./scripts/deploy-with-validation.sh --help`

Fast custom-app iteration path: `./scripts/rebuild-remote-fast.sh`.
This is an explicit no-check remote rebuild helper; keep using the guarded
deploy path for normal changes.

## New Admin Template Workflow

The current/default deployment keeps operator-facing values in [`vars.nix`](./vars.nix)
so a new admin can still configure the main install in one place. The reusable
host layer lives under [`hosts/`](./hosts): `hosts/dsaw` points back to
`vars.nix`, while `hosts/example` is a template host with placeholder values.

Useful first-run helpers:

- `nix run .#doctor -- --host dsaw`
- `nix run .#explain -- --host dsaw`
- `nix run .#storage-plan -- --host dsaw`
- `nix run .#render-runbook -- --host dsaw`
- `nix run .#init-site -- --site my-home`

`modules/Core_Modules` is the fixed platform layer. Profiles and app enable
options are for optional app surfaces around that core, not for swapping out
identity, DNS, edge, storage, or validation foundations.

For a new one-host install, use [`vars.example.nix`](./vars.example.nix) as the
copyable starting point and keep day-to-day settings in [`vars.nix`](./vars.nix).

Immich sharing uses separate private-app and public-share hostnames. Render the
site runbook with `nix run .#render-runbook -- --host <host>` for concrete URLs,
and see [Operations](./documentation/operations.md#app-hostnames) for the access
model.

Mail archive control plane: see [Mail Archive UI](./rust/apps/mail-archive-ui/README.md) for the private UI, sync flow, and storage model.

Files split cleanly by role: the uploads hostname is the Copyparty bulk-uploader
surface and lands each signed-in user directly in their own uploads root, while
the files hostname is the authenticated FileBrowser Quantum UI and WebDAV
entrypoint. Kavita-managed book roots use `ebooks`, `comics`, and `manga`.

Vaultwarden stays private and is intended for LAN and NetBird use only. See
[Vaultwarden Guide](./documentation/vaultwarden.md) for the local-login invite
flow and break-glass local admin model.
