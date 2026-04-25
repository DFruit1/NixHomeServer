# Restore And Recovery

Use this guide when rebuilding the host, recreating the single mirrored ZFS data pool, replacing a degraded member in that mirror, mounting or unmounting manual cold-storage pools, or restoring SSD-backed application state.

Recovery priorities:
- keep the system SSD isolated from data-pool recovery unless the scenario explicitly replaces the SSD
- rebuild declaratively before doing destructive storage work whenever the host can still boot
- treat optional manual cold-storage pools as separate from the default Disko path

## When To Use This Guide

Use this guide when any of these are true:
- the SSD died but the mirrored data pool is still intact
- the mirrored `data` pool must be recreated
- you need to replace one failed member in the active mirror
- a configured cold-storage pool needs to be mounted or unmounted manually
- you need to inspect or restore SSD-backed app state from the local Restic repository

If the problem is ordinary validation, deployment, or runtime triage, use [Operations](./operations.md) instead.

## Conventions

- Placeholders such as `<new-disk-a>`, `<new-disk-b>`, `<pool-name>`, and `/path/to/agenix.key` are examples. Replace them with the actual operator values before running commands.
- Group names such as `users`, `immich-users`, `paperless-users`, `fileshare_users`, and `*-admin` are literal names managed by this repo.
- Command blocks use the same context format:
  - Run from: where to execute the commands
  - Privileges: whether `sudo` is required
  - Environment: whether a plain shell or a specific `nix shell` is expected

## Shared Pre-Flight

Confirm the target disks from [`vars.nix`](../vars.nix) before any storage action.

- Run from: `workstation repo root`
- Privileges: `sudo not required`
- Environment: `plain shell`

```bash
ls -l /dev/disk/by-id
nix eval --json --impure --expr '
let flake = builtins.getFlake (toString ./.); vars = import ./vars.nix { lib = flake.inputs.nixpkgs.lib; };
in {
  mainDisk = vars.mainDisk;
  zfsDataPoolDiskIds = vars.zfsDataPoolDiskIds;
  coldStorageDiskIds = map (p: p.disk) vars.coldStoragePools;
}'
```

Expected result:
- `mainDisk` identifies only the system SSD
- `zfsDataPoolDiskIds` lists only the mirrored data-pool members
- `coldStorageDiskIds` lists only manual cold-storage disks

Stop conditions:
- any disk ID overlaps between the SSD, mirrored data pool, and cold-storage pools
- the physical disks on the host do not match the declarative disk IDs

## How The Mirrored Data Pool Works

The active `data` pool is a mirrored ZFS pool built from the single mirror pair declared in [`vars.nix`](../vars.nix) under `zfsDataPool.mirrorPairs`.

Key points:
- this repo assumes exactly one active mirrored vdev for `data`
- that mirror can usually survive one failed member, but not both members
- the pool stays available while one member is missing or failed, but the pool is then degraded and should be repaired promptly
- the pool is only as safe as the remaining healthy member, so do not treat a degraded mirror as a normal steady state

Operational implications:
- do not use the destructive `./scripts/format-data-disks.sh` workflow to replace a single failed disk
- after replacing a failed member, wait for resilvering to finish before treating the pool as healthy again
- whenever a mirror member changes permanently, update [`vars.nix`](../vars.nix) so monitoring, future wrapper previews, and recovery workflows match reality
- if you ever choose to move beyond a single mirrored vdev, treat that as a deliberate topology redesign and update the repo expectations first rather than assuming the current runbooks still apply unchanged

## ZFS Pool Do's And Don'ts

