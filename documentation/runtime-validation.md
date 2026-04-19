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
- Unbound answers for private hostnames
- mergerfs plus all configured data and parity mounts
- `/mnt/backup` when `enableBackupDisk = true`
- SMART degradation warnings for configured array disks and any attached backup disk
- SnapRAID status and drift

If this fails, stop and fix infrastructure first.

## 2. Public/private access spot-check
Confirm the public endpoints work:

- `https://id.<domain>`
- `https://files.<domain>`

Confirm the private endpoints still require NetBird reachability:

- `https://emails.<domain>`
- `https://paperless.<domain>`
- `https://photos.<domain>`
- `https://audiobooks.<domain>`
- `https://books.<domain>`
- `https://videos.<domain>`
- `https://jellyseerr.<domain>`

DNS expectations:

- `dnsMode = "netbird-only"`:
  - private names resolve to `vars.nbIP`
  - `id.<domain>` and `files.<domain>` follow the public path
- `dnsMode = "split-horizon"`:
  - hosted names resolve to `vars.serverLanIP` on LAN
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
  - a `fileshare_users` member can upload, download, rename, and delete
  - a logged-in user can create a share link
  - a logged-out browser can open the resulting `/shares/...` link
  - unrelated `files` paths still require OAuth
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

- `findmnt -R /mnt` shows `/mnt/data`, every configured data disk mount, and all configured parity mounts
- `findmnt /mnt/backup` succeeds when the backup disk is enabled
- `/mnt/cold-storage` exists but is not mounted unless you mounted it intentionally
- Copyparty shared paths still map to the expected workspace and ingest roots
- Immich managed uploads stay out of the external import root
- Paperless ingest still lands in `/mnt/data/media/documents/consume`
- runtime readiness shows no critical SMART degradation on active array disks
- `snapraid diff` does not show anything unexpected after the validation write-path tests

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

## 7. Cleanup
After a full manual pass:

- remove any temporary Kanidm test users
- remove temporary uploaded test files and documents
- note any app that still requires local admin promotion
- update docs if the validation uncovered a real behavior change
