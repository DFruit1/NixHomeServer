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
- Unbound answers hosted DNS records over NetBird, and optionally on the LAN in split-horizon mode.

## Endpoint matrix
All non-public app hostnames in this stack are intentionally **NetBird-only**.

| Hostname | Public internet | NetBird required | Purpose |
|---|---:|---:|---|
| `id.<domain>` | Yes | No | Kanidm login and OIDC identity provider |
| `files.<domain>` | Yes | No | OAuth2 Proxy + Copyparty public file flow |
| `emails.<domain>` | No | Yes | Mail archive UI |
| `paperless.<domain>` | No | Yes | Paperless app |
| `photos.<domain>` | No | Yes | Immich app |
| `audiobooks.<domain>` | No | Yes | Audiobookshelf app |
| `books.<domain>` | No | Yes | Kavita app |
| `videos.<domain>` | No | Yes | Jellyfin app |
| `jellyseerr.<domain>` | No | Yes | Jellyseerr app |

Availability note:

- when power management is enabled, these routes are intentionally unavailable
  during the nightly suspend window
- see [Power Management](./power-management.md) for the sleep schedule and wake
  validation flow

## DNS behavior
- `dnsMode = "netbird-only"`:
  - private app hostnames resolve to `vars.nbIP` (server NetBird IP)
  - `id.<domain>` and `files.<domain>` intentionally recurse to the public Cloudflare path
  - DNS service is meant for NetBird clients, not general LAN recursion
- `dnsMode = "split-horizon"`:
  - the host binds `vars.serverLanIP` directly on `vars.netIface`
  - `vars.serverLanGateway` is the pinned LAN default route
  - LAN clients should use `vars.serverLanIP` as primary DNS when you want hosted names resolved locally
  - hosted names resolve to `vars.serverLanIP` on LAN so on-network traffic stays local
  - NetBird clients still resolve private app names to `vars.nbIP`
  - `id.<domain>` and `files.<domain>` stay public for NetBird clients but resolve locally on LAN

Current default:
- `vars.dnsMode = "split-horizon"`

## Identity and access behavior

- Kanidm is the identity source of truth.
- `users` is a baseline identity group only.
- App access is granted by app-specific groups such as:
  - `immich-users`
  - `paperless-users`
  - `audiobookshelf-users`
  - `kavita-login`
  - `fileshare_users`
  - `mail-archive-users`
- `fileshare_users` now gates both:
  - browser access to `https://files.<domain>` through OAuth2 Proxy
  - SMB access over NetBird to the aligned file shares
- App admin intent is tracked separately with:
  - `immich-admin`
  - `paperless-admin`
  - `audiobookshelf-admin`
  - `kavita-admin`
- Jellyfin and Jellyseerr remain local-auth exceptions in the current stack.

## Files access model

- Public browser flow:
  - `files.<domain>` stays public behind Cloudflare Tunnel, Caddy, and OAuth2 Proxy
  - the main UI remains behind OAuth2 Proxy
  - only the explicit `/shares/...` namespace bypasses OAuth2 Proxy for anonymous share links
  - Copyparty still limits share creation to authenticated users
  - Copyparty consumes the authenticated username from proxy headers
- Private mesh flow:
  - SMB is exposed only on the NetBird interface
  - valid shares are `homes`, `exchange`, `public`, `photos-upload`, and `documents-upload`
  - no LAN or internet-facing SMB listener is exposed
  - the SMB shares map to the same storage roots Copyparty exposes for private files and ingest

Aligned storage roots:

- `homes` -> `/mnt/data/workspaces/users/%U/files`
- `exchange` -> `/mnt/data/workspaces/shared/exchange`
- `public` -> `/mnt/data/workspaces/shared/public`
- `photos-upload` -> `/mnt/data/media/photos/external`
- `documents-upload` -> `/mnt/data/media/documents/consume`

## Mail archive access model

- Private browser flow:
  - `emails.<domain>` is private-only and served through Caddy
  - a dedicated oauth2-proxy instance enforces `mail-archive-users`
  - the UI reads the forwarded Kanidm username and keeps every mailbox, sync, and search action scoped to that user
- Storage model:
  - app config, sqlite state, and the encryption key live under `/mnt/data/appdata/mail-archive-ui`
  - downloaded mail lives under `/mnt/data/mail-archive/users/<user>/accounts/<account-id>/`
  - downloaded Maildir data is intentionally not exposed through Copyparty or SMB

## DNS Mode Toggle
Set [`vars.dnsMode`](/home/dsaw/Projects/NixOS/vars.nix) to one of:

- `"netbird-only"` for the current model where clients rely on NetBird DNS distribution
- `"split-horizon"` when you want LAN clients to prefer this server for hosted names

Router/LAN intent in split-horizon mode:
- keep `vars.serverLanIP` and `vars.serverLanGateway` aligned with the active LAN
- advertise the server as primary LAN DNS if you want local hosted-name resolution
- remove competing router-side overrides for `sydneybasiniot.org` unless they delegate back to this server resolver
- ensure the router accepts traffic for `vars.serverLanIP` on that subnet

During a cutover, the current SSH endpoint may temporarily differ from
`vars.serverLanIP`. Keep `vars.serverLanIP` pointed at the intended final
address and use a local `CURRENT_SERVER_IP` override in deploy commands until
the router change is complete.

## NetBird DNS distribution
Private names only work on clients where NetBird distributes your server resolver. In the current split-horizon model:

- NetBird clients should keep receiving `100.72.113.237` as the hosted resolver for private names
- the server itself should keep using local Unbound on `127.0.0.1`
- exclude the server peer from NetBird hosted-DNS assignment so NetBird does not try to replace the server-side DNS listener

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
host emails.<domain> 127.0.0.1
host id.<domain> 127.0.0.1
host files.<domain> 127.0.0.1
```

Expected:
- in `netbird-only` mode:
  - `paperless/photos/emails/audiobooks/books/videos/jellyseerr` -> NetBird IP
  - `id/files` -> public Cloudflare path
- in `split-horizon` mode on LAN:
  - `id/files/paperless/photos/emails/audiobooks/books/videos/jellyseerr` -> server LAN IP
- in `split-horizon` mode over NetBird:
  - private app names -> NetBird IP
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
host emails.<domain> 127.0.0.1
resolvectl query paperless.<domain>
```

Likely causes:

- NetBird DNS distribution not active on the client
- Unbound not serving the expected private records
- client bypassing NetBird DNS and using public recursion instead
- split-horizon enabled but the router is not advertising the server as the primary LAN DNS