Do:
- use stable `/dev/disk/by-id/*` names, not transient `/dev/sdX` names
- verify `mainDisk`, the single active `zfsDataPool.mirrorPairs` entry, and `coldStoragePools` before any storage change
- run `sudo zpool status data` before and after every pool change
- update [`vars.nix`](../vars.nix) when a mirror member is permanently replaced with a new disk ID
- rerun [Runtime Validation](./operations.md#runtime-validation) after replacement or pool recreation
- keep replacements focused: one failed mirror member, one replacement disk, one resilver

Don't:
- do not run `./scripts/format-data-disks.sh` for a single-disk replacement
- do not remove or replace both members of the same mirror pair at once
- do not mix topology changes, recovery work, and unrelated deploy changes in one step
- do not assume a disk is healthy just because the pool is still mounted
- do not leave [`vars.nix`](../vars.nix) stale after replacing a failed disk with a different by-id value

## Scenario: SSD Died But Data Pool Is Intact

Goal:
- replace or rebuild the system SSD without touching the mirrored `data` pool

Do Not Touch:
- every disk in `zfsDataPool.mirrorPairs`
- every disk in `coldStoragePools`

Preconditions:
- you have confirmed the disk inventory in [`vars.nix`](../vars.nix)
- the mirrored `data` pool disks are still physically present
- the agenix private key is available for installation onto the rebuilt SSD

Command Context:
- Run from: `installer environment`
- Privileges: `sudo required if you are not already root`
- Environment: `plain shell`

Steps:
1. Clone the repo into the installer environment and preview only the system wrapper.

```bash
mkdir -p /mnt/src
git clone <your-fork-or-origin-url> /mnt/src
cd /mnt/src
./scripts/format-system-disk.sh --print-only
```

2. Recreate only the system SSD and verify the mounted layout.

```bash
./scripts/format-system-disk.sh
findmnt -R /mnt
```

3. Copy the repo into the target root, install the agenix key, and install the OS.

```bash
cp -r /mnt/src/* /mnt/etc/nixos
nixos-generate-config --root /mnt
install -d -m 0700 /mnt/etc/agenix
install -m 0400 /path/to/agenix.key /mnt/etc/agenix/age.key
nixos-install --flake /mnt/etc/nixos#server
reboot
```

4. After the rebuilt host boots, use [Guarded Deploy](./operations.md#guarded-deploy) and [Runtime Validation](./operations.md#runtime-validation) to confirm the rebuilt system and imported pool are healthy.

Expected Result:
- only `mainDisk` was repartitioned
- the mirrored `data` pool disks were not reformatted
- after boot, `/mnt/data` and its child datasets mount normally

Stop Conditions:
- the system-wrapper preview shows any mirrored data-pool or cold-storage disk
- `/mnt/data` does not reappear after the rebuilt host boots
- the data pool imports degraded or missing members that were expected to be online

Next Document If The Problem Is Elsewhere:
- use [Operations](./operations.md#service-failure-entry-points) for non-storage service failures

## Scenario: Recreate Only The Mirrored Data Pool

Goal:
- destroy and recreate only the single mirrored `data` pool while leaving the SSD untouched

Do Not Touch:
- `mainDisk`
- every disk in `coldStoragePools`

Preconditions:
- the host is stable enough that you have already finished the relevant [Validation Gate](./operations.md#validation-gate) and [Runtime Validation](./operations.md#runtime-validation) work outside this guide
- you have confirmed the exact mirrored data-pool disk IDs in [`vars.nix`](../vars.nix)
- you have accepted that all existing contents on the current pool member disks will be destroyed

Command Context:
- Run from: `workstation repo root`
- Privileges: `sudo required for ZFS export and the wrapper if you are not already root`
- Environment: `plain shell`

Steps:
1. Preview the exact destructive target set first.

```bash
./scripts/format-data-disks.sh --print-only
```

2. Export the pool if it is currently imported, then recreate only the mirrored data-pool disks.

```bash
sudo zpool export data
./scripts/format-data-disks.sh
findmnt /
findmnt -R /mnt/data
sudo zpool status data
sudo zfs list -r data
```

Direct `nix run ... disko ...` commands are reserved for expert or manual debugging only and are not the supported operator workflow.

3. Finish with [Runtime Validation](./operations.md#runtime-validation) after the pool is back.

Expected Result:
- `/` remains `btrfs`
- `/mnt/data` and configured child datasets are `zfs`
- the SSD was not repartitioned
- optional manual cold-storage disks were not touched

Stop Conditions:
- the wrapper preview includes `mainDisk`
- the wrapper preview includes any cold-storage disk
- `sudo zpool status data` does not return an `ONLINE` mirrored pool after recreation

Next Document If The Problem Is Elsewhere:
- use [Operations](./operations.md#service-failure-entry-points) for service failures after the pool mounts again

## Scenario: Replace A Degraded Disk In A Mirror Pool

Goal:
- replace one failed or missing member in the active mirror without recreating the whole pool

Do Not Touch:
- `mainDisk`
- the healthy member in the active mirror
- every disk in `coldStoragePools`

Preconditions:
- `sudo zpool status data` clearly shows a degraded pool and identifies the failed or missing member
- you know which active mirror member failed and which replacement disk will take its place
- the replacement disk is not already part of any pool and is not referenced by `mainDisk` or `coldStoragePools`
- you are prepared to update [`vars.nix`](../vars.nix) if the replacement disk has a new by-id value

Command Context:
- Run from: `target server shell`
- Privileges: `sudo required`
- Environment: `plain shell`

Steps:
1. Capture the current degraded state and identify the failed member path exactly as ZFS sees it.

```bash
sudo zpool status data
sudo zpool list -v
```

2. Confirm the replacement disk's stable by-id path and make sure it is not one of the currently declared SSD, cold-storage, or unrelated data-pool disks.

3. Partition only the replacement disk so it matches the layout declared in [`disko.nix`](../disko.nix): one GPT partition spanning the disk, with the future ZFS member on `-part1`.

4. If the replacement disk ID is new, update [`vars.nix`](../vars.nix) so the sole `zfsDataPool.mirrorPairs` entry uses the new disk ID, then run the normal [Validation Gate](./operations.md#validation-gate) and [Guarded Deploy](./operations.md#guarded-deploy) so monitoring and future destructive-wrapper previews match the actual hardware.

5. Replace only the failed member with the new `-part1` device.

```bash
sudo zpool replace data \
  /dev/disk/by-id/<failed-disk>-part1 \
  /dev/disk/by-id/<replacement-disk>-part1
```

6. Watch the resilver until the pool returns to `ONLINE`.

```bash
sudo zpool status data
sudo zpool status data
sudo zfs list -r data
sudo ./scripts/runtime-readiness.sh
```

Expected Result:
- only the failed mirror member is replaced
- the pool remains available during the replacement workflow
- `zpool status data` eventually reports the resilver as complete and the pool as `ONLINE`
- runtime readiness passes once the replacement has finished

Stop Conditions:
- you cannot confidently identify which mirror member is failed
- the candidate replacement disk appears anywhere in the current pool, `mainDisk`, or `coldStoragePools`
- you are about to use `./scripts/format-data-disks.sh` for a single-disk replacement
- the pool degrades further or another member begins failing during the replacement

Next Document If The Problem Is Elsewhere:
- use [Operations](./operations.md#service-failure-entry-points) if the storage replacement completes but service health is still bad

## Scenario: Mount Or Unmount A Cold-Storage Pool

Goal:
- operate only on a configured manual cold-storage pool

Do Not Touch:
- `mainDisk`
- the active mirrored `data` pool

Preconditions:
- the pool is declared in `coldStoragePools` in [`vars.nix`](../vars.nix)
- you know the exact pool name you intend to operate on

Command Context:
- Run from: `target server shell`
- Privileges: `sudo not required unless the helper reports otherwise`
- Environment: `plain shell`

Steps:
1. Inspect current cold-storage state.

```bash
./scripts/cold-storage.sh status
```

2. Mount the pool when you need it.

```bash
./scripts/cold-storage.sh mount <pool-name>
```

3. Unmount the pool when you are done.

```bash
./scripts/cold-storage.sh unmount <pool-name>
```

Expected Result:
- only the named cold-storage pool changes state
- the mirrored `data` pool remains untouched
- `status` reflects the mount or unmount operation you just performed

Stop Conditions:
- the helper reports a pool name that is not declared in `coldStoragePools`
- the command output suggests it is trying to operate on the active `data` pool

Next Document If The Problem Is Elsewhere:
- use [Operations](./operations.md#storage-monitoring) if the issue becomes a monitoring or general readiness problem

## Scenario: Restore SSD-Backed App State

Goal:
- inspect or restore SSD-backed state from the local Restic repository at `/persist/backups/restic/system-state`

Do Not Touch:
- the mirrored `data` pool payloads under `/mnt/data`
- manual cold-storage pool contents

Preconditions:
- the local repository exists on the SSD
- you know whether you only need an inspection restore into a scratch directory or a manual targeted file restore afterward

Command Context:
- Run from: `target server shell`
- Privileges: `sudo required`
- Environment: `plain shell`

Steps:
1. Inspect backup status and available snapshots.

```bash
systemctl status restic-backups-system-state.timer
sudo systemctl start restic-backups-system-state.service
sudo restic-system-state snapshots
```

2. Restore the latest snapshot into a scratch directory for inspection.

```bash
sudo restic-system-state restore latest --target /tmp/system-state-restore
```

3. Use the restored metadata and files to decide what must be copied back before returning to [Guarded Deploy](./operations.md#guarded-deploy) and [Runtime Validation](./operations.md#runtime-validation).

Expected Result:
- the snapshot list is readable
- the restore command recreates the backed-up tree under `/tmp/system-state-restore`
- metadata about the pool layout and critical managed paths is available for inspection

Stop Conditions:
- the snapshot list is empty when you expected local backups
- the restore output is missing critical paths such as `/etc/agenix`, `/etc/ssh`, or `/persist/appdata`
- you are about to overwrite live files without first confirming the restored contents

Next Document If The Problem Is Elsewhere:
- use [Operations](./operations.md#shared-troubleshooting-matrix) if the host issue is broader than SSD-backed app state
