# Operations

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
```

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

### SSH and auth policy
- Non-root admin SSH key login works.
- Root SSH login is rejected.
- Password and keyboard-interactive auth are rejected.

### Service health
```bash
systemctl status caddy kanidm oauth2-proxy cloudflared unbound paperless-web paperless-scheduler paperless-task-queue netbird-main
systemctl --failed
journalctl -b -u caddy -u kanidm -u oauth2-proxy -u cloudflared -u unbound -u paperless-web -u netbird-main
```

### Exposure checks
- Public: `https://id.<domain>`, `https://files.<domain>`
- Private/NetBird: `paperless`, `photos`, `audiobooks`, `books`, `video`, `jellyseerr`

### DNS, mesh, and secrets
```bash
systemctl status netbird-main
ip addr show nb0
ls -l /run/agenix
```

## Troubleshooting quick map
- Login loop on `files`: start from `https://files.<domain>` only, verify OAuth2 callback and HTTPS.
- Private app unreachable: verify NetBird connected and DNS distributed.
- OIDC sign-in fails: verify `id.<domain>` health and that the user is in the
  app-specific Kanidm access group.
- ACME failure: verify Cloudflare API token secret and tunnel/domain settings.

## Access model reminders
- `users` is baseline identity only; it does not grant app access.
- Use app-specific groups for login:
  - `immich-users`
  - `paperless-users`
  - `audiobookshelf-users`
  - `kavita-login`
  - `fileshare_users`
- Use app-specific admin groups for intended administrators:
  - `immich-admin`
  - `paperless-admin`
  - `audiobookshelf-admin`
  - `kavita-admin`
- `admindsaw` is the intended operator/admin identity.
- `dsaw` is the intended normal daily-use identity.
- Jellyfin and Jellyseerr remain local-auth exceptions.
