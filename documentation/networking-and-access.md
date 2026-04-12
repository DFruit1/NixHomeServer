# Networking and Access

This guide explains what is public, what is private, and why.

## Why this model exists
- Keep internet exposure minimal.
- Require identity for all user-facing access.
- Keep private apps off public DNS and public ingress.
- Make remote private access consistent on and off your home LAN.

## Core boundary
- Caddy is the local policy boundary for app routing and TLS termination.
- Cloudflare Tunnel publishes only the endpoints that must be internet-reachable.
- NetBird carries private app traffic to the server.
- Unbound answers private DNS records over NetBird.

## Endpoint matrix
All non-public app hostnames in this stack are intentionally **NetBird-only**.

| Hostname | Public internet | NetBird required | Purpose |
|---|---:|---:|---|
| `id.<domain>` | Yes | No | Kanidm login and OIDC identity provider |
| `files.<domain>` | Yes | No | OAuth2 Proxy + Copyparty public file flow |
| `paperless.<domain>` | No | Yes | Paperless app |
| `photos.<domain>` | No | Yes | Immich app |
| `audiobooks.<domain>` | No | Yes | Audiobookshelf app |
| `books.<domain>` | No | Yes | Kavita app |
| `video.<domain>` | No | Yes | Jellyfin app |
| `jellyseerr.<domain>` | No | Yes | Jellyseerr app |

## DNS behavior
- Private app hostnames resolve to `vars.nbIP` (server NetBird IP).
- `id.<domain>` and `files.<domain>` intentionally resolve via Cloudflare public records.
- DNS service is meant for NetBird clients, not open LAN/public recursive use.

## Identity and access behavior

- Kanidm is the identity source of truth.
- `users` is a baseline identity group only.
- App access is granted by app-specific groups such as:
  - `immich-users`
  - `paperless-users`
  - `audiobookshelf-users`
  - `kavita-login`
  - `fileshare_users`
- App admin intent is tracked separately with:
  - `immich-admin`
  - `paperless-admin`
  - `audiobookshelf-admin`
  - `kavita-admin`
- Jellyfin and Jellyseerr remain local-auth exceptions in the current stack.

## NetBird DNS distribution
Private names only work on clients where NetBird distributes your server resolver.

Check server NetBird interface:
```bash
ip -brief addr show nb0
```

If `netbird-main status` shows `Nameservers: 0/0 Available`, DNS distribution is not configured in NetBird yet.

## Quick checks
```bash
# server-side
systemctl status cloudflared netbird-main unbound caddy

# from a NetBird client
dig +short paperless.<domain>
dig +short photos.<domain>
dig +short id.<domain>
dig +short files.<domain>
```

Expected:
- `paperless/photos/audiobooks/books/video/jellyseerr` -> NetBird IP
- `id/files` -> public Cloudflare path

## Optional DietPi companion
Only applies when `enableDietPiCompanion = true` in [`vars.nix`](/home/dsaw/Projects/NixOS/vars.nix).

Recommended split:
- DietPi: DHCP + primary LAN DNS filtering (AdGuard Home)
- NixHomeServer: app host + identity + private DNS authority

Use one authoritative source for local overrides to avoid split-brain.
