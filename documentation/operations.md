# Operations

Use this as the single day-2 runbook for deploys, runtime validation, DNS and
access expectations, power checks, storage monitoring, and troubleshooting.

Use the other guides this way:
- [Quickstart](./quickstart.md) owns workstation setup, secrets staging, agenix key installation, and the supported destructive disk wrappers.
- [Kanidm Guide](./kanidm.md) owns operator identity workflows and app access grants.
- [Restore and Recovery](./restore-and-recovery.md) owns mirrored data-pool recreation and cold-storage mount or unmount operations.

## 1. Common Commands

- Validation gate: `nix flake check --no-build` then `scripts/check-repo.sh`
- Guarded deploy: `./scripts/deploy-validated.sh`
- Runtime readiness: `sudo ./scripts/runtime-readiness.sh`
- Power audit: `./scripts/power-audit.sh`
- Failed units: `systemctl --failed --no-pager`

## 2. Validation Gate

Run from the repo root before deploys and after meaningful config changes:

```bash
nix flake check --no-build
scripts/check-repo.sh
```

`scripts/check-repo.sh` already runs `tests/run-all.sh`, including `tests/core-config.sh`.
It also builds and runs the packaged `mail-archive-ui` test derivation so Rust app
regressions cannot slip past the repo gate.

## 3. Guarded Deploy

Derive the intended target address from `vars.serverLanIP`, then keep any
temporary reachable cutover address in `CURRENT_SERVER_IP` only:

```bash
export TARGET_SERVER_IP="$(nix eval --raw --impure --expr 'let flake = builtins.getFlake (toString ./.); vars = import ./vars.nix { lib = flake.inputs.nixpkgs.lib; }; in vars.serverLanIP')"
export CURRENT_SERVER_IP="${CURRENT_SERVER_IP:-$TARGET_SERVER_IP}"

./scripts/deploy-validated.sh \
  --target "dsaw@$CURRENT_SERVER_IP" \
  --build-host "dsaw@$CURRENT_SERVER_IP" \
  --action test \
  --hostname server
```

Switch only after the guarded test path passes:

```bash
./scripts/deploy-validated.sh \
  --target "dsaw@$CURRENT_SERVER_IP" \
  --build-host "dsaw@$CURRENT_SERVER_IP" \
  --action switch \
  --hostname server
```

Use `./scripts/deploy-validated.sh --help` for argument details.

## 4. Runtime Validation

Primary runtime validation:

```bash
sudo ./scripts/runtime-readiness.sh
```

The readiness check validates:
- core service units
- public and private HTTPS entrypoints
- server-local Unbound answers
- ZFS mounts derived from `vars.zfsDataPool.datasets`
- SMART health for `vars.monitoredStorageDiskIds`

Additional read-only audits:

```bash
./scripts/power-audit.sh
systemctl --failed --no-pager
```

## 5. Access And DNS Model

Public endpoints:
- `https://id.<domain>`
- `https://files.<domain>`

Private endpoints:
- `https://emails.<domain>`
- `https://paperless.<domain>`
- `https://photos.<domain>`
- `https://audiobooks.<domain>`
- `https://books.<domain>`
- `https://videos.<domain>`

Expected behavior:
- On the home LAN in `split-horizon` mode, only the private app hostnames should resolve to `vars.serverLanIP` through router forwarding.
- Over NetBird, private app hostnames should resolve to `vars.nbIP`.
- `id.<domain>` and `files.<domain>` should stay on the normal public path.
- Off the home LAN, the private apps require NetBird.

Recommended LAN DNS model:
- DHCP advertises only the router as DNS.
- The router forwards only the private app hostnames to the server.
- Do not forward the whole public zone to the server.

## 6. Power Management

Current policy is declarative and owned by
[`modules/power-management/default.nix`](/home/dsaw/Projects/NixOS/modules/power-management/default.nix).

Operational expectations:
- nightly suspend makes SSH and app endpoints intentionally unavailable during the sleep window
- RTC wake and Wake-on-LAN are part of the expected policy
- `fstrim` and ZFS scrub should stay outside the sleep window

Audit with:

```bash
./scripts/power-audit.sh
systemctl list-timers power-management-nightly-suspend.timer fstrim.timer zfs-scrub-data.timer
```

## 7. Storage Monitoring

Background storage monitoring complements runtime readiness.

What runs automatically:
- `smartd` on the active pool disks and configured cold-storage disks
- `storage-smart-short@*.timer`
- `storage-smart-long@*.timer`
- `storage-health-report.timer`

Useful commands:

```bash
systemctl list-timers 'storage-*'
systemctl status storage-health-report.timer
sudo systemctl start storage-health-report.service
sudo cat /var/lib/storage-monitoring/latest.txt
sudo jq . /var/lib/storage-monitoring/latest.json
```

Cold-storage pool import, mount, and unmount workflows live in [Restore and Recovery](./restore-and-recovery.md).

## 8. Failure Entry Points

Public endpoint failure:

```bash
systemctl status caddy cloudflared-tunnel-metro
journalctl -u caddy -u cloudflared-tunnel-metro -n 100 --no-pager
```

Private hostname resolves wrongly:

```bash
systemctl status unbound netbird-main
host paperless.<domain> 127.0.0.1
host photos.<domain> 127.0.0.1
host emails.<domain> 127.0.0.1
resolvectl query paperless.<domain>
```

Storage or mount failure:

```bash
findmnt -R /mnt
sudo zpool status data
sudo zfs list -r data
./scripts/cold-storage.sh status
sudo ./scripts/runtime-readiness.sh
```

Mail archive service checks:

```bash
systemctl status mail-archive-ui mail-archive-oauth2-proxy mail-archive-sync.timer
sudo systemctl start mail-archive-sync.service
curl -fsS http://127.0.0.1:9011/healthz | jq .
```

Mailbox repair notes:
- Use the UI `Reindex` action when downloaded mail is present but search looks stale.
- Use `Sync now` when the mailbox needs a fresh IMAP pull before reindexing.
