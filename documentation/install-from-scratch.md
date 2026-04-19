# Install From Scratch

Use this when provisioning a blank machine from a NixOS installer ISO.

## 1) Boot installer and get network
- Boot a recent NixOS installer image.
- Ensure internet connectivity.

Wi-Fi example:
```bash
iwctl
# then in iwctl:
# device list
# station <wifi-iface> connect "<SSID>"
```

## 2) Clone repository in installer session
```bash
mkdir -p /mnt/src
git clone <your-fork-or-origin-url> /mnt/src
```

## 3) Set hardware/network values in `vars.nix`
At minimum set:
- `mainDisk`
- `dataDisks`
- `parityDisks`
- `backupDisk`
- `enableBackupDisk`
- `coldStorageDisk`
- `coldStorageMountPoint`
- `netIface`
- `serverLanIP`
- `serverLanGateway`
- `serverSSHPubKey`

`dataDisks` and `parityDisks` define the current protected-array topology. Keep docs and operator checks aligned to `vars.nix`; do not assume a fixed number of data or parity disks over the server lifetime.

`serverLanIP` and `serverLanGateway` define the static LAN address and default
route applied by NixOS. If the host is temporarily reachable on a different
address during migration, keep those values set to the final target and handle
the current reachable address as a local operator override only.

List stable disk IDs:
```bash
ls -l /dev/disk/by-id/
```

Use `/dev/disk/by-id/*` values, not transient `/dev/sdX` names.

Current storage intent:

- `backupDisk` is the active dedicated `/mnt/backup` target and should stay enabled
- `coldStorageDisk` is tracked for manual operator mounts only and must not be added to the protected array

If you want to change the default nightly suspend and morning wake behavior,
edit `modules/power-management/default.nix` after install and use the
vendor-neutral checklist in [Power Management](./power-management.md).

## 4) Optional: wipe target disks (destructive)
```bash
for d in /dev/disk/by-id/<disk-id-1> /dev/disk/by-id/<disk-id-2>; do
  wipefs -a "$d"
  sgdisk --zap-all "$d"
done
```

## 5) Apply Disko layout (destructive)
```bash
nix run github:nix-community/disko -- \
  --mode zap_create_mount /mnt/src/disko.nix
findmnt -R /mnt
```

## 6) Copy config into target root and generate hardware config
```bash
cp -r /mnt/src/* /mnt/etc/nixos
nixos-generate-config --root /mnt
```

Review `/mnt/etc/nixos/hardware-configuration.nix` and keep it aligned with Disko-managed filesystems.

## 7) Prepare secrets and age key
Follow [Secrets and Prerequisites](./secrets-and-prereqs.md), then copy the private key to target root:
```bash
install -d -m 0700 /mnt/etc/agenix
install -m 0400 /path/to/agenix.key /mnt/etc/agenix/age.key
```

## 8) Install and reboot
```bash
nixos-install --flake /mnt/etc/nixos#server
reboot
```

## 9) Post-install activation and verification
After first boot, continue with [Quickstart](./quickstart.md) step 5 and [Operations](./operations.md).
