# Restore And Recovery

Use this guide for the maintained recovery boundary:
- replacing one failed member in the active mirrored `data` pool
- inspecting or restoring SSD-backed application state from the selected Restic backup target

Do not use `disko` for these workflows. Existing-server storage maintenance is handled in place with ZFS and the standard block-device tools already installed on the host.

## Scenario: Replace A Degraded Disk In A Mirror Pool

```bash
sudo zpool status data
sudo zpool list -v
sudo zpool replace data \
  /dev/disk/by-id/<failed-disk>-part1 \
  /dev/disk/by-id/<replacement-disk>-part1
sudo zpool status data
sudo zfs list -r data
sudo ./scripts/check-runtime-readiness.sh --profile manual
```

## Scenario: Restore SSD-Backed App State

Precondition:
- a backup target is already selected with `manage-backup-target select ...`

```bash
systemctl status restic-backups-system-state.timer
sudo manage-backup-target mount
sudo systemctl start restic-backups-system-state.service
sudo restic-system-state snapshots
sudo column -t -s $'\t' /persist/appdata/system-state-backup/metadata/app-state-roots.tsv
sudo restic-system-state restore latest --target /tmp/system-state-restore
sudo column -t -s $'\t' /tmp/system-state-restore/persist/appdata/system-state-backup/metadata/app-state-roots.tsv
sudo ls -1 /tmp/system-state-restore/persist/appdata/system-state-backup/dumps
sudo manage-backup-target unmount
```
