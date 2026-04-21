# Restore and Recovery

Use this when you need to rebuild the host or recover the mirrored ZFS data pool without touching the Btrfs system SSD by accident.

## Recovery model

This repo now assumes:

- the system disk is a Btrfs SSD managed by `disko-system.nix`
- the active data array is the mirrored ZFS pool defined in `vars.zfsDataPool`
- manual cold-storage pools remain outside the default destructive Disko path
- offsite backups and any manual local copies are separate operator workflows

## Before recovery work

1. Confirm disk identities from `vars.nix` before running any destructive command.
2. Keep `mainDisk` reserved for the existing Btrfs SSD only.
3. Confirm `vars.zfsDataPoolDiskIds` matches exactly the mirrored data disks you intend to create or recreate.
4. Confirm `vars.coldStoragePools` remains outside `disko.nix`.

Recommended verification:

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

## Rebuild-first recovery flow

1. Put the repo on the target machine and install the agenix private key at `/etc/agenix/age.key`.
2. Validate the repo:

```bash
nix flake check --no-build
scripts/check-repo.sh
```

3. Rebuild the host:

```bash
sudo nixos-rebuild test --flake .#server
sudo nixos-rebuild switch --flake .#server
```

4. Run the runtime validation pass:

```bash
sudo ./scripts/runtime-readiness.sh
```

Then work through [Runtime Validation](./runtime-validation.md) if the rebuild touched auth, routing, or application state.

## Recreating only the mirrored data pool

If the `data` pool must be recreated and the SSD must remain untouched:

1. Stop write-path activity and export the existing pool if it is imported:

```bash
sudo zpool export data
```

2. Run only the mirror-only Disko entrypoint:

```bash
sudo nix run github:nix-community/disko -- --mode zap_create_mount ./disko.nix
```

3. Do not use `disko-install.nix` or `disko-system.nix` for this case.

4. Verify the result:

```bash
findmnt /
findmnt -R /mnt/data
sudo zpool status data
sudo zfs list -r data
```

Expected result:

- `/` remains `btrfs`
- `/mnt/data` and its child datasets are `zfs`
- the SSD was not repartitioned
- the cold-storage disk was not touched

## Notes

- `scripts/cold-storage.sh` remains the manual-only path for cold-storage imports and mounts.
- Runtime readiness includes SMART degradation warnings, so review those before resuming normal write workloads.
- If you adopt offsite backups later, document that separately from this repo’s base recovery flow.
