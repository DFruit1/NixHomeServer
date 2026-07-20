# Restore And Recovery

Use this guide for the maintained recovery boundary:
- replacing one failed member in the active configured mirror pool when using
  `storage.profile = "zfs-mirror"`
- replacing only the failed system SSD while preserving every configured ZFS
  data-pool disk
- checking and restoring a `storage.profile = "single-disk-ext4"` host
- inspecting or restoring SSD-backed application state from Kopia-managed backup repositories

Only the explicit guarded `--system-disk-only` recovery below uses a dedicated
Disko output, and that output contains no data-pool devices. Never use the
normal blank-host/bootstrap Disko mode for pool-member replacement, application
state restore, or any other existing-server maintenance; those workflows are
handled in place with the standard block-device and filesystem tools.

Kopia is the maintained backup interface. The managed repository is a local
encrypted filesystem repository below `vars.backupRoot` (by default
`/mnt/data/backups/kopia`), and the
`kopia-persist-snapshot.timer` creates daily snapshots of `/persist` and
the Paperless media root below `vars.dataRoot` after `backup-prepare.service`
publishes consistent dumps.

On `zfs-mirror`, `vars.dataRoot` is the mirrored ZFS data pool. On
`single-disk-ext4`, `vars.dataRoot` and `/persist` are regular directories on
the root ext4 filesystem, so local Kopia data is not a second-disk copy unless
you also sync it off host.

The previous automatic Restic `system-state` backup is retired and no Restic
timer or backup service is enabled by this module.

## Before Any Recovery

Enter the exact repository revision used for the recovery (`/persist/etc/nixos`
on a running host or `/tmp/nixhomeserver` in the installer), then evaluate the
configured pool and storage paths once. Every command below uses these quoted
variables rather than assuming the defaults. Rerun this block after changing
revisions or editing `vars.nix`:

```bash
server_settings="$(
  nix eval --json .#lib.nixhomeserverSerializableSettings \
    | jq -e '
        if type == "object" and length == 1
        then to_entries[0].value
        else error("expected exactly one configured host")
        end
      '
)"
pool_name="$(jq -er '.zfsDataPool.name | strings | select(length > 0)' \
  <<<"$server_settings")"
data_root="$(jq -er '.dataRoot | strings | select(startswith("/"))' \
  <<<"$server_settings")"
backup_root="$(jq -er '.backupRoot | strings | select(startswith("/"))' \
  <<<"$server_settings")"
printf 'pool=%q data_root=%q backup_root=%q\n' \
  "$pool_name" "$data_root" "$backup_root"
```

1. Do not guess device names. Record `lsblk -e7 -o NAME,SIZE,MODEL,SERIAL,WWN,FSTYPE,MOUNTPOINTS`,
   `findmnt`, `zpool status -P`, and `zpool status -g` before changing disks.
2. Verify the pool name and the exact failed member against `vars.nix`. A path
   containing `<...>` anywhere below is a placeholder, not a command to paste.
3. Confirm a recent local snapshot and, when enabled, the verified offsite
   marker:
   ```bash
   sudo jq . "$backup_root/.kopia-last-snapshot-success.json"
   sudo jq . /var/lib/rclone/last-mega-sync-success.json
   cd /persist/etc/nixos
   nix run .#kopia-managed -- snapshot list --all
   ```
4. Stop the affected application before overwriting its state. Database
   restores must never run while the corresponding application is writing.
5. Restore into a new staging directory first. Validate hashes, ownership and
   database integrity there; preserve the live directory as a timestamped
   rollback copy until the application has passed its health check.

## Scenario: Replace Only The System SSD On A ZFS Host

This workflow is available only for `storage.profile = "zfs-mirror"`. A
single-disk-ext4 host stores `/persist`, `vars.dataRoot`, and its local Kopia
repository on the same disk, so replacing that disk requires an off-host backup
and cannot preserve a local data pool.

The recovery revision must contain a non-null numeric
`storage.dataPool.expectedGuid`. The system-disk-only wrapper refuses to
preserve an unpinned pool and prints the pinned GUID in its plan. If an older
installation still has `expectedGuid = null`, stop before Disko. From the
installer, first inventory importable pools, import the candidate by its
reported numeric GUID without mounting datasets, and prove that every
configured member belongs to it:

```bash
sudo zpool import -d /dev/disk/by-id
sudo zpool import -d /dev/disk/by-id -N <candidate-numeric-guid>
sudo scripts/helpers/verify-zfs-pool-identity.sh \
  --pool "$pool_name" \
  --expected-device /dev/disk/by-id/<first-configured-data-disk> \
  --expected-device /dev/disk/by-id/<second-configured-data-disk>
sudo zpool export "$pool_name"
```

