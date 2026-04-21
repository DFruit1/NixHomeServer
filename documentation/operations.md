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

Storage validation is config-driven. Follow the current ZFS pool and manual cold-storage topology from `vars.nix`, not old assumptions about fixed disk roles.

## Deploy

### Remote guarded deploy
Use the deploy wrapper as the only documented remote deploy path:

```bash
export TARGET_SERVER_IP="$(nix eval --raw --impure --expr 'let flake = builtins.getFlake (toString ./.); vars = import ./vars.nix { lib = flake.inputs.nixpkgs.lib; }; in vars.serverLanIP')"
export CURRENT_SERVER_IP="${CURRENT_SERVER_IP:-$TARGET_SERVER_IP}"

./scripts/deploy-validated.sh \
  --target "dsaw@$CURRENT_SERVER_IP" \
  --build-host "dsaw@$CURRENT_SERVER_IP" \
  --action test \
  --hostname server
```

`vars.serverLanIP` remains the intended primary LAN address. During a
migration window, set `CURRENT_SERVER_IP` locally if the host is still
reachable on a temporary address. Do not commit that temporary IP into active
repo files.

Switch only after the guarded test path passes:

```bash
./scripts/deploy-validated.sh \
  --target "dsaw@$CURRENT_SERVER_IP" \
  --build-host "dsaw@$CURRENT_SERVER_IP" \
  --action switch \
  --hostname server
```

### Local-console deploy
Use this during high-risk changes such as the LAN cutover:

```bash
ssh dsaw@$CURRENT_SERVER_IP
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

### LAN cutover rollback
If the static address, route, or resolver path is wrong after the cutover:

```bash
ip -4 addr show dev enp34s0
ip route
networkctl status enp34s0
sudo nixos-rebuild switch --rollback
```

Expected post-cutover state:

- the interface keeps the static address `192.168.8.12`
- the default route points at `192.168.8.1`
- the server still uses `127.0.0.1` as its own resolver

### Transition deploy notes
Before the cutover completes:

- use `CURRENT_SERVER_IP` for SSH, SCP, and guarded deploy commands
- keep `TARGET_SERVER_IP` derived from `vars.serverLanIP`
- prefer the local-console deploy path while the router, switch, or subnet is
  actively changing

After the cutover completes, stop using the temporary local override and
confirm the host is reachable on `dsaw@192.168.8.12`.

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
- Copyparty upstream: `curl -I http://127.0.0.1:3923/`

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
- client bypassing the router and using public recursion on the LAN
- split-horizon enabled but the router is not forwarding the private app hostnames to the server
- the router is forwarding the whole `sydneybasiniot.org` zone and you are seeing fallback behavior you did not intend

### LAN cutover route is wrong
Check:

```bash
ip -4 addr show dev enp34s0
ip route
networkctl status enp34s0
```

Expected:

- static address `192.168.8.12`
- default route `192.168.8.1`
- `127.0.0.1` remains the server resolver

## Storage failure entrypoints

```bash
findmnt -R /mnt
./scripts/cold-storage.sh status
sudo ./scripts/runtime-readiness.sh
sudo zpool status data
sudo zfs list -r data
```

Check `/mnt/data` and each configured ZFS child dataset mount against `vars.nix`. `scripts/cold-storage.sh status` should report the configured cold-storage pool without auto-importing it. The runtime readiness report also includes SMART degradation warnings for the active pool disks and the manual cold-storage disk.

If storage is unhealthy, stop write-path testing until the config-driven mount set looks correct again and runtime readiness reports no critical SMART conditions on active array disks.

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
Recovery sequencing now lives in [Restore and Recovery](./restore-and-recovery.md).

The repo no longer ships a local backup target. Treat offsite backups and any manual local copies as separate operator workflows.
