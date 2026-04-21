# First Admin Session

Use this guide after the server is already deployed and reachable. It is the
best starting point for a new operator who did not build the system.

## What this server is

This host is a NixOS home server with:

- Kanidm for identity and OIDC
- Caddy for HTTPS and reverse proxying
- Cloudflare Tunnel for the public edge
- NetBird for private remote access
- Unbound for private DNS answers
- a mirrored ZFS data pool plus manual cold-storage import tooling

The important operational rule is simple: Kanidm knows who a person is, but
Kanidm group membership decides which apps they may use.

## Which account to use

- `admindsaw`: privileged operator identity
- `dsaw`: normal day-to-day identity
- `admin` and `idm_admin`: break-glass Kanidm accounts only

Use `admindsaw` for:

- user and group administration
- application bootstrap
- rebuilds and infrastructure work

Use `dsaw` for:

- normal daily use
- testing non-admin access

Do not use `users` membership as a shortcut for application access. In this
stack, `users` only means the person exists.

## How to reach the services

Public-capable endpoints:

- `https://id.<domain>`
- `https://files.<domain>`

Private app endpoints:

- `https://paperless.<domain>`
- `https://photos.<domain>`
- `https://audiobooks.<domain>`
- `https://books.<domain>`
- `https://videos.<domain>`
- `https://jellyseerr.<domain>`

On the home LAN, these private app endpoints are intended to work through the
router-forwarded split-DNS path. Off the home LAN, they require NetBird.

When the default nightly suspend policy is enabled, all app endpoints and SSH
are intentionally unavailable during the configured suspend window. Run
connectivity checks outside that window or after the morning resume. See
[Power Management](./power-management.md).

## Access Matrix

| Service | URL | Auth model | Login group | Admin group | First login behavior | Local fallback |
|---|---|---|---|---|---|---|
| Kanidm | `https://id.<domain>` | Kanidm native | n/a | `idm_admins` for delegated admins | no downstream provisioning | `admin`, `idm_admin` |
| Files / Copyparty | `https://files.<domain>` | Kanidm through OAuth2 Proxy | `fileshare_users` | app-local only | proxy grants access; personal workspaces are materialized from `fileshare_users` membership | server-side/app-local |
| Immich | `https://photos.<domain>` | Kanidm OIDC | `immich-users` or `immich-admin` | `immich-admin` | local user row is created on first successful OIDC login | one local recovery admin may still be useful |
| Paperless | `https://paperless.<domain>` | Kanidm OIDC | `paperless-users` or `paperless-admin` | `paperless-admin` | local user row is created or linked on first successful OIDC login | keep one local recovery superuser |
| Audiobookshelf | `https://audiobooks.<domain>` | Kanidm OIDC | `audiobookshelf-users` or `audiobookshelf-admin` | `audiobookshelf-admin` | local user row is created or linked on first successful OIDC login | local root bootstrap account |
| Kavita | `https://books.<domain>` | Kanidm OIDC | `kavita-login` or `kavita-admin` | local Kavita admin | fresh databases still require a one-time local admin bootstrap before normal OIDC provisioning | local admin bootstrap and promotion currently required |
| Jellyfin | `https://videos.<domain>` | local app auth | local only | local only | local user creation only | local admin |
| Jellyseerr | `https://jellyseerr.<domain>` | Jellyfin-backed auth | Jellyfin-driven | Jellyfin/Jellyseerr local | bootstrap through Jellyfin login | local/Jellyfin-backed admin |

## Confirm DNS and routing first

Run this on the server:

```bash
./scripts/runtime-readiness.sh
```

This checks:

- service units
- public and private HTTPS entrypoints
- private DNS answers from Unbound
- the ZFS data pool plus expected child datasets
- SMART degradation warnings for configured storage disks
- ZFS pool health and dataset visibility

If you prefer the manual path, see [Operations](./operations.md).

## Log into Kanidm

From the server or a workstation with the Kanidm CLI:

```bash
nix shell nixpkgs#kanidm_1_9 --impure
kanidm login --url https://id.<domain> --name admindsaw
kanidm reauth --url https://id.<domain> --name admindsaw
```

