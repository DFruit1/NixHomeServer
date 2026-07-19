# Restore And Recovery

Use this guide for the maintained recovery boundary:
- replacing one failed member in the active mirrored `data` pool when using
  `storage.profile = "zfs-mirror"`
- checking and restoring a `storage.profile = "single-disk-ext4"` host
- inspecting or restoring SSD-backed application state from Kopia-managed backup repositories

Do not use `disko` for these workflows. Existing-server storage maintenance is
handled in place with the standard block-device and filesystem tools already
installed on the host.

Kopia is the maintained backup interface. The managed repository is a local
encrypted filesystem repository at `/mnt/data/backups/kopia`, and the
`kopia-persist-snapshot.timer` creates daily snapshots of `/persist` and
`/mnt/data/paperless` after `backup-prepare.service` publishes consistent dumps.

On `zfs-mirror`, `/mnt/data` is the mirrored ZFS data pool. On
`single-disk-ext4`, `/mnt/data` and `/persist` are regular directories on the
root ext4 filesystem, so local Kopia data is not a second-disk copy unless you
also sync it off host.

The previous automatic Restic `system-state` backup is retired and no Restic
timer or backup service is enabled by this module.

## Before Any Recovery

1. Do not guess device names. Record `lsblk -e7 -o NAME,SIZE,MODEL,SERIAL,WWN,FSTYPE,MOUNTPOINTS`,
   `findmnt`, `zpool status -P`, and `zpool status -g` before changing disks.
2. Verify the pool name and the exact failed member against `vars.nix`. A path
   containing `<...>` anywhere below is a placeholder, not a command to paste.
3. Confirm a recent local snapshot and, when enabled, the verified offsite
   marker:
   ```bash
   sudo jq . /mnt/data/backups/.kopia-last-snapshot-success.json
   sudo jq . /var/lib/rclone/last-mega-sync-success.json
   sudo kopia snapshot list --all
   ```
4. Stop the affected application before overwriting its state. Database
   restores must never run while the corresponding application is writing.
5. Restore into a new staging directory first. Validate hashes, ownership and
   database integrity there; preserve the live directory as a timestamped
   rollback copy until the application has passed its health check.

## Scenario: Replace A Degraded Disk In A Mirror Pool

Use this only for `storage.profile = "zfs-mirror"`.

First identify a healthy member from the same mirror and the new whole-disk
by-id path. The replacement must be at least as large as the failed device.
Replicate the partition table from the healthy disk, give the replacement new
GUIDs, and ask the kernel to reread it:

```bash
sudo zpool status -P data
ls -l /dev/disk/by-id/
sudo blockdev --getsize64 /dev/disk/by-id/<healthy-whole-disk>
sudo blockdev --getsize64 /dev/disk/by-id/<replacement-whole-disk>
sudo sgdisk --replicate=/dev/disk/by-id/<replacement-whole-disk> \
  /dev/disk/by-id/<healthy-whole-disk>
sudo sgdisk --randomize-guids /dev/disk/by-id/<replacement-whole-disk>
sudo partprobe /dev/disk/by-id/<replacement-whole-disk>
sudo udevadm settle
ls -l /dev/disk/by-id/<replacement-whole-disk>-part*
```

Re-run `lsblk` and verify the two exact partition paths before replacing
anything. Use the failed member exactly as ZFS reports it; use the replacement
data partition, not its whole-disk path:

```bash
sudo zpool replace data \
  /dev/disk/by-id/<failed-disk>-part1 \
  /dev/disk/by-id/<replacement-disk>-part1
sudo watch -n 10 zpool status -P data
```

Wait for `scan: resilvered ... with 0 errors` and an `ONLINE` or expected
`DEGRADED` pool before rebooting. Then run and complete a scrub:

```bash
sudo zpool scrub data
sudo watch -n 30 zpool status -P data
sudo zfs list -r data
findmnt /mnt/data /mnt/data/users /mnt/data/shared /mnt/data/backups
sudo systemctl --failed --no-pager
```

If the replacement disk has a new stable by-id value, update `vars.nix` before
the next blank-machine provisioning run. Do not run the repository's disk
layout tooling against this already-imported pool.

## Scenario: Check A Single-Disk Ext4 Host

Use this for `storage.profile = "single-disk-ext4"` after boot, power loss, or
storage warnings:

```bash
findmnt -no SOURCE,FSTYPE,OPTIONS /
df -hT / /mnt/data /persist
sudo smartctl -a /dev/disk/by-id/<system-disk-id>
sudo journalctl -u data-pool-layout.service -b --no-pager
sudo systemctl --failed --no-pager
```

Run offline filesystem repair only from a rescue or installer environment with
the root filesystem unmounted.

