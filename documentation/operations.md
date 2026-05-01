# Operations

Use this as the single day-2 runbook for validation, guarded deploys, rollback, runtime readiness, DNS expectations, power checks, storage monitoring, and first-response troubleshooting.

Use the other guides this way:
- [Quickstart](./quickstart.md) owns workstation setup, secrets staging, agenix key installation, and the supported destructive disk wrappers.
- [Kanidm Guide](./kanidm.md) owns operator identity workflows and app access grants.
- [Restore And Recovery](./restore-and-recovery.md) owns single-mirror data-pool recreation, degraded-disk replacement, and cold-storage mount or unmount operations.

## When To Use This Guide

Use Operations when any of these are true:
- the host already exists and you need the canonical validation gate
- you need the guarded deploy workflow for a config change
- a deploy completed but the new generation is bad and you need rollback steps
- runtime readiness, DNS behavior, or service status needs to be checked
- storage monitoring, power-management timers, or failed units need a quick audit

## Conventions

- Placeholders such as `<domain>`, `TARGET_SERVER_IP`, and `CURRENT_SERVER_IP` are examples. Replace them with your operator values before running commands.
- Group names such as `users`, `user-files`, `shared-files-ro`, `shared-files-rw`, `immich-users`, `paperless-users`, and `*-admin` are literal names managed by this repo.
- Command blocks use the same context format:
  - Run from: where to execute the commands
  - Privileges: whether `sudo` is required
  - Environment: whether a plain shell or a specific `nix shell` is expected

## Shared Troubleshooting Matrix