The verifier accepts an unpinned pool only when all configured members match
and reports the numeric GUID to place in `storage.dataPool.expectedGuid`.
Repeat `--expected-device` for every configured data-pool disk when the pool
has more than the two members shown. Set the reported value, commit the
recovery revision, and rerun readiness before invoking the system-disk-only
wrapper. Do not proceed if the topology check fails or the pool cannot be
cleanly exported.

Boot the installer, obtain the exact deployed repository revision and two
matching private age-key copies on separate filesystems, then inspect every
device and any imported pool. The replacement SSD has a new stable by-id name,
so update only `storage.systemDisk` in `vars.nix` before asking Disko to find it:

```bash
lsblk -e7 -o NAME,PATH,SIZE,MODEL,SERIAL,WWN,FSTYPE,MOUNTPOINTS
zpool status -P || true
cd /tmp/nixhomeserver
git config --local user.name "$(jq -er '.kanidmAdminUser' \
  <<<"$server_settings")"
git config --local user.email "$(jq -er '.kanidmAdminEmail' \
  <<<"$server_settings")"
test -n "$(git config --local --get user.name)"
test -n "$(git config --local --get user.email)"
test -z "$(git status --short)"
$EDITOR vars.nix
# Set storage.systemDisk to the replacement SSD's /dev/disk/by-id basename.
git diff -- vars.nix
git add vars.nix
git diff --cached --check
git commit -m "Record replacement system SSD"
test -z "$(git status --short)"
git rev-parse HEAD
```

Record this recovery revision and copy/push or bundle it to durable storage.
Do not change any data-pool member IDs, its expected GUID, or the generated
hardware module. All validation, Disko, installation, and later workstation
deployment must use this new recovery revision:

```bash
nix run .#validate-config-readiness -- \
  --host <vars.hostname> \
  --require-local-hardware \
  --identity /path/to/age.key
sudo nix run .#bootstrap-disks -- \
  --host <vars.hostname> \
  --system-disk-only
```

The printed plan must list exactly `storage.systemDisk`. It also prints the
pinned pool GUID and every data-pool by-id value as preserved. Match that GUID
to the committed recovery revision. If any data disk appears under “disks that
will be erased,” stop. Apply the system-only plan by confirming the configured
pool name as well as the one system disk:

```bash
sudo nix run .#bootstrap-disks -- \
  --host <vars.hostname> \
  --system-disk-only \
  --apply \
  --identity /path/to/age.key \
  --age-key-backup /path/to/separately-mounted-media/nixhomeserver.age.key \
  --confirm-host <vars.hostname> \
  --confirm-preserve-data-pool "$pool_name" \
  --confirm-disk <system-disk-by-id-basename>
```

This mode builds a dedicated `<vars.hostname>-system-recovery` Disko output which
contains only `disko.devices.disk.system`; it cannot partition a configured
data-pool member. It still irreversibly erases the selected system SSD.

After Disko, import and mount the preserved pool without running the application
stack. Import it by the committed `storage.dataPool.expectedGuid`, never merely
by its mutable pool name. Then connect a temporary Kopia client using the
encrypted credential in the recorded recovery revision:

```bash
expected_pool_guid="$(jq -er '
  .zfsDataPool.expectedGuid
  | strings
  | select(test("^[1-9][0-9]*$"))
' <<<"$server_settings")"
sudo zpool import -d /dev/disk/by-id -N "$expected_pool_guid"
sudo scripts/helpers/verify-zfs-pool-identity.sh \
  --pool "$pool_name" \
  --expected-guid "$expected_pool_guid" \
  --expected-device /dev/disk/by-id/<first-configured-data-disk> \
  --expected-device /dev/disk/by-id/<second-configured-data-disk>
sudo zfs mount "$pool_name"
sudo zfs mount "${pool_name}/backups"
mountpoint "$data_root"
sudo install -d -m 0700 /run/kopia-recovery
cd /tmp/nixhomeserver
nix run .#kopia-managed -- \
  --recovery-config /run/kopia-recovery/system-ssd.config \
  --recovery-identity /path/to/age.key \
  repository connect filesystem \
  --path="${backup_root}/kopia" \
  --cache-directory=/run/kopia-recovery/cache \
  --no-use-keyring
nix run .#kopia-managed -- \
  --recovery-config /run/kopia-recovery/system-ssd.config \
  --recovery-identity /path/to/age.key \
  snapshot list --all
```

The managed wrapper accepts only a direct `*.config` child of that root-owned,
mode-`0700` runtime directory. It rejects nested, traversing, symlinked, or
group/world-readable existing config paths before bypassing the normal data
pool mount requirement.

