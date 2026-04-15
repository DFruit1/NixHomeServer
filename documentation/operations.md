# Operations

This is the main troubleshooting and day-to-day operations guide.

## Account model reminders

- `admindsaw` is the intended privileged operator identity.
- `dsaw` is the intended normal daily-use identity.
- `users` is baseline identity only; it does not grant app access.
- app login is controlled by app-specific groups:
  - `immich-users`
  - `paperless-users`
  - `audiobookshelf-users`
  - `kavita-login`
  - `fileshare_users`
- app admin intent is tracked separately:
  - `immich-admin`
  - `paperless-admin`
  - `audiobookshelf-admin`
  - `kavita-admin`
- Jellyfin and Jellyseerr remain local-auth exceptions.

## Validate before deploy
Run from repo root:
```bash
nix flake check --no-build
scripts/check-repo.sh
tests/run-all.sh
```

Optional runtime companion checks:
```bash
tests/run-all.sh --with-runtime
./scripts/runtime-readiness.sh
./scripts/runtime-validation-report.sh
```

## Storage layout

Canonical persistent paths now live under:

- `/mnt/data/appdata`
- `/mnt/data/media`
- `/mnt/data/workspaces`

Service state roots:

- Audiobookshelf: `/mnt/data/appdata/audiobookshelf`
- Jellyfin: `/mnt/data/appdata/jellyfin/server`
- Jellyseerr: `/mnt/data/appdata/jellyfin/jellyseerr`
- Kavita: `/mnt/data/appdata/kavita`
- Paperless: `/mnt/data/appdata/paperless`

Media and ingest roots:

- Immich managed: `/mnt/data/media/photos/managed`
- Immich external import: `/mnt/data/media/photos/external`
- Paperless consume: `/mnt/data/media/documents/consume`
- Paperless archive: `/mnt/data/media/documents/archive`
- Paperless export: `/mnt/data/media/documents/export`
- Shared exchange: `/mnt/data/workspaces/shared/exchange`
- Shared public: `/mnt/data/workspaces/shared/public`

If you are migrating from the old app-centric layout, run:

```bash
sudo ./scripts/migrate-storage-layout.sh
```

before the rebuild that switches services onto the new paths.

## Deploy workflows

### A) Local-first on target host (safest)
```bash
ssh <admin-user>@<server-lan-ip>
# then on the server:
# sudo -i
# cd /etc/nixos
# nix flake check --no-build
# scripts/check-repo.sh
# nixos-rebuild test --flake .#server
# systemctl --failed
# nixos-rebuild switch --flake .#server
```

### B) Remote from workstation
```bash
nix run nixpkgs#nixos-rebuild -- test \
  --flake .#server \
  --target-host <admin-user>@<server-lan-ip> \
  --build-host <admin-user>@<server-lan-ip> \
  --sudo \
  --ask-sudo-password

nix run nixpkgs#nixos-rebuild -- switch \
  --flake .#server \
  --target-host <admin-user>@<server-lan-ip> \
  --build-host <admin-user>@<server-lan-ip> \
  --sudo \
  --ask-sudo-password
```

## Post-switch checklist

Fast path:

```bash
./scripts/runtime-readiness.sh
```

### SSH and auth policy
- Non-root admin SSH key login works.
- Root SSH login is rejected.
- Password and keyboard-interactive auth are rejected.

### Service health
```bash
systemctl status \
  caddy \
  kanidm \
  oauth2-proxy \
  cloudflared-tunnel-metro \
  unbound \
  immich-server \
  paperless-web \
  audiobookshelf \
  kavita \
  jellyfin \
  jellyseerr \
  netbird-main
systemctl --failed
journalctl -b \
  -u caddy \
  -u kanidm \
  -u oauth2-proxy \
  -u cloudflared-tunnel-metro \
  -u unbound \
  -u immich-server \
  -u paperless-web \
  -u audiobookshelf \
  -u kavita \
  -u jellyfin \
  -u jellyseerr \
  -u netbird-main
```

If SMB is enabled for NetBird clients, also check:

```bash
systemctl status samba-smbd
journalctl -u samba-smbd -n 100 --no-pager
ss -tlpn | grep -E ':(139|445)\s'
```

### Minimal health checklist

- public HTTPS works:
  - `https://id.<domain>`
  - `https://files.<domain>`
- private HTTPS works over NetBird:
  - `paperless`
  - `photos`
  - `audiobooks`
  - `books`
  - `video`
  - `jellyseerr`
- OIDC issuer is reachable
- upstream apps respond
- `/mnt/data` is mounted as mergerfs
- SnapRAID status is clean enough to operate

### DNS and mesh checks

```bash
systemctl status netbird-main unbound
ip -brief addr show nb0
host paperless.<domain> 127.0.0.1
host photos.<domain> 127.0.0.1
host id.<domain> 127.0.0.1
host files.<domain> 127.0.0.1
resolvectl query paperless.<domain>
```

Expected:

- private app names resolve to the server NetBird IP
- `id.<domain>` and `files.<domain>` resolve through the public Cloudflare path

### Storage checks

```bash
sudo findmnt /mnt/data /mnt/parity
sudo systemctl status snapraid-sync.timer snapraid-scrub.timer
sudo snapraid status
sudo snapraid diff
```

Interpretation:

- `/mnt/data` should be mergerfs
- `/mnt/parity` should be mounted
- `snapraid status` should report `No error detected.`
- `snapraid diff` may show updated application databases and logs until the next
  sync; that is expected on a live system

After the storage refactor, spot-check the new roots:

```bash
sudo find /mnt/data/appdata -maxdepth 2 -type d | sort
sudo find /mnt/data/media -maxdepth 3 -type d | sort
sudo find /mnt/data/workspaces -maxdepth 3 -type d | sort
```

