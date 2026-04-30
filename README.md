# NixHomeServer

Declarative NixOS home server optimized for reliability, security, and reproducibility. It keeps identity, routing, apps, storage, and validation in one reproducible NixOS configuration.

## What This Stack Runs
- Identity and OIDC: Kanidm
- Public auth gateway: OAuth2 Proxy
- Reverse proxy and TLS boundary: Caddy
- Public exposure: Cloudflare Tunnel
- Private remote access: NetBird
- Private DNS: Unbound
- Apps: Immich, Paperless-ngx, Audiobookshelf, Copyparty, Kiwix, Kavita, Jellyfin
- Mail archive and search: `mail-archive-ui`, `mbsync`, `notmuch`
- Storage: Btrfs system SSD, single mirrored ZFS data pool, manual cold-storage pools
- Validation: `nix flake check --no-build`, `scripts/check-repo.sh`, `scripts/check-repo.sh --full`, `scripts/check-docs.sh`, `scripts/runtime-readiness.sh`

## Conventions
- Placeholders such as `<domain>`, `TARGET_SERVER_IP`, `CURRENT_SERVER_IP`, `ADMIN_USER`, and `NEW_USER` are examples. Replace them with your operator values before running commands.
- Group names such as `users`, `user-files`, `shared-files-ro`, `shared-files-rw`, `immich-users`, `paperless-users`, and `*-admin` are literal names managed by this repo. Do not rename them in commands.

## Start Here

| Situation | Start with | Use when | Follow next |
| --- | --- | --- | --- |
| Blank-machine bootstrap | [Quickstart](./documentation/quickstart.md) | You are preparing a workstation, staging secrets, installing the agenix key, or installing onto a fresh machine. | Continue with [Operations](./documentation/operations.md) for guarded deploys and readiness checks. |
| Normal deploy, validation, or runtime check | [Operations](./documentation/operations.md) | The host already exists and you need the canonical validation gate, guarded deploy workflow, runtime readiness, DNS checks, or power/storage checks. | Use [Kanidm Guide](./documentation/kanidm.md) for identity work or [Restore And Recovery](./documentation/restore-and-recovery.md) for storage recovery. |
| Identity or access changes | [Kanidm Guide](./documentation/kanidm.md) | You need delegated operator login, user onboarding, access-group grants, password reset tokens, or app access troubleshooting after sign-in. | Fall back to [Operations](./documentation/operations.md) if the problem is DNS, routing, or service health. |
| Public or private endpoint troubleshooting | [Operations](./documentation/operations.md#shared-troubleshooting-matrix) | A public endpoint is down, a private hostname resolves incorrectly, or you need the first command set for DNS and service failures. | Use [Kanidm Guide](./documentation/kanidm.md#troubleshooting-flow) if auth succeeds but the app still denies access. |
| Rollback after a bad deploy | [Operations](./documentation/operations.md#rollback-after-a-bad-generation) | A deploy completed, but the current generation is bad and you need SSH, bootloader, or local-console rollback steps. | Re-run [Runtime Validation](./documentation/operations.md#runtime-validation) after rollback. |
| SSD, data-pool, or cold-storage recovery | [Restore And Recovery](./documentation/restore-and-recovery.md) | You need scenario recipes for SSD replacement, single-mirror data-pool recreation, cold-storage mounting, or SSD-backed state restoration. | Use [Quickstart](./documentation/quickstart.md) only when the rebuilt host still needs bootstrap inputs or agenix key installation. |

Validation gate: see [Operations](./documentation/operations.md#validation-gate) for the canonical `nix flake check --no-build`, `scripts/check-repo.sh`, and `scripts/check-repo.sh --full` workflow.

Deploy entry point: `./scripts/deploy-validated.sh --help`

Mail archive control plane: see [Mail Archive UI](./rust/apps/mail-archive-ui/README.md) for the private UI, sync flow, and storage model.
