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
- Validation: `scripts/validate-repo-remote.sh --host ... --full`, `scripts/validate-repo.sh`, `scripts/validate-repo.sh --run-flake-check`, `scripts/validate-repo.sh --full`, `scripts/check-runtime-readiness.sh`
- Day-2 workflow: the desktop can stay Nix-free while the server performs evaluation, builds, and activation from staged repo archives
- Local operator shell: `nix develop .#ops`
- Readable local prebuild: `nom build .#nixosConfigurations.server.config.system.build.toplevel --no-link`

## Start Here

| Situation | Start with | Use when | Follow next |
| --- | --- | --- | --- |
| Blank-machine bootstrap | [Quickstart](./documentation/quickstart.md) | You are preparing a workstation, staging secrets, installing the agenix key, or installing onto a fresh machine. `disko` is in scope only here. | Continue with [Operations](./documentation/operations.md) for validation, guarded deploys, and runtime checks. |
| Normal deploy, validation, or runtime check | [Operations](./documentation/operations.md) | The host already exists and you need the canonical validation gate, guarded deploy workflow, runtime readiness, DNS checks, storage checks, or rollback steps. | Use [Kanidm Guide](./documentation/kanidm.md) for identity work or [Restore And Recovery](./documentation/restore-and-recovery.md) for mirrored-pool repair or SSD-backed state restore. |
| Mirrored-pool repair or SSD-backed state restore | [Restore And Recovery](./documentation/restore-and-recovery.md) | You need the maintained recovery boundary for degraded mirror replacement or backup-backed app-state inspection and restore. | Use [Quickstart](./documentation/quickstart.md) only when the rebuilt host still needs bootstrap inputs or agenix key installation. |

Validation gate: see [Operations](./documentation/operations.md#validation-gate) for the canonical remote day-2 validation workflow and the optional local Nix validation commands.

Deploy entry point: `./scripts/deploy-with-validation.sh --help`

Immich sharing: the private app stays on `photos.sydneybasiniot.org`, while
public share links use `sharephotos.sydneybasiniot.org`. See
[Operations](./documentation/operations.md#app-hostnames).

Mail archive control plane: see [Mail Archive UI](./rust/apps/mail-archive-ui/README.md) for the private UI, sync flow, and storage model.

Files now split cleanly by role: `https://uploads.sydneybasiniot.org/upload/<username>/` is the Copyparty bulk-uploader surface, while `https://files.sydneybasiniot.org/` is the authenticated FileBrowser Quantum UI and WebDAV entrypoint. Kavita-managed book roots now only include `ebooks`, `comics`, and `manga`.
