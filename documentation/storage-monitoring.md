# Storage Monitoring

Disk checks are a first-class operational feature.

This layer is complementary to `./scripts/runtime-readiness.sh`:

- runtime readiness is the manual deploy/runtime gate
- storage monitoring is the continuous background report and alert path

## Scope

Automated storage monitoring includes:

- all configured mirrored data-pool disks from `vars.zfsDataPool`
- all configured manual cold-storage disks from `vars.coldStoragePools`

## What runs automatically

### SMART daemon baseline

`smartd` remains enabled for:

- data-pool disks
- configured cold-storage disks

### SMART self-test schedules

Schedules are derived from the configured monitored-disk order, so they move when
the storage topology changes.

Current topology:

Weekly short tests:

- `disk1`: Saturday `03:00`
- `disk2`: Saturday `03:20`
- `disk3`: Saturday `03:40`
- `disk4`: Saturday `04:00`
- `cold-v1jan8ph`: Saturday `04:20`

Monthly long tests:

- `disk1`: day `01` at `01:00`
- `disk2`: day `02` at `01:00`
- `disk3`: day `03` at `01:00`
- `disk4`: day `04` at `01:00`
- `cold-v1jan8ph`: day `05` at `01:00`

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

- the `data` pool mount and expected child dataset mounts
- SMART status for monitored disks
- recent kernel transport errors from `journalctl -k`
- last SMART self-test status
- `zpool list` health for the data pool
- `zfs list` coverage for the expected datasets
- timer state for SMART monitoring timers

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

Cold storage is monitored for SMART and reported in the periodic storage report,
but it remains manual for imports and mounts. Use `scripts/cold-storage.sh` to
import, mount, unmount, and export the configured pool.
