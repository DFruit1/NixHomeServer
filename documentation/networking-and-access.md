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
systemctl status cloudflared-tunnel-metro netbird-main unbound caddy

# from a NetBird client
host paperless.<domain> 127.0.0.1
host photos.<domain> 127.0.0.1
host id.<domain> 127.0.0.1
host files.<domain> 127.0.0.1
```

Expected:
- `paperless/photos/audiobooks/books/video/jellyseerr` -> NetBird IP
- `id/files` -> public Cloudflare path

## Failure entrypoints

### Public endpoint fails

Check:

```bash
systemctl status caddy cloudflared-tunnel-metro
journalctl -u caddy -u cloudflared-tunnel-metro -n 100 --no-pager
```

Likely causes:

- the current tunnel unit name changed and you are checking the wrong unit
- tunnel unit down
- Caddy upstream mismatch
- Cloudflare DNS or tunnel ingress drift

### Private hostname resolves wrongly

Check:

```bash
systemctl status unbound netbird-main
host paperless.<domain> 127.0.0.1
host photos.<domain> 127.0.0.1
resolvectl query paperless.<domain>
```

Likely causes:

- NetBird DNS distribution not active on the client
- Unbound not serving the expected private records
- client bypassing NetBird DNS and using public recursion instead

## Optional DietPi companion
Only applies when `enableDietPiCompanion = true` in [`vars.nix`](/home/dsaw/Projects/NixOS/vars.nix).

Recommended split:
- DietPi: DHCP + primary LAN DNS filtering (AdGuard Home)
- NixHomeServer: app host + identity + private DNS authority

Use one authoritative source for local overrides to avoid split-brain.
