# NixHomeServer

Declarative NixOS home server designed for reliable self-hosting with clear security boundaries.

## What this stack does
- Identity and SSO: Kanidm
- Public auth gateway: OAuth2 Proxy
- Reverse proxy and TLS policy boundary: Caddy
- Internet exposure: Cloudflare Tunnel (public endpoints only)
- Private remote access: NetBird mesh
- Internal DNS authority: Unbound
- Apps: Immich, Paperless-ngx, Audiobookshelf, Copyparty, Kavita, Jellyfin, Jellyseerr
- Mail archive and search: IMAP to local Maildir plus Notmuch over SSH/CLI
- Storage layout: Btrfs system SSD + Disko-managed ZFS mirrored data pool + manual cold-storage pool
- Storage topology is config-driven from `vars.nix`
- Declarative power policy: nightly suspend, RTC wake, Wake-on-LAN, and low-risk power tuning

## Access model
- Public internet endpoints: `https://id.<domain>`, `https://files.<domain>`
- Private app endpoints: `paperless`, `photos`, `audiobooks`, `books`, `videos`, `jellyseerr`
  - on the home LAN, these are intended to work through router-forwarded split DNS
  - off the home LAN, they require NetBird
- Caddy is the routing boundary for all app traffic.
- Kanidm is default-deny for app access; users only reach apps through
  app-specific groups.
- `admindsaw` is the intended admin identity and `dsaw` is the intended
  day-to-day identity.

## Validation and Recovery
- Primary validation gate: `nix flake check --no-build`
- Guarded deploy helper: `./scripts/deploy-validated.sh --target <user@host>`
- Recovery path: declarative rebuild plus ZFS pool validation

## Start here
1. [First Admin Session](./documentation/first-admin-session.md) if the server already exists and you need to understand how to operate it.
2. [Quickstart](./documentation/quickstart.md) for the shortest copy-paste deployment path.
3. [Install From Scratch](./documentation/install-from-scratch.md) if you are provisioning blank disks.
4. [Secrets and Prerequisites](./documentation/secrets-and-prereqs.md) before first deploy.
5. [Operations](./documentation/operations.md) for validation, deploy, checks, and troubleshooting.
6. [Restore and Recovery](./documentation/restore-and-recovery.md) for rebuild and storage-recovery ordering.
7. [Kanidm Guide](./documentation/kanidm.md) for user/group setup.
8. [Mail Archive](./documentation/mail-archive.md) for per-user email backup and search.
9. [Documentation Index](./documentation/README.md) for the task-oriented doc map.