If the web UI looks limited, that is expected. The CLI or `kanidm-user-tui`
is the reliable administrative path.

## Create a new person

On the server:

```bash
kanidm-user-tui
```

Or use the command reference in [Kanidm CLI Reference](./kanidm_cli.md).

Baseline workflow:

1. create the person
2. add them to `users`
3. add only the app-specific `*-users` groups they need
4. add `*-admin` groups only if they should administer those apps
5. have them sign into the app for first-time local account creation

## App group map

Login access groups:

- `fileshare_users`
- `immich-users`
- `paperless-users`
- `audiobookshelf-users`
- `kavita-login`

Admin intent groups:

- `immich-admin`
- `paperless-admin`
- `audiobookshelf-admin`
- `kavita-admin`

## What happens on first login

### Files / Copyparty

- access is enforced by OAuth2 Proxy before the app
- `fileshare_users` membership now pre-creates each user workspace for web access
- Copyparty shows two top-level roots:
  - `/my-files`
  - `/shared`
- `/shared` is the single shared area and maps to the existing public workspace root
- logout clears the app session and immediately restarts the oauth2-proxy login
  flow
- authenticated users can create Copyparty share links
- anonymous visitors may open only the explicit `/shares/...` links
- normal UI browsing and unrelated paths still require OAuth
- SMB no longer mirrors the Copyparty areas; the server instead exposes one LAN-only admin share for `/mnt/data`

### Immich

- successful OIDC login creates the local user row
- admin intent is tracked by `immich-admin`
- if app-native admin mapping is ever insufficient, keep one local recovery
  admin available

### Paperless

- successful OIDC login creates or links the local user row
- the first social-login user can become the initial superuser
- keep one local recovery superuser even after OIDC is working

### Audiobookshelf

- OIDC is configured and the bootstrap root account exists
- `admindsaw` is expected to link against the bootstrap flow
- additional admins may still need app-local promotion after the first OIDC
  login

### Kavita

- a fresh Kavita database still shows the local admin registration flow until an
  initial admin exists
- after that one-time bootstrap, OIDC login provisions the local account
- `kavita-admin` is still the intended admin cohort, but current Kavita roles stay local after OIDC login

### Jellyfin and Jellyseerr

- they are intentional exceptions
- Jellyfin stays local-auth
- Jellyseerr depends on Jellyfin-backed auth

## Check storage before creating new application data

Run:

```bash
sudo findmnt -R /mnt
sudo zpool status data
sudo zfs list -r data
```

Interpretation:

- `/mnt/data` should be `zfs`
- the expected child datasets from `vars.zfsDataPool.datasets` should be mounted
- `zpool status data` should report the pool healthy
- `./scripts/runtime-readiness.sh` should not report critical SMART degradation on active array disks
- the manual cold-storage pool should remain unmounted until you intentionally import it with `scripts/cold-storage.sh`

Current canonical paths:

- app state: `/mnt/data/appdata`
- media libraries: `/mnt/data/media`
- personal and shared workspaces: `/mnt/data/workspaces`

## Safe rebuild flow

From repo root:

```bash
nix flake check --no-build
scripts/check-repo.sh
```

Then either:

```bash
./scripts/deploy-validated.sh \
  --target <admin-user>@<current-server-ip> \
  --build-host <admin-user>@<current-server-ip> \
  --action test \
  --hostname server
```

or, after the test generation looks good:

```bash
./scripts/deploy-validated.sh \
  --target <admin-user>@<current-server-ip> \
  --build-host <admin-user>@<current-server-ip> \
  --hostname server \
  --action switch
```

Use the current reachable server address during a migration window. Keep
`vars.serverLanIP` reserved for the intended final LAN address.

Use raw `nixos-rebuild` only as a manual fallback when the wrapper is not
appropriate.

## If something is wrong

Start with:

- [Operations](./operations.md) for symptom-based troubleshooting
- [Networking and Access](./networking-and-access.md) for DNS and reachability
- [Kanidm Guide](./kanidm.md) for identity and group issues
- [Runtime Validation](./runtime-validation.md) for app-by-app expected behavior
