# Operations

This is the short active runbook for deploys, rollback, smoke tests, and common failure entrypoints.

## Validate before deploy
Run from the repo root:

```bash
nix flake check --no-build
scripts/check-repo.sh
```

Direct repo-local validation entrypoints:

```bash
tests/run-all.sh
tests/core-config.sh
```

Read-only runtime audits:

```bash
./scripts/runtime-readiness.sh
./scripts/power-audit.sh
```

## Deploy

### Remote guarded deploy
Use the deploy wrapper as the only documented remote deploy path:

```bash
export SERVER_IP="$(nix eval --raw --impure --expr 'let flake = builtins.getFlake (toString ./.); vars = import ./vars.nix { lib = flake.inputs.nixpkgs.lib; }; in vars.serverLanIP')"

./scripts/deploy-validated.sh \
  --target "dsaw@$SERVER_IP" \
  --build-host "dsaw@$SERVER_IP" \
  --action test \
  --hostname server
```

Switch only after the guarded test path passes:

```bash
./scripts/deploy-validated.sh \
  --target "dsaw@$SERVER_IP" \
  --build-host "dsaw@$SERVER_IP" \
  --action switch \
  --hostname server
```

### Local-console deploy
Use this during high-risk changes such as the router cutover:

```bash
ssh dsaw@<server-lan-ip>
# then on the server:
# sudo -i
# cd /etc/nixos
# nix flake check --no-build
# scripts/check-repo.sh
# nixos-rebuild test --flake .#server --no-reexec
# systemctl --failed
# nixos-rebuild switch --flake .#server --no-reexec
```

## Rollback

### Immediate rollback
From the server console:

```bash
sudo nixos-rebuild switch --rollback
systemctl --failed --no-pager
```

### Router cutover rollback
If the DHCP lease, route, or resolver path is wrong after the gateway cutover:

```bash
ip -4 addr show dev enp34s0
ip route
networkctl status enp34s0
sudo nixos-rebuild switch --rollback
```

Expected cutover state:

- the interface gets the reserved DHCP lease `192.168.8.12`
- the default route comes from the router
- the server still uses `127.0.0.1` as its own resolver

## Smoke tests
Run these after a successful test or switch:

```bash
systemctl --failed --no-pager
sudo ./scripts/runtime-readiness.sh
sudo ./scripts/power-audit.sh
```

Check the main entrypoints:

- public: `https://id.<domain>`, `https://files.<domain>`
- private over NetBird: `emails`, `paperless`, `photos`, `audiobooks`, `books`, `videos`, `jellyseerr`

If you need the short manual acceptance checklist, use [Runtime Validation](./runtime-validation.md).

## Networking failure entrypoints

### Public endpoint fails
Check:

```bash
systemctl status caddy cloudflared-tunnel-metro
journalctl -u caddy -u cloudflared-tunnel-metro -n 100 --no-pager
```

Likely causes:

- Cloudflared tunnel unit down
- Caddy upstream mismatch
- Cloudflare ingress or DNS drift

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
- Unbound not serving the expected records
- client bypassing NetBird DNS and using public recursion instead
- split-horizon enabled but the router is not advertising the server as primary LAN DNS

### LAN cutover route is wrong
Check:

```bash
ip -4 addr show dev enp34s0
ip route
networkctl status enp34s0
```

Expected:

- DHCP lease `192.168.8.12`
- default route learned from the router
- no statically pinned gateway in the NixOS config

## Storage failure entrypoints

```bash
findmnt /mnt/data
findmnt /mnt/parity
systemctl status snapraid-sync.timer snapraid-scrub.timer
sudo snapraid status
sudo snapraid diff
```

If storage is unhealthy, stop write-path testing until `/mnt/data` and `/mnt/parity` look correct again.

## Mail archive operations
Useful commands:

```bash
systemctl status mail-archive-ui mail-archive-oauth2-proxy
systemctl status mail-archive-sync.timer
sudo systemctl start mail-archive-sync.service
curl -fsS http://127.0.0.1:9011/healthz
```

User-facing access still depends on `mail-archive-users`.

## Backup and restore
Backup scope and restore sequencing live in [Restore and Recovery](./restore-and-recovery.md).

The backup policy remains intentionally narrow:

- `/var/lib/kanidm`
- `/var/lib/acme`
- `/var/lib/snapraid`
- `/etc/ssh`
- `/mnt/data/appdata`