| Symptom | First commands | Next document or section |
| --- | --- | --- |
| Public endpoint down | `systemctl status caddy cloudflared-tunnel-metro` and `journalctl -u caddy -u cloudflared-tunnel-metro -n 100 --no-pager` | Stay in [Service Failure Entry Points](#service-failure-entry-points). |
| Private hostname resolves incorrectly | `systemctl status unbound netbird-main`, `host ytdownload.<domain> 127.0.0.1`, and `resolvectl query ytdownload.<domain>` | Stay in [Access And DNS Model](#access-and-dns-model) and [Service Failure Entry Points](#service-failure-entry-points). |
| User reaches sign-in but app still denies access | Confirm the app and user in [Kanidm Guide](./kanidm.md#troubleshooting-flow). | Continue in [Kanidm Guide](./kanidm.md#troubleshooting-flow). |
| Deploy succeeded but the new generation is bad | Start with the rollback path that matches your current access: SSH, bootloader, or local console. | Use [Rollback After A Bad Generation](#rollback-after-a-bad-generation). |
| `/mnt/data` is missing or datasets do not mount | `findmnt -R /mnt`, `sudo zpool status data`, and `sudo zfs list -r data` | Continue in [Restore And Recovery](./restore-and-recovery.md). |
| `zpool status data` shows `DEGRADED` or a failed member | Confirm which member failed, avoid any topology changes, and start the degraded-disk replacement workflow. | Continue in [Restore And Recovery](./restore-and-recovery.md#scenario-replace-a-degraded-disk-in-a-mirror-pool). |
| Cold-storage pool does not appear | Confirm the configured pool names and current import state. | Continue in [Restore And Recovery](./restore-and-recovery.md#scenario-mount-or-unmount-a-cold-storage-pool). |
| Power or overnight availability looks wrong | `./scripts/power-audit.sh` and `systemctl list-timers power-management-nightly-suspend.timer fstrim.timer zfs-scrub-data.timer` | Stay in [Power Management](#power-management). |

## Common Commands

- Validation gate: `nix flake check --no-build` then `scripts/check-repo.sh --run-flake-check`
- Exhaustive local gate: `scripts/check-repo.sh --full`
- Manual docs audit: `scripts/check-docs.sh`
- Guarded deploy: `./scripts/deploy-validated.sh`
- Runtime readiness: `sudo ./scripts/runtime-readiness.sh --profile manual`
- Strict runtime readiness: `sudo ./scripts/runtime-readiness.sh --profile deploy`
- Backup target selection: `backup-target list` then `sudo backup-target select ...`
- Power audit: `./scripts/power-audit.sh`
- Failed units: `systemctl --failed --no-pager`

## Files Access Model

Use these roles when checking files access incidents:
- `user-files`: personal Copyparty and SMB access only
- `shared-files-ro`: read-only access to `/shared/*`
- `shared-files-rw`: shared-write access through Samba only

Important behavior:
- `shared-files-ro` and `shared-files-rw` do not imply `user-files`
- Copyparty shared roots are read-only for both shared groups
- Samba is the authoritative shared-write surface
- `shared-files-rw` on Samba means upload new files, rename own files, and read peer files, but not peer overwrite or peer delete
- Samba cannot cleanly block an owner from removing their own shared entry once it exists; if that becomes unacceptable later, move to a moderated ingest workflow instead of direct shared writes

## Validation Gate

Run the flake check first.

- Run from: `workstation repo root`
- Privileges: `sudo not required`
- Environment: `plain shell`

```bash
nix flake check --no-build
```

Expected result:
- evaluation completes without option, flake, or type errors
- the host configuration and packages still evaluate cleanly before any deploy work

If it fails:
- stop before deploying anything
- fix the reported Nix evaluation error first
- rerun the command until it completes cleanly

Run the change-aware repo policy and test gate second.

- Run from: `workstation repo root`
- Privileges: `sudo not required`
- Environment: `plain shell`

```bash
scripts/check-repo.sh
```

Default `scripts/check-repo.sh` behavior:
- does not rerun `nix flake check --no-build` by default
- runs docs checks when docs are the only changed files, otherwise runs smoke suite plus targeted tests through `tests/run-changed.sh`
- builds Rust check derivations only when relevant paths changed
- does not run documentation churn checks; use `scripts/check-docs.sh` manually when you want the repo-audit pass

To include flake checks in the same pass as default mode:
```bash
scripts/check-repo.sh --run-flake-check
```

Use the exhaustive local gate when you want the full shell suite and all explicit Rust derivation checks regardless of the diff.

```bash
scripts/check-repo.sh --full
```

`scripts/check-repo.sh --full` runs `tests/run-all.sh`, including `tests/core-config-base.sh`, `tests/core-config-storage.sh`, and `tests/core-config-apps.sh`. Guarded deploys also use the exhaustive mode, but skip the duplicate flake check because the deploy helper already ran it first.

Expected result:
- the change-aware shell suite passes in default mode
- `--full` runs the exhaustive shell suite when requested
- targeted or exhaustive Rust derivation builds pass for the touched apps
- the script exits with `Repository checks passed.`

If it fails:
- stop before deploying anything
- fix the failing test, policy check, or build error
- rerun `scripts/check-repo.sh --full` before a deploy if you only iterated with the selective default path

## Guarded Deploy

Derive the intended target address from `vars.serverLanIP`, then keep any temporary reachable cutover address in `CURRENT_SERVER_IP` only.

- Run from: `workstation repo root`
- Privileges: `sudo may be requested on the target host`
- Environment: `plain shell`
- Build ownership: `the workstation stages and orchestrates; all Rust and Nix builds run on --build-host`

```bash
export TARGET_SERVER_IP="$(nix eval --raw --impure --expr 'let flake = builtins.getFlake (toString ./.); vars = import ./vars.nix { lib = flake.inputs.nixpkgs.lib; }; in vars.serverLanIP')"
export CURRENT_SERVER_IP="${CURRENT_SERVER_IP:-$TARGET_SERVER_IP}"

./scripts/deploy-validated.sh \
  --target "dsaw@$CURRENT_SERVER_IP" \
  --build-host "dsaw@$CURRENT_SERVER_IP" \
  --action test \
  --hostname server
```

Expected result:
- the helper reruns validation before the remote rebuild
- the helper uploads the current checkout and runs the exhaustive repo gate on `--build-host`
- remote `nixos-rebuild test` completes
- the helper checks failed units and runs remote runtime readiness successfully in strict `--profile deploy` mode
- any transition notice is advisory only and still ends with a clean validation result

If it fails:
- do not proceed to `--action switch`
- fix the reported validation, SSH, rebuild, unit, or runtime-readiness failure first
- if it reports `Insufficient free space on build host`, free space on the filesystem backing the remote `sandbox-build-dir` and on remote `/tmp` before retrying
- if the issue is storage- or recovery-related, move to [Restore And Recovery](./restore-and-recovery.md)

Only switch after the guarded test path passes.

- Run from: `workstation repo root`
- Privileges: `sudo may be requested on the target host`
- Environment: `plain shell`
- Build ownership: `the workstation stages and orchestrates; all Rust and Nix builds run on --build-host`

```bash
./scripts/deploy-validated.sh \
  --target "dsaw@$CURRENT_SERVER_IP" \
  --build-host "dsaw@$CURRENT_SERVER_IP" \
  --action switch \
  --hostname server
```

Expected result:
- the switch completes on the target host
- the new generation becomes active without introducing failed units
- follow-up readiness checks remain clean on the switched generation

If it fails:
- stop and use [Rollback After A Bad Generation](#rollback-after-a-bad-generation) if the new generation is already active and bad
- otherwise fix the reported rebuild or connectivity problem and rerun the guarded test path first

Use `./scripts/deploy-validated.sh --help` for argument details.

## Backup Target Selection

The `system-state` Restic job writes to `/mnt/backup-system-state/restic/system-state`, but the backing USB partition is selected at runtime instead of being hardcoded in `vars.nix` or `disko`.

- Run from: `target server shell`
- Privileges: `sudo required for select, mount, unmount, and clear`
- Environment: `plain shell`

Inspect the currently eligible USB backup partitions first.

```bash
backup-target list
backup-target status
```

Select the partition you want the next backup runs to use.

```bash
sudo backup-target select /dev/disk/by-id/<usb-backup>-part1
backup-target status
```

Normal manual verification flow:

```bash
sudo backup-target mount
sudo systemctl start restic-backups-system-state.service
sudo backup-target unmount
```

Expected result:
- `list` shows only eligible external USB partitions with stable `by-id` names
- `select` persists the chosen partition under `/persist/appdata/.nixos-managed/system-state-backup-target/selected-device`
- the backup service mounts the selected USB partition at start and auto-unmounts it after the run

If it fails:
- if `select` reports ambiguity, choose the exact `/dev/disk/by-id/...-partN` path instead of `LABEL=...`
- if `mount` or the backup service reports the device is missing, attach the selected USB disk again or choose a different one
- if the selected filesystem is unsupported, reselect an `exfat`, `ext4`, or `btrfs` partition

## Rollback After A Bad Generation

Use the rollback path that matches your current access.

### SSH Still Works

- Run from: `target server shell`
- Privileges: `sudo required`
- Environment: `plain shell`

```bash
sudo nixos-rebuild switch --rollback
sudo systemctl --failed --no-pager
sudo ./scripts/runtime-readiness.sh
```

Expected result:
- the system switches back to the previous generation
- failed units return to the pre-change baseline
- runtime readiness passes again on the rolled-back generation

If it fails:
- move to a local console and use the local rollback path below
- if the host cannot keep the network up long enough for SSH, use the bootloader rollback path

### You Can Still Reach The Bootloader

At the next reboot, select the previous known-good generation from the NixOS boot menu.

Expected result:
- the system boots into the older generation
- remote access and expected services return

If it fails:
- use a local console for the next recovery step
- if the issue is storage-related after rollback, continue in [Restore And Recovery](./restore-and-recovery.md)

### Only A Local Console Is Available

- Run from: `local console`
- Privileges: `sudo required`
- Environment: `plain shell`

```bash
sudo nix-env -p /nix/var/nix/profiles/system --list-generations
sudo nixos-rebuild switch --rollback
sudo systemctl --failed --no-pager
sudo ./scripts/runtime-readiness.sh
```

Expected result:
- you can confirm the currently installed generations
- the local system switches back to the previous generation
- runtime readiness verifies that the rollback is actually healthy

If it fails:
- inspect the console errors before attempting another deploy
- if the rollback restores boot but `/mnt/data` is still missing, continue in [Restore And Recovery](./restore-and-recovery.md)

## Runtime Validation

Primary runtime validation:

- Run from: `target server shell`
- Privileges: `sudo required`
- Environment: `plain shell`

```bash
sudo ./scripts/runtime-readiness.sh
```

The readiness check validates:
- core service units
- public and private HTTPS entrypoints
- server-local Unbound answers
- ZFS mounts derived from `vars.zfsDataPool.datasets`
- SMART health for `vars.monitoredStorageDiskIds`
- required app-state roots and critical payload paths derived from the evaluated host config
- backup timer state and the recency of the system-state backup metadata

Useful profiles:

```bash
sudo ./scripts/runtime-readiness.sh --profile manual
sudo ./scripts/runtime-readiness.sh --profile deploy
sudo ./scripts/runtime-readiness.sh --profile manual --deep
```

Expected result:
- all required units report active
- HTTP checks return one of the expected status codes
- DNS answers match the configured public or split-horizon model
- the ZFS pool and expected datasets are mounted
- `DEGRADED` mirrored-pool health still passes in the default manual mode when the datasets are mounted and accessible
- SMART checks do not report hard failures
- stale backups only hard-fail when the selected removable target is actually attached
- `--deep` adds sqlite integrity probes plus PostgreSQL connectivity and dump-artifact checks

If it fails:
- use [Service Failure Entry Points](#service-failure-entry-points) for service and DNS issues
- use [Kanidm Guide](./kanidm.md#troubleshooting-flow) if the failure is app access after successful sign-in
- use [Restore And Recovery](./restore-and-recovery.md) if the failure is mount- or storage-related

Operational note:
- manual `sudo ./scripts/runtime-readiness.sh` reflects runtime survivability and allows a mirrored pool to remain `DEGRADED` while still serving data
- guarded deploys stay stricter and run `runtime-readiness.sh --profile deploy`, so deploy promotion remains blocked until mirror redundancy is restored

## Storage Layout Audit

Use this when you need to confirm the current on-disk layout matches the intended steady-state model before or after impermanence preparation.

- Run from: `target server shell`
- Privileges: `sudo recommended`
- Environment: `plain shell`

```bash
sudo ./scripts/audit-storage-layout.sh
```

The audit reports:
- active payload roots that should remain in steady state
- retired legacy roots that should be absent or empty
- active SSD-backed app-state roots

Expected result:
- `paperless`, `immich`, `users`, `shared`, and `kiwix` report as the active steady-state roots
- retired roots such as `/mnt/data/appdata`, `/mnt/data/media`, `/mnt/data/shared/documents`, and `/mnt/data/shared/photos` are absent or empty
- the script exits successfully

If it fails:
- stop before enabling impermanence persistence or root rollback
- remove only the retired roots that the audit confirms are empty
- do not remove `paperless`, `immich`, `kiwix`, or anything under `users` or `shared`
- rerun the audit and [Runtime Validation](#runtime-validation) after any cleanup

Additional read-only audits:

- Run from: `target server shell`
- Privileges: `sudo not required`
- Environment: `plain shell`

```bash
./scripts/power-audit.sh
systemctl --failed --no-pager
```

Expected result:
- `./scripts/power-audit.sh` reports the configured power policy and any follow-up concerns
- `systemctl --failed --no-pager` is empty or only shows already-understood failures

## Access And DNS Model

Public endpoints:
- `https://id.<domain>`
- `https://files.<domain>`

Private endpoints:
- `https://emails.<domain>`
- `https://wiki.<domain>`
- `https://ytdownload.<domain>`
- `https://paperless.<domain>`
- `https://photos.<domain>`
- `https://audiobooks.<domain>`
- `https://books.<domain>`
- `https://videos.<domain>`

Expected behavior:
- On the home LAN in `split-horizon` mode, the private app hostnames plus `id.<domain>` and `files.<domain>` resolve to `vars.serverLanIP` through router forwarding.
- Over NetBird, private app hostnames should resolve to `vars.nbIP`.
- `id.<domain>` and `files.<domain>` should stay on the normal public path.
- Off the home LAN, the private apps require NetBird.
- Upstream recursive DNS stays encrypted-only. If `dnscrypt-proxy` is down or cannot bootstrap, recursive DNS should fail closed instead of silently downgrading to plaintext.

Recommended LAN DNS model:
- DHCP advertises only the router as DNS.
- The router forwards only the private app hostnames to the server.
- Do not forward the whole public zone to the server.

Offsite NetBird requirements:
- Configure a NetBird nameserver group in the NetBird admin plane that points private app match domains at `100.72.113.237:53`.
- Match only the private app hostnames. Do not include the zone apex, `id.<domain>`, or `files.<domain>`.
- Keep NetBird DNS management enabled for the peer groups that need private app access.
- Linux peers need `systemd-resolved` for NetBird match-domain split DNS. macOS, Windows, iOS, and Android can use NetBird-managed DNS directly.

## Power Management

Current policy is declarative and owned by [`modules/power-management/default.nix`](../modules/power-management/default.nix).

Operational expectations:
- nightly suspend makes SSH and app endpoints intentionally unavailable during the sleep window
- RTC wake and Wake-on-LAN are part of the expected policy
- `fstrim` and ZFS scrub should stay outside the sleep window

- Run from: `target server shell`
- Privileges: `sudo not required`
- Environment: `plain shell`

```bash
./scripts/power-audit.sh
systemctl list-timers power-management-nightly-suspend.timer fstrim.timer zfs-scrub-data.timer
```

## Storage Monitoring

Background storage monitoring complements runtime readiness.

What runs automatically:
- `smartd` on the active pool disks and configured cold-storage disks
- `storage-smart-short@*.timer`
- `storage-smart-long@*.timer`
- `storage-health-report.timer`
- `runtime-health-report.timer`

- Run from: `target server shell`
- Privileges: `sudo required for on-demand report generation and report reads`
- Environment: `plain shell`

```bash
systemctl list-timers 'storage-*'
systemctl status storage-health-report.timer
systemctl status runtime-health-report.timer
sudo systemctl start storage-health-report.service
sudo systemctl start runtime-health-report.service
sudo cat /var/lib/storage-monitoring/latest.txt
sudo jq . /var/lib/storage-monitoring/latest.json
sudo cat /var/lib/runtime-monitoring/latest.txt
sudo jq . /var/lib/runtime-monitoring/latest.json
```

Expected result:
- the timers appear active
- the latest report exists and reflects the current pool and monitored disks
- `latest.json` reports `.zfs.healthState` as the raw pool state and `.zfs.runtimeState` as `operational`, `degraded`, or `failed`
- a `DEGRADED` mirrored pool remains an operationally critical alert, even when runtime is still available
- the runtime monitor report reflects unit, HTTP, DNS, mount, SMART, ZFS, and backup-recency state in one machine-readable snapshot

If it fails:
- inspect the service status and latest report output
- continue in [Restore And Recovery](./restore-and-recovery.md) if the problem is a missing pool or missing mount

Cold-storage pool import, mount, and unmount workflows live in [Restore And Recovery](./restore-and-recovery.md).

## Service Failure Entry Points

Public endpoint failure:

- Run from: `target server shell`
- Privileges: `sudo not required`
- Environment: `plain shell`

```bash
systemctl status caddy cloudflared-tunnel-metro
journalctl -u caddy -u cloudflared-tunnel-metro -n 100 --no-pager
```

Private hostname resolves wrongly:

- Run from: `target server shell`
- Privileges: `sudo not required`
- Environment: `plain shell`

```bash
systemctl status unbound netbird-main
host paperless.<domain> 127.0.0.1
host photos.<domain> 127.0.0.1
host emails.<domain> 127.0.0.1
resolvectl query paperless.<domain>
```

Storage or mount failure:

- Run from: `target server shell`
- Privileges: `sudo required for ZFS and readiness checks`
- Environment: `plain shell`

```bash
findmnt -R /mnt
sudo zpool status data
sudo zfs list -r data
sudo ./scripts/runtime-readiness.sh
```

If `/mnt/data` or a configured dataset is missing, move to [Restore And Recovery](./restore-and-recovery.md).

If `sudo zpool status data` shows `DEGRADED` but the datasets are still mounted:
- treat that as runtime-survivable but operationally critical
- use `sudo ./scripts/runtime-readiness.sh` to confirm the host is still serving from the surviving mirror member
- keep guarded deploys blocked until the failed member is replaced and the pool returns to `ONLINE`

Mail archive service checks:

- Run from: `target server shell`
- Privileges: `sudo required for the manual sync trigger`
- Environment: `plain shell`

```bash
systemctl status mail-archive-ui mail-archive-oauth2-proxy mail-archive-sync.timer
sudo systemctl start mail-archive-sync.service
curl -fsS http://127.0.0.1:9011/healthz | jq .
```

Mailbox repair notes:
- Use the UI `Reindex` action when downloaded mail is present but search looks stale.
- Use `Sync now` when the mailbox needs a fresh IMAP pull before reindexing.
- Enable `Send attachments to Paperless for filing` per mailbox when qualifying attachments should flow into Paperless.
- The first run after enabling Paperless filing backfills the existing downloaded mailbox once; later runs only process newly reviewed mail.
- Downloaded mail payload lives under `/mnt/data/users/<user>/emails/accounts/<account-id>/maildir`, while per-account derived sync and index state lives under `/persist/appdata/mail-archive-ui/accounts/<user>/<account-id>`.