## Scenario: Recover The Local Kopia Repository From MEGA

Use `rclone copy`, never reverse `rclone sync`, for recovery. A mistaken reverse
sync can delete the only remote copy. Render or securely provide an Rclone
configuration, evaluate the configured destination from the deployed repository,
confirm that remote path with `rclone lsf`, and copy into an empty staging
directory owned by the `rclone` service account:

```bash
mega_destination="$(nix eval --raw \
  ".#lib.nixhomeserverSettings.<vars.hostname>.rcloneMega.destination")"
printf 'Recovering from: %s\n' "$mega_destination"
sudo systemctl start rclone-mega-config.service
sudo -u rclone rclone lsf --config /run/rclone/rclone.conf \
  --max-depth 2 "$mega_destination"
sudo install -d -o rclone -g rclone -m 0700 \
  /mnt/data/backups/kopia-recovered
sudo -u rclone test -w /mnt/data/backups/kopia-recovered
sudo -u rclone rclone copy --config /run/rclone/rclone.conf \
  --progress "$mega_destination" /mnt/data/backups/kopia-recovered
```

Connect Kopia to the recovered repository without overwriting the managed live
configuration. Use a temporary config and the existing `kopiaServerPassword`:

```bash
sudo install -d -m 0700 /run/kopia-recovery
sudo env KOPIA_PASSWORD="$(sudo cat /run/agenix/kopiaServerPassword)" \
  kopia repository connect filesystem \
  --path=/mnt/data/backups/kopia-recovered \
  --config-file=/run/kopia-recovery/repository.config \
  --cache-directory=/run/kopia-recovery/cache \
  --no-use-keyring
sudo env KOPIA_PASSWORD="$(sudo cat /run/agenix/kopiaServerPassword)" \
  KOPIA_CONFIG_PATH=/run/kopia-recovery/repository.config \
  kopia snapshot list --all
```

Restore a small known file into `/run/kopia-recovery/restore-test` before
declaring the remote usable. Keep the recovered repository separate until its
snapshot inventory and sample restore both succeed.

## Scenario: Restore SSD-Backed App State

Use the Kopia UI at the Kopia hostname to browse snapshots, but restore the
needed paths into a staging directory. If an operator copied the repository to
external media, connect Kopia to that copied repository explicitly rather than
overwriting the live repository first.

Useful restored dump files:

- `/persist/appdata/backup-metadata/current/dumps/immich.pgdump`: custom-format Immich PostgreSQL dump; inspect
  with `pg_restore --list` and restore with `pg_restore`.
- `/persist/appdata/backup-metadata/current/dumps/*.sqlite`: integrity-checked SQLite backups for configured
  applications.
- `/persist/appdata/backup-metadata/current/dumps/mail-archive-ui.sqlite3`: Mail Archive UI state, including
  attachment catalog and Paperless handoff records.

Useful restored metadata files:

- `/persist/appdata/backup-metadata/current/metadata/manifest.json`: dump-set timestamp, host, and schema.
- `/persist/appdata/backup-metadata/current/metadata/SHA256SUMS`: hashes for every prepared database dump.
- `/persist/appdata/backup-metadata/current/metadata/mail-archive-roots.tsv`: per-user mail archive root status
  and counts without message or attachment names.

Before publishing restored dumps, verify the generation:

```bash
cd /persist/appdata/backup-metadata/current
sudo sha256sum --check metadata/SHA256SUMS
sudo sqlite3 -readonly dumps/<application>.sqlite 'PRAGMA integrity_check;'
sudo pg_restore --list dumps/immich.pgdump >/dev/null
```

For an Immich database restore, stop Immich services, terminate remaining
database sessions, recreate the database with the evaluated owner, then restore
the custom-format dump. Confirm the evaluated database name and owner first;
the defaults below are `immich`:

```bash
sudo systemctl stop immich-server.service immich-machine-learning.service
sudo -u postgres psql -d postgres -c \
  "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = 'immich';"
sudo -u postgres dropdb --if-exists immich
sudo -u postgres createdb --owner=immich immich
sudo -u immich pg_restore --dbname=immich --clean --if-exists \
  /persist/appdata/backup-metadata/current/dumps/immich.pgdump
sudo systemctl start immich-machine-learning.service immich-server.service
sudo systemctl status immich-server.service --no-pager
```

For SQLite applications, stop the service, preserve its existing database,
install the verified dump with the same owner and mode, start the service, and
inspect its journal. Do one application at a time; never bulk-copy every dump
over running services.

Run `mail-archive-ui verify-attachments --repair` manually when attachment
repair is required; routine backup preparation deliberately does not mutate the
archive.
