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
- Unbound answers hosted DNS records over NetBird and on the LAN in split-horizon mode.
- On the LAN, the recommended path is router DHCP -> router DNS -> conditional forwarding for private app names to this server.

## Endpoint matrix
Private app hostnames stay off the public internet, but in the recommended split-horizon setup they are reachable both on the home LAN and over NetBird.

| Hostname | Public internet | LAN access | NetBird required off-LAN | Purpose |
|---|---:|---:|---:|---|
| `id.<domain>` | Yes | Yes | No | Kanidm login and OIDC identity provider |
| `files.<domain>` | Yes | Yes | No | OAuth2 Proxy + Copyparty public file flow |
| `emails.<domain>` | No | Yes | Yes | Mail archive UI |
| `paperless.<domain>` | No | Yes | Yes | Paperless app |
| `photos.<domain>` | No | Yes | Yes | Immich app |
| `audiobooks.<domain>` | No | Yes | Yes | Audiobookshelf app |
| `books.<domain>` | No | Yes | Yes | Kavita app |
| `videos.<domain>` | No | Yes | Yes | Jellyfin app |
| `jellyseerr.<domain>` | No | Yes | Yes | Jellyseerr app |

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
  - the recommended LAN model is that clients keep using the router as their only DNS server
  - the router conditionally forwards only the private app hostnames to `vars.serverLanIP`
  - private app names resolve to `vars.serverLanIP` on LAN when queried through those router forward rules
  - LAN-only device records are served from `vars.lanDnsDomain` and default to:
    - `<hostname>.home.arpa` -> `vars.serverLanIP`
    - `router.home.arpa` -> `vars.serverLanGateway`
  - reverse DNS for entries in `vars.lanDnsHosts` is served from the matching
    `in-addr.arpa` zone
  - NetBird clients still resolve private app names to `vars.nbIP`
  - `id.<domain>` and `files.<domain>` stay public for NetBird clients and should usually stay on the router's normal public DNS path on LAN for graceful fallback

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
- `fileshare_users` gates browser access to `https://files.<domain>` through
  OAuth2 Proxy
- the broad SMB `data` share is intentionally separate and gated to the
  delegated admin account
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
- Private LAN flow:
  - SMB is exposed only on the primary LAN interface
  - the only share is `data`
  - the share maps to `/mnt/data`
  - the share is intended for the delegated admin account, not general `fileshare_users`
  - no NetBird or internet-facing SMB listener is exposed

Aligned storage roots:

- Copyparty `/my-files` -> `/mnt/data/workspaces/users/%U/files`
- Copyparty `/shared` -> `/mnt/data/workspaces/shared/public`
- SMB `data` -> `/mnt/data`

## Mail archive access model

- Private browser flow:
  - `emails.<domain>` is private-only and served through Caddy
  - a dedicated oauth2-proxy instance enforces `mail-archive-users`
  - the UI reads the forwarded Kanidm username and keeps every mailbox, sync, and search action scoped to that user
- Storage model:
  - app config, sqlite state, and the encryption key live under `/mnt/data/appdata/mail-archive-ui`
  - downloaded mail lives under `/mnt/data/mail-archive/users/<user>/accounts/<account-id>/`
  - downloaded Maildir data is not exposed through Copyparty, but it is reachable through the admin-only SMB `data` share

## DNS Mode Toggle
Set [`vars.dnsMode`](/home/dsaw/Projects/NixOS/vars.nix) to one of:

- `"netbird-only"` for the current model where clients rely on NetBird DNS distribution
- `"split-horizon"` when you want LAN-local answers available through this server and router forwarding

Router/LAN intent in split-horizon mode:
- keep `vars.serverLanIP` and `vars.serverLanGateway` aligned with the active LAN
- have DHCP advertise the router as the only DNS server for LAN clients
- use router conditional forwarding for only the private app hostnames:
  - `paperless.<domain>`
  - `photos.<domain>`
  - `emails.<domain>`
  - `audiobooks.<domain>`
  - `books.<domain>`
  - `videos.<domain>`
  - `jellyseerr.<domain>`
- do not forward the whole `sydneybasiniot.org` zone to this server if you want `id.<domain>` and `files.<domain>` to keep graceful public fallback
- ensure the router accepts traffic for `vars.serverLanIP` on that subnet
- add or update LAN device records in [`vars.nix`](/home/dsaw/Projects/NixOS/vars.nix)
  under `lanDnsHosts` when you want forward and reverse lookups for those devices

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

# on the server or a LAN client using this resolver
host server.home.arpa 192.168.8.12
host 192.168.8.12 192.168.8.12

# from a LAN client using the router as DNS
host paperless.<domain> <router-ip>
host photos.<domain> <router-ip>
host emails.<domain> <router-ip>
host id.<domain> <router-ip>
host files.<domain> <router-ip>
```

Expected:
- in `netbird-only` mode:
  - `paperless/photos/emails/audiobooks/books/videos/jellyseerr` -> NetBird IP
  - `id/files` -> public Cloudflare path
- in `split-horizon` mode on LAN:
  - `paperless/photos/emails/audiobooks/books/videos/jellyseerr` -> server LAN IP through router conditional forwarding
  - `id/files` -> public Cloudflare path unless you intentionally choose a more complex LAN-local rule
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
- client bypassing the router and using public recursion directly on the LAN
- split-horizon enabled but the router is not conditionally forwarding the private app names to this server