Do not omit `--expected-guid` in this post-Disko recovery check; the guarded
system-disk-only workflow requires the pool identity to have been pinned in the
recorded revision first. If the pool is already imported, run the same identity
verification and use `zfs mount` rather than importing it again. Restore the required `/persist` snapshot into a new
staging directory, validate it, and then populate the new `/mnt/persist`
filesystem **before `nixos-install` and the first normal boot**, following the
staged-restore rules below. Re-seed or fast-forward the installed repository to
the recorded recovery revision afterward. Do not let applications initialize
empty state and then overwrite it with an unreviewed restore.

## Scenario: Replace A Degraded Disk In A Mirror Pool

Use this only for `storage.profile = "zfs-mirror"`.

First identify a healthy member from the same mirror and the new whole-disk
by-id path. The replacement must be at least as large as the failed device.
Replicate the partition table from the healthy disk, give the replacement new
GUIDs, and ask the kernel to reread it:

```bash
sudo zpool status -P "$pool_name"
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
sudo zpool replace "$pool_name" \
  /dev/disk/by-id/<failed-disk>-part1 \
  /dev/disk/by-id/<replacement-disk>-part1
sudo watch -n 10 zpool status -P "$pool_name"
```

Wait for `scan: resilvered ... with 0 errors` and an `ONLINE` or expected
`DEGRADED` pool before rebooting. Then run and complete a scrub:

```bash
sudo zpool scrub "$pool_name"
sudo watch -n 30 zpool status -P "$pool_name"
sudo zfs list -r "$pool_name"
for target in "$data_root" "${data_root}/users" "${data_root}/shared" "$backup_root"; do
  findmnt --target "$target"
done
sudo systemctl --failed --no-pager
```

Before the next normal boot, replace the failed whole-disk by-id basename in
`storage.dataPool.mirrorPairs` with the replacement disk's stable whole-disk
basename (not its `-part1` path). Keep `storage.dataPool.expectedGuid`
unchanged, run config readiness, and complete the guarded test/switch deploy
while the verified pool is online. The boot-time identity verifier rejects an
unconfigured replacement member. If an emergency reboot is unavoidable before
that deploy, use the documented one-boot `zfs_recovery_import=1` recovery
override, verify the pool at the console, and update the declarative identity
immediately. Do not run blank-host Disko against this already-imported pool.

## Scenario: Check A Single-Disk Ext4 Host

Use this for `storage.profile = "single-disk-ext4"` after boot, power loss, or
storage warnings:

```bash
findmnt -no SOURCE,FSTYPE,OPTIONS /
df -hT / "$data_root" /persist
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
mega_destination="$(jq -er '.rcloneMega.destination | strings | select(length > 0)' \
  <<<"$server_settings")"
recovered_repository="${backup_root}/kopia-recovered"
printf 'Recovering from: %s\n' "$mega_destination"
sudo systemctl start rclone-mega-config.service
sudo -u rclone rclone lsf --config /run/rclone/rclone.conf \
  --max-depth 2 "$mega_destination"
sudo install -d -o rclone -g rclone -m 0700 "$recovered_repository"
sudo -u rclone test -w "$recovered_repository"
sudo -u rclone rclone copy --config /run/rclone/rclone.conf \
  --progress "$mega_destination" "$recovered_repository"
```

Connect Kopia to the recovered repository without overwriting the managed live
configuration. Use a temporary config and the existing `kopiaServerPassword`:

```bash
sudo install -d -m 0700 /run/kopia-recovery
nix run .#kopia-managed -- \
  --recovery-config /run/kopia-recovery/repository.config \
  repository connect filesystem \
  --path="$recovered_repository" \
  --cache-directory=/run/kopia-recovery/cache \
  --no-use-keyring
nix run .#kopia-managed -- \
  --recovery-config /run/kopia-recovery/repository.config \
  snapshot list --all
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
sudo bash -c '
  set -euo pipefail
  cd /persist/appdata/backup-metadata/current
  sha256sum --check metadata/SHA256SUMS
  sqlite3 -readonly dumps/<application>.sqlite "PRAGMA integrity_check;"
  pg_restore --list dumps/immich.pgdump >/dev/null
'
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
sudo install -d -o postgres -g postgres -m 0700 /run/immich-restore
sudo install -o postgres -g postgres -m 0400 \
  /persist/appdata/backup-metadata/current/dumps/immich.pgdump \
  /run/immich-restore/immich.pgdump
sudo -u postgres pg_restore --dbname=immich --clean --if-exists \
  /run/immich-restore/immich.pgdump
sudo rm -rf /run/immich-restore
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
