# NixHomeServer

Declarative NixOS home server optimized for reliability, security, and reproducibility. It keeps identity, routing, apps, storage, and validation in one reproducible NixOS configuration.

## What this stack runs
- Identity and OIDC: Kanidm
- Public auth gateway: OAuth2 Proxy
- Reverse proxy and TLS boundary: Caddy
- Public exposure: Cloudflare Tunnel
- Private remote access: NetBird
- Private DNS: Unbound
- Apps: Immich, Paperless-ngx, Audiobookshelf, Copyparty, Kavita, Jellyfin
- Mail archive and search: `mail-archive-ui`, `mbsync`, `notmuch`
- Storage: Btrfs system SSD, mirrored ZFS data pool, manual cold-storage pools
- Validation: `nix flake check --no-build`, `scripts/check-repo.sh`, `scripts/runtime-readiness.sh`

## Start Here
1. [Quickstart](./documentation/quickstart.md) for workstation prerequisites, `vars.nix`, secrets staging, agenix key installation, and the supported destructive disk wrappers.
2. [Operations](./documentation/operations.md) for the canonical validation gate, guarded deploy workflow, runtime readiness, DNS expectations, power checks, storage monitoring, and troubleshooting.
3. [Kanidm Guide](./documentation/kanidm.md) for operator identities, access groups, onboarding, and CLI/TUI workflows.
4. [Restore and Recovery](./documentation/restore-and-recovery.md) for rebuild sequencing, mirrored data-pool recreation, and manual cold-storage operations.
5. [Mail Archive UI](./rust/apps/mail-archive-ui/README.md) for the private mail archive control plane and its storage model.

Validation gate: see [Operations](./documentation/operations.md#2-common-commands) for the canonical `nix flake check --no-build` and `scripts/check-repo.sh` workflow.

Deploy entry point: `./scripts/deploy-validated.sh --help`
