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
- mergerfs and SnapRAID for data storage

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

Public endpoints:

- `https://id.<domain>`
- `https://files.<domain>`

NetBird-only endpoints:

- `https://paperless.<domain>`
- `https://photos.<domain>`
- `https://audiobooks.<domain>`
- `https://books.<domain>`
- `https://video.<domain>`
- `https://jellyseerr.<domain>`

## Access Matrix

| Service | URL | Auth model | Login group | Admin group | First login behavior | Local fallback |
|---|---|---|---|---|---|---|
| Kanidm | `https://id.<domain>` | Kanidm native | n/a | `idm_admins` for delegated admins | no downstream provisioning | `admin`, `idm_admin` |
| Files / Copyparty | `https://files.<domain>` | Kanidm through OAuth2 Proxy | `fileshare_users` | app-local only | proxy grants access; Copyparty is not JIT-provisioned here | server-side/app-local |
| Immich | `https://photos.<domain>` | Kanidm OIDC | `immich-users` or `immich-admin` | `immich-admin` | local user row is created on first successful OIDC login | one local recovery admin may still be useful |
| Paperless | `https://paperless.<domain>` | Kanidm OIDC | `paperless-users` or `paperless-admin` | `paperless-admin` | local user row is created or linked on first successful OIDC login | keep one local recovery superuser |
| Audiobookshelf | `https://audiobooks.<domain>` | Kanidm OIDC | `audiobookshelf-users` or `audiobookshelf-admin` | `audiobookshelf-admin` | local user row is created or linked on first successful OIDC login | local root bootstrap account |
| Kavita | `https://books.<domain>` | Kanidm OIDC | `kavita-login` or `kavita-admin` | `kavita-admin` | local account is provisioned on first successful OIDC login | none normally needed |
| Jellyfin | `https://video.<domain>` | local app auth | local only | local only | local user creation only | local admin |
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
- mergerfs mount state
- SnapRAID status and pending drift

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
- Copyparty shows per-user and shared work areas:
  - `/me/<username>`
  - `/shared/exchange`
  - `/shared/public`
  - `/incoming/photos`
  - `/incoming/documents`
- the same logical areas are also available over NetBird-only SMB

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

- OIDC login provisions the local account
- `kavita-admin` is the cleanest group-mapped admin path in this stack

### Jellyfin and Jellyseerr

- they are intentional exceptions
- Jellyfin stays local-auth
- Jellyseerr depends on Jellyfin-backed auth

## Check storage before creating new application data

Run:

```bash
sudo findmnt /mnt/data /mnt/parity
sudo snapraid status
sudo snapraid diff
```

Interpretation:

- `/mnt/data` should be `fuse.mergerfs`
- `/mnt/parity` should be mounted
- `snapraid status` should end with `No error detected.`
- `snapraid diff` may show updated app databases and logs between sync runs

Do not treat non-empty `snapraid diff` as a fault by itself. It is expected when
applications are active.

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
nix run nixpkgs#nixos-rebuild -- test \
  --flake .#server \
  --target-host <admin-user>@<server-lan-ip> \
  --build-host <admin-user>@<server-lan-ip> \
  --sudo \
  --ask-sudo-password \
  --no-reexec
```

or, after the test generation looks good:

```bash
nix run nixpkgs#nixos-rebuild -- switch \
  --flake .#server \
  --target-host <admin-user>@<server-lan-ip> \
  --build-host <admin-user>@<server-lan-ip> \
  --sudo \
  --ask-sudo-password \
  --no-reexec
```

## If something is wrong

Start with:

- [Operations](./operations.md) for symptom-based troubleshooting
- [Networking and Access](./networking-and-access.md) for DNS and reachability
- [Kanidm Guide](./kanidm.md) for identity and group issues
- [Runtime Validation](./runtime-validation.md) for app-by-app expected behavior
