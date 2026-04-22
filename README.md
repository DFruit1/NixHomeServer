# NixHomeServer

Declarative NixOS home server optimized for reliability, security, and reproducibility.

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

## Access model
- Public endpoints: `https://id.<domain>`, `https://files.<domain>`
- Private app endpoints: `emails`, `paperless`, `photos`, `audiobooks`, `books`, `videos`
- Private apps are intended to work on the home LAN through router-forwarded split DNS and off-LAN through NetBird
- Caddy is the routing boundary for app traffic
- Kanidm group membership decides app access

## Start Here
1. [Quickstart](./documentation/quickstart.md) for first deploys, blank-machine installs, secrets staging, and disk wrapper entrypoints.
2. [Operations](./documentation/operations.md) for validation, guarded deploys, DNS expectations, power checks, storage monitoring, and troubleshooting.
3. [Kanidm Guide](./documentation/kanidm.md) for operator identities, access groups, onboarding, and CLI/TUI workflows.
4. [Restore and Recovery](./documentation/restore-and-recovery.md) for rebuild and data-pool recovery sequencing.
5. [Mail Archive UI](./rust/apps/mail-archive-ui/README.md) for the private mail archive control plane and its storage model.

## Validation Gate
```bash
nix flake check --no-build
scripts/check-repo.sh
```

## Deploy Entry Point
```bash
./scripts/deploy-validated.sh --help
```
