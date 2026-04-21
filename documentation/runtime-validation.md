# Runtime Validation

Use this checklist after a deploy, after auth or routing changes, after a restore, or after the router cutover.

If nightly suspend is enabled, run this outside the sleep window. If the server recently resumed, include one quick post-resume pass for Caddy, Cloudflared, Unbound, NetBird, and SSH.

## 1. Automated baseline
Run on the server:

```bash
./scripts/runtime-readiness.sh
```

This is the main smoke-test path. It checks:

- core units
- public and private HTTPS entrypoints
- direct Copyparty upstream reachability on `http://127.0.0.1:3923/`
- Unbound recursion plus hosted and LAN-only forward/reverse DNS records
- the ZFS data-pool mount plus expected child datasets
- SMART degradation warnings for configured pool disks and the manual cold-storage disk
- ZFS pool health and dataset visibility

If this fails, stop and fix infrastructure first.

## 2. Public/private access spot-check
Confirm the public endpoints work:

- `https://id.<domain>`
- `https://files.<domain>`

Confirm the private endpoints work over NetBird and, when router forwarding is configured, on the home LAN:

- `https://emails.<domain>` over NetBird, and on the home LAN when router forwarding is configured
- `https://paperless.<domain>` over NetBird, and on the home LAN when router forwarding is configured
- `https://photos.<domain>` over NetBird, and on the home LAN when router forwarding is configured
- `https://audiobooks.<domain>` over NetBird, and on the home LAN when router forwarding is configured
- `https://books.<domain>` over NetBird, and on the home LAN when router forwarding is configured
- `https://videos.<domain>` over NetBird, and on the home LAN when router forwarding is configured
- `https://jellyseerr.<domain>` over NetBird, and on the home LAN when router forwarding is configured

DNS expectations:

- `dnsMode = "netbird-only"`:
  - private names resolve to `vars.nbIP`
  - `id.<domain>` and `files.<domain>` follow the public path
- `dnsMode = "split-horizon"`:
  - direct queries to the server's Unbound LAN view resolve hosted names to `vars.serverLanIP`
  - LAN-only device names under `vars.lanDnsDomain` resolve from `vars.lanDnsHosts`
  - reverse lookups for those LAN entries resolve locally as well
  - in the recommended router-forwarded model, only the private app hostnames should resolve to `vars.serverLanIP` through the router
  - `id.<domain>` and `files.<domain>` should stay on the router's normal public DNS path so they still work when server DNS is unavailable
  - private names still resolve to `vars.nbIP` over NetBird

## 3. Identity and delegated admin
Validate the operator identity first:

- sign into Kanidm as `admindsaw`
- run `kanidm reauth`
- confirm the delegated admin path works through the CLI or `kanidm-user-tui`
- avoid using break-glass `admin` or `idm_admin` for routine validation

## 4. Manual app checks that still matter
These behaviors still need a human spot-check after major changes:

- Files / Copyparty:
  - logged-out users are redirected through OAuth2 Proxy
  - the logged-in UI shows only `/my-files` and `/shared`
  - a `fileshare_users` member can upload, download, rename, and delete
  - a logged-in user can create a share link
  - a logged-out browser can open the resulting `/shares/...` link
  - unrelated `files` paths still require OAuth
  - `/shared` reads and writes to `/mnt/data/workspaces/shared/public`
- Mail archive:
  - a `mail-archive-users` member can open the UI, trigger a sync, and search
- Immich:
  - first successful OIDC login creates the local user row
  - upload works for a normal user
- Paperless:
  - first successful OIDC login creates or links the local user row
  - document ingest still works
- Audiobookshelf:
  - OIDC login works and local bootstrap access still exists
- Kavita:
  - OIDC login works
  - admin remains app-local unless you intentionally change that policy
- Jellyfin / Jellyseerr:
  - local auth and the Jellyfin-backed chain still work

## 5. Storage and write-path spot-check
Confirm these paths still match the current array topology from `vars.nix`:

- `/mnt/data/appdata`
- `/mnt/data/media`
- `/mnt/data/workspaces`
- `/mnt/data/mail-archive`

Quick checks:

- `findmnt -R /mnt` shows `/mnt/data` and the expected ZFS child datasets
- `/mnt/cold-storage` exists but is not mounted unless you mounted it intentionally
- the LAN SMB `data` share mounts successfully for `admindsaw`
- the LAN SMB `data` share can read and write under `/mnt/data/media`, `/mnt/data/workspaces`, `/mnt/data/mail-archive`, and `/mnt/data/appdata`
- SMB access over NetBird no longer succeeds
- Copyparty `/shared` still maps to `/mnt/data/workspaces/shared/public`
- Immich managed uploads stay out of the external import root
- Paperless ingest still lands in `/mnt/data/media/documents/consume`
- runtime readiness shows no critical SMART degradation on active array disks
- `zpool status data` remains healthy after the validation write-path tests

## 6. Router cutover validation

### Pre-cutover / transition state
Before the LAN cutover completes:

- deploy and SSH commands may still need `CURRENT_SERVER_IP`
- `vars.serverLanIP` and `vars.serverLanGateway` should remain the intended
  final LAN values
- local-console deploy is the preferred path while the gateway, subnet, or
  switch port is actively changing

### Post-cutover final-state checks
After the LAN cutover:

```bash
ip -4 addr show dev enp34s0
ip route
networkctl status enp34s0
```

Expected:

- the interface has the static address `192.168.8.12`
- the default route points at `192.168.8.1`
- the host still uses `127.0.0.1` for local DNS resolution

Then confirm:

- SSH works to `dsaw@192.168.8.12`
- `./scripts/runtime-readiness.sh` passes
- a LAN client using router DHCP resolves private app names to `192.168.8.12`
- that same LAN client resolves `id.<domain>` and `files.<domain>` through the normal public path

Router-forwarding spot check from a LAN client:

```bash
host paperless.<domain> <router-ip>
host photos.<domain> <router-ip>
host emails.<domain> <router-ip>
host id.<domain> <router-ip>
host files.<domain> <router-ip>
```

Expected:

- `paperless/photos/emails/audiobooks/books/videos/jellyseerr` -> `192.168.8.12`
- `id/files` -> non-`192.168.8.12` public answer

## 7. Cleanup
After a full manual pass:

- remove any temporary Kanidm test users
- remove temporary uploaded test files and documents
- note any app that still requires local admin promotion
- update docs if the validation uncovered a real behavior change