### Secrets
```bash
ls -l /run/agenix
```

## Service-specific status checks

### Kanidm

```bash
systemctl status kanidm
journalctl -u kanidm -n 100 --no-pager
curl -skI https://id.<domain>/
```

### Caddy

```bash
systemctl status caddy
journalctl -u caddy -n 100 --no-pager
curl -skI https://id.<domain>/
curl -skI https://files.<domain>/
```

### Cloudflare Tunnel

The current unit name is `cloudflared-tunnel-metro`. In general, the pattern is
`cloudflared-tunnel-<tunnel-name>`.

```bash
systemctl status cloudflared-tunnel-metro
journalctl -u cloudflared-tunnel-metro -n 100 --no-pager
```

### OAuth2 Proxy

```bash
systemctl status oauth2-proxy
journalctl -u oauth2-proxy -n 100 --no-pager
curl -skI https://files.<domain>/
```

### Copyparty

```bash
systemctl status copyparty
journalctl -u copyparty -n 100 --no-pager
```

Healthy signs:

- the page shows the authenticated username after the OAuth flow
- the reverse-proxy warning about untrusted forwarded headers is gone
- `/me/<username>`, `/shared/exchange`, `/shared/public`, `/incoming/photos`, and `/incoming/documents` are visible for allowed users

### Immich

```bash
systemctl status immich-server
journalctl -u immich-server -n 100 --no-pager
curl -skI https://photos.<domain>/
```

### Paperless

```bash
systemctl status paperless-web paperless-scheduler paperless-task-queue
journalctl -u paperless-web -u paperless-scheduler -u paperless-task-queue -n 100 --no-pager
curl -skI https://paperless.<domain>/
```

### Audiobookshelf

```bash
systemctl status audiobookshelf
journalctl -u audiobookshelf -n 100 --no-pager
curl -skI https://audiobooks.<domain>/
```

### Kavita

```bash
systemctl status kavita
journalctl -u kavita -n 100 --no-pager
curl -skI https://books.<domain>/
```

### Jellyfin

```bash
systemctl status jellyfin
journalctl -u jellyfin -n 100 --no-pager
curl -skI https://video.<domain>/
```

### Jellyseerr

```bash
systemctl status jellyseerr
journalctl -u jellyseerr -n 100 --no-pager
curl -skI https://jellyseerr.<domain>/
```

Check the public setup state and the internal Jellyfin target:

```bash
curl -s http://127.0.0.1:5055/api/v1/settings/public | jq
curl -s http://127.0.0.1:8096/System/Info/Public | jq
```

Expected:

- `applicationUrl` is `https://jellyseerr.<domain>`
- Jellyseerr points at Jellyfin on `127.0.0.1:8096`
- users still browse Jellyfin on `https://video.<domain>`

### Kanidm branding

```bash
systemctl status kanidm-branding
journalctl -u kanidm-branding -n 100 --no-pager
```

Expected:

- the apps listing uses the branded service labels `Photos`, `Documents`, `Audiobooks`, `Books`, and `Files`
- the portal logo and service tiles match the repo-managed assets

### SMB over NetBird

```bash
systemctl status samba-smbd
journalctl -u samba-smbd -n 100 --no-pager
```

Expected:

- SMB only listens on `nb0` and loopback
- NetBird clients can authenticate with Kanidm accounts that are in `fileshare_users`
- the aligned shares are `homes`, `exchange`, `public`, `photos-upload`, and `documents-upload`

## Troubleshooting by symptom

### I can log into Kanidm but not the app

Check:

1. the user is in the correct app login group
2. the app hostname is reachable over the expected path
3. the OIDC client callback URL still matches the app hostname

Common causes:

- user is only in `users`
- user is missing `*-users`
- user is in the wrong browser session or stale session state
- app-local bootstrap did not complete on first login

### The app logs in, but I am not an admin

Common causes:

- the app treats Kanidm admin groups as intent only
- local promotion is still required after the first OIDC login
- the user row was created before the current OIDC/admin config existed

Current exceptions to remember:

- Immich may still need local follow-up
- Paperless keeps a recovery superuser path
- Audiobookshelf keeps a root bootstrap path
- Jellyfin and Jellyseerr are not part of the Kanidm admin model

### The hostname resolves incorrectly

Check:

```bash
host paperless.<domain> 127.0.0.1
host photos.<domain> 127.0.0.1
resolvectl query paperless.<domain>
```

Common causes:

- NetBird DNS is not distributed to the client
- Unbound is not serving the expected private records
- the client is using public recursive DNS for a private name

### A rebuild succeeded but the app is broken

Separate the failure type first:

- config evaluation:
  `nix flake check --no-build`
- systemd/runtime:
  `systemctl --failed`
- routing:
  `curl -skI https://<hostname>/`
- identity:
  check Kanidm, group membership, and the app OIDC callback
- storage:
  `findmnt`, `snapraid status`

### Login loop on `files`

Start from:

```bash
curl -skI https://files.<domain>/
systemctl status oauth2-proxy caddy cloudflared-tunnel-metro
```

Check:

- callback hostname is still `files.<domain>`
- HTTPS redirect is intact
- OAuth2 Proxy can reach the Kanidm issuer

### ACME or public edge failure

Check:

```bash
systemctl status caddy cloudflared-tunnel-metro
journalctl -u caddy -u cloudflared-tunnel-metro -n 100 --no-pager
ls -l /run/agenix/cfAPIToken /run/agenix/cfHomeCreds
```

Likely causes:

- Cloudflare DNS token secret drift
- Cloudflare tunnel credentials drift
- tunnel ingress no longer matching the intended public hostnames
