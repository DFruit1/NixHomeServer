# Storage Monitoring

Disk checks are now a first-class operational feature.

This layer is complementary to `./scripts/runtime-readiness.sh`:

- runtime readiness is the manual deploy/runtime gate
- storage monitoring is the continuous background report and alert path

## Scope

Automated storage monitoring includes:

- all configured data disks from `vars.dataDisks`
- all configured parity disks from `vars.parityDisks`
- the configured backup disk when `enableBackupDisk = true`

Automated storage monitoring excludes:

- `vars.coldStorageDisk`

Cold storage remains manual on purpose so it does not spin up for routine checks.

## What runs automatically

### SMART daemon baseline

`smartd` remains enabled for:

- data disks
- parity disks
- the active backup disk

It does not monitor cold storage.

### SMART self-test schedules

Weekly short tests:

- `disk1`: Saturday `03:00`
- `disk2`: Saturday `03:20`
- `disk3`: Saturday `03:40`
- `parity`: Saturday `04:00`
- `parity2`: Saturday `04:20`
- `backupDisk`: Saturday `04:40` when enabled

Monthly long tests:

- `disk1`: day `01` at `01:00`
- `disk2`: day `02` at `01:00`
- `disk3`: day `03` at `01:00`
- `parity`: day `04` at `01:00`
- `parity2`: day `05` at `01:00`
- `backupDisk`: day `06` at `01:00` when enabled

These run as systemd timer/service pairs:

- `storage-smart-short@<label>.timer`
- `storage-smart-long@<label>.timer`

### Periodic report timer

The main report timer is:

- `storage-health-report.timer`

It runs every 30 minutes and writes fresh JSON and text summaries.

## Report artifacts

Current report files:

- `/var/lib/storage-monitoring/latest.json`
- `/var/lib/storage-monitoring/latest.txt`

Historical snapshots:

- `/var/lib/storage-monitoring/history/<timestamp>.json`
- `/var/lib/storage-monitoring/history/<timestamp>.txt`

History older than 90 days is cleaned automatically.

## What the report checks

Each run evaluates:

- mergerfs and all configured data/parity mounts
- `/mnt/backup` when the backup disk is enabled
- SMART status for monitored disks
- recent kernel transport errors from `journalctl -k`
- last SMART self-test status
- `snapraid status`
- `snapraid diff`
- timer state for SnapRAID and SMART monitoring timers

## Ntfy alerts

Alerts are sent through the webhook URL stored in:

- `age.secrets.storageAlertWebhookUrl`

The repo ships with a placeholder encrypted value so config evaluation still works before the real webhook is staged.

Alert behavior:

- send on degraded-state changes
- do not resend the same ongoing failure every 30 minutes
- send one recovery alert when the state returns to `OK`

## Operator commands

```bash
systemctl list-timers 'storage-*'
systemctl status storage-health-report.timer
sudo systemctl start storage-health-report.service
sudo cat /var/lib/storage-monitoring/latest.txt
sudo jq . /var/lib/storage-monitoring/latest.json
```

## Cold storage

Cold storage is intentionally excluded from:

- `smartd`
- SMART self-test timers
- periodic reports
- ntfy alerts
- deploy/runtime gating
