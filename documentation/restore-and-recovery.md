# Restore And Recovery

Use this guide for the maintained recovery boundary:
- replacing one failed member in the active mirrored `data` pool
- inspecting or restoring SSD-backed application state from Kopia-managed backup repositories

Do not use `disko` for these workflows. Existing-server storage maintenance is handled in place with ZFS and the standard block-device tools already installed on the host.

Kopia is the maintained backup interface. The server starts the Kopia UI without
preselecting a repository, so an operator can connect Backblaze, another remote
repository, or a repository on an automatically mounted USB drive under
`/mnt/external-usb/<label-or-uuid>`.

The previous automatic Restic `system-state` backup is retired and no Restic
timer or backup service is enabled by this module.

## Scenario: Replace A Degraded Disk In A Mirror Pool

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

## Scenario: Restore SSD-Backed App State

Use the Kopia UI at the backups hostname to browse snapshots and restore the
needed paths. For local USB repositories, attach the drive and use its
automounted path under `/mnt/external-usb/` when connecting the repository.

Useful restored dump files:

- `dumps/postgresql.sql`: logical PostgreSQL dump.
- `dumps/mail-archive-ui.sqlite3`: Mail Archive UI state, including attachment catalog and Paperless handoff records.

Useful restored metadata files:

- `metadata/critical-paths.tsv`: expected core state and payload roots.
- `metadata/upload-flow-roots.tsv`: retained upload staging and quarantine root status, when present.
- `metadata/mail-archive-roots.tsv`: per-user mail archive root status and counts, without listing message or attachment names.
- `metadata/mail-archive-attachments.json`: attachment blob verification report generated before backup.
