# Restore And Recovery

Use this when rebuilding the host or recovering the mirrored ZFS data pool.

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

Install the agenix key on the target machine, then run:

```bash
nix flake check --no-build
scripts/check-repo.sh
sudo nixos-rebuild test --flake .#server
sudo nixos-rebuild switch --flake .#server
sudo ./scripts/runtime-readiness.sh
```

If the rebuild touched auth, routing, or application behavior, continue with
[Operations](./operations.md).

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
