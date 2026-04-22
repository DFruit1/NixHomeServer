# Restore And Recovery

Use this when rebuilding the host, recreating the mirrored ZFS data pool, or manually mounting and unmounting cold-storage pools.

Recovery priorities:
- keep the system SSD isolated from data-pool recovery
- rebuild declaratively before doing destructive storage work
- treat manual cold-storage pools as separate from the default Disko path

## 1. Pre-Flight

Confirm the target disks from [`vars.nix`](/home/dsaw/Projects/NixOS/vars.nix):

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

Keep these rules:
- `mainDisk` is the system SSD only
- `vars.zfsDataPoolDiskIds` are the only disks in scope for mirrored data-pool recreation
- `vars.coldStoragePools` stay outside the default destructive Disko path

## 2. Rebuild-First Recovery

Before destructive storage work, stabilize the host with the validation, guarded deploy, and runtime readiness workflows in [Operations](./operations.md). Use Quickstart only if the target still needs bootstrap inputs or the agenix key installed.

## 3. Recreate Only The Mirrored Data Pool

If the `data` pool must be recreated while the SSD must remain untouched:

```bash
sudo zpool export data
./scripts/format-data-disks.sh
findmnt /
findmnt -R /mnt/data
sudo zpool status data
sudo zfs list -r data
```

Direct `nix run ... disko ...` commands are reserved for expert/manual
debugging only and are not the supported operator workflow.

For wrapper details and guardrails, use:

```bash
./scripts/format-data-disks.sh --help
```

Expected result:
- `/` remains `btrfs`
- `/mnt/data` and configured child datasets are `zfs`
- the SSD was not repartitioned
- manual cold-storage disks were not touched

## 4. Cold Storage

Cold-storage imports remain manual:

```bash
./scripts/cold-storage.sh status
./scripts/cold-storage.sh mount cold-v1jan8ph
./scripts/cold-storage.sh unmount cold-v1jan8ph
```

## 5. Notes

- Runtime readiness includes SMART degradation warnings; review those before resuming write workloads.
- Offsite backup policy is outside this repo’s base recovery workflow.
