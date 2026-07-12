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

## Scenario: Replace A Degraded Disk In A Mirror Pool

Use this only for `storage.profile = "zfs-mirror"`.

```bash
sudo zpool status data
sudo zpool list -v
sudo zpool replace data \
  /dev/disk/by-id/<failed-disk>-part1 \
  /dev/disk/by-id/<replacement-disk>-part1
sudo zpool status data
sudo zfs list -r data
sudo systemctl --failed --no-pager
```

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

## Scenario: Restore SSD-Backed App State

Use the Kopia UI at the kopia hostname to browse snapshots and restore the
needed paths. If an operator has manually copied `/mnt/data/backups/kopia` to
external media, copy it back under `/mnt/data/backups/kopia` or connect Kopia to
that copied filesystem repository explicitly.

Useful restored dump files:

- `successful/dumps/immich.pgdump`: custom-format Immich PostgreSQL dump; inspect
  with `pg_restore --list` and restore with `pg_restore`.
- `successful/dumps/*.sqlite`: integrity-checked SQLite backups for configured
  applications.
- `successful/dumps/mail-archive-ui.sqlite3`: Mail Archive UI state, including
  attachment catalog and Paperless handoff records.

Useful restored metadata files:

- `successful/metadata/manifest.json`: dump-set timestamp, host, and schema.
- `successful/metadata/SHA256SUMS`: hashes for every prepared database dump.
- `successful/metadata/mail-archive-roots.tsv`: per-user mail archive root status
  and counts without message or attachment names.

Run `mail-archive-ui verify-attachments --repair` manually when attachment
repair is required; routine backup preparation deliberately does not mutate the
archive.
