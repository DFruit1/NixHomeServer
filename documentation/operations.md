# Operations

Use this as the maintained day-2 operations guide for validation, guarded deploys, rollback, service health, SMART monitoring, and first-response troubleshooting.

## Service Access Canary

`canary-user` is a non-privileged Kanidm person used by the Homepage admin
service-access test. It belongs to normal application groups plus backup and
monitoring access, but never to `app-admin`, `domain_admins`, `system_admins`,
or delegated `idm_*` groups.

`kanidm-canary-bootstrap.service` automatically provisions the generated
`canaryUserPassword`, enrolls a Kanidm-generated SHA-256 TOTP credential, and
verifies a real password-plus-TOTP login. The root-only TOTP seed is persisted
at `/var/lib/homepage-canary-credentials/kanidm-totp-seed`; it is synthetic
operational state and does not need to be staged by an operator.

```bash
systemctl status kanidm-canary-bootstrap.service
journalctl -u kanidm-canary-bootstrap.service -n 100 --no-pager
```

The bootstrap is idempotent: a normal boot verifies the existing credentials
and leaves them unchanged. If the persisted seed is missing, corrupt, or no
longer matches Kanidm, it replaces the synthetic account credentials and
publishes a new root-only seed without printing secret material to the journal.
No browser enrollment or reset-token handoff is required.

The suite verifies unauthenticated blocking, Kanidm login, expected application
content, and visually blank pages even when the server returned HTTP 200.
Jellyfin and Vaultwarden have native logins; Kopia and Beszel add native login
after SSO. Those are reported as boundary-only checks and no app-local
credentials are stored.

Guarded deploys run the suite after public-route checks and return nonzero on a
failure. This does not automatically roll back the activated generation.
Failure JSON is stored under `/var/lib/homepage-canary/failures` for 14 days;
it contains statuses and render metrics but no screenshots, HTML, cookies, or
passwords.

```bash
sudo systemctl start homepage-canary.service
sudo homepage-canary-assert
sudo journalctl -u homepage-canary.service -n 100 --no-pager
```

Normal day-2 operations no longer require local Nix on the desktop. The
documented path is to stage the repo archive over SSH and let the remote server
perform evaluation, builds, activation, and secrets generation. Blank-machine
bootstrap remains the installer-side exception.

## After Bootstrap

A first install is complete when the host accepts SSH for `vars.localAdminUser`,
the agenix key is installed at `/persist/etc/agenix/age.key` (and visible at
`/etc/agenix/age.key` through impermanence after boot), the storage mounts are
present, and a guarded test deploy passes:

```bash
./scripts/deploy.sh --debug --action test
```

After that point, do not return to installer-time disk provisioning for normal
work. Routine changes use the guarded deploy path:

```bash
./scripts/deploy.sh --action test
./scripts/deploy.sh --action switch
```

Once homepage and SSO are reachable, use the homepage "For Admins" page for
live app configuration, user onboarding commands, and common server-management
reminders.

## Local-Console Administrator Recovery

The generated `serverBootstrapSudoPassword` is reconciled as the password for
`vars.localAdminUser`. It is a local-console recovery path if the administrator's
SSH key is unavailable; it does not enable password login over the network.
OpenSSH password and keyboard-interactive authentication both remain disabled.

On a trusted machine with the repository and private age identity, decrypt the
recovery value and use it only at the server's physical or virtual console:

```bash
age --decrypt --identity /path/to/age.key \
  secrets/serverBootstrapSudoPassword.age
```

On the running server, root can read the same value from
`/run/agenix/serverBootstrapSudoPassword` if an interactive sudo prompt is
unavoidable. Treat the output as a password: do not paste it into chat, tickets,
command arguments, or shell history.

## Common Commands

- Remote validation gate: `./scripts/deploy.sh --debug --action test`
- Local validation gate: `nix flake check --no-build` then `scripts/validate-repo.sh`
- Flake-inclusive local gate: `scripts/validate-repo.sh --run-flake-check`
- Full local gate: `scripts/validate-repo.sh --full`
- Human config summary: `nix run .#show-config-summary`
- Machine-readable inventory: `nix run .#export-inventory`
- Guarded deploy: `./scripts/deploy.sh --action test`
- Full guarded deploy: `./scripts/deploy.sh --action test --debug`
- Guarded switch: `./scripts/deploy.sh --action switch`
- Local-build deploy: `./scripts/deploy.sh --build-locally --action test`
- Server-side secret verification: `ssh <admin>@<hostname> 'cd /path/to/repo && nix run .#generate-secrets -- --identity /persist/etc/agenix/age.key'`
- Service health: `sudo systemctl --failed --no-pager`
- List/retrieve one-time Jellyfin credentials: `sudo jellyfin-initial-credential [USERNAME]`
- SMART sweep: `sudo systemctl start storage-smart-short.service`
- Local encrypted backup repository: `/mnt/data/backups/kopia`
- Manual external USB media root for operators: `/mnt/external-usb/`

`/mnt/data` is the configured data root for both storage profiles. On
`zfs-mirror` it is a ZFS pool mountpoint; on `single-disk-ext4` it is a normal
directory on the root filesystem.

## App Hostnames

Immich uses separate private and public hostnames on purpose. Show evaluated
URLs for a site with `nix run .#show-config-summary -- --host <host>`.

- Private Immich app: `https://<photos-domain>`
- Public Immich share links: `https://<share-photos-domain>`
- Authenticated Filestash UI and SFTP: `https://<files-domain>/`
- Private Vaultwarden: `https://<passwords-domain>`
- Local Kopia backup management UI: `https://<kopia-domain>/`

Use the private photos hostname for the owner's normal Immich login on LAN or
NetBird. Use the public share hostname only for public album or photo links sent
to other people.

Declaratively managed Jellyfin users receive a one-time random native password.
List available usernames with `sudo jellyfin-initial-credential`, retrieve one
with `sudo jellyfin-initial-credential USERNAME`, then change it after the first
login. The root-only handoff files live under
`/var/lib/jellyfin/.nixos-managed/initial-credentials/`; reconciliation never
overwrites a password after its durable initialization marker is recorded.

Use the files hostname for browser access. For large transfers, use the
dedicated OpenSSH SFTP endpoint on the configured `filesSftp` port over LAN.

Use the passwords hostname only on LAN or NetBird paths. The canonical operator
workflow for invites, break-glass local admin handling, and the standard
credential-item pattern lives in [Vaultwarden Guide](./vaultwarden.md).

Use the kopia hostname for local Kopia backup management. Browser access is gated by
Kanidm through OAuth2 Proxy and requires membership in `backup-admin`.
After OAuth2 succeeds, Kopia still requires its native `kopia-admin` password
from the generated `kopiaServerPassword` secret. The managed repository is a
local encrypted Kopia filesystem repository at `/mnt/data/backups/kopia`.
`backup-prepare.service` first creates integrity-checked SQLite dumps and an
Immich PostgreSQL custom-format dump under
`/persist/appdata/backup-metadata/current`; successful logical dumps are published
as immutable generations and this symlink is replaced atomically;
`kopia-persist-snapshot.timer`
then snapshots `/persist` and `/mnt/data/paperless` daily. On
`single-disk-ext4`, both paths live on the same root filesystem, so an external
or offsite backup remains important.

The MEGA remote and regular Kopia offsite sync are managed declaratively; there
is no persistent Rclone web service:

1. Set `rcloneMega.enable = true` and set `rcloneMega.email` in `vars.nix`.
2. From the repository, evaluate and confirm the exact destination:
   ```bash
   mega_destination="$(nix eval --raw \
     ".#lib.nixhomeserverSettings.<vars.hostname>.rcloneMega.destination")"
   printf 'MEGA mirror destination: %s\n' "$mega_destination"
   ```
   Never point it at an unverified or shared remote directory: the job is a
   mirror and intentionally deletes remote files that are absent locally.
3. Stage the MEGA password locally:
   ```bash
   install -d -m 0700 secrets/unencrypted
   install -m 0600 /path/to/mega-password-file secrets/unencrypted/rcloneMegaPassword
   nix run .#generate-secrets -- \
     --replace-external rcloneMegaPassword \
     --identity /path/to/current/age.key
   rm -f secrets/unencrypted/rcloneMegaPassword
   rmdir secrets/unencrypted 2>/dev/null || true
   ```
4. Deploy the host. Activation renders `/run/rclone/rclone.conf` from the
   agenix secret and keeps the plaintext password out of the Nix store and repo.
5. Confirm the timer is enabled, then start an immediate upload and wait for it:
   ```bash
   sudo systemctl is-enabled rclone-mega-kopia-sync.timer
   sudo systemctl start rclone-mega-kopia-sync.service
   sudo systemctl status rclone-mega-kopia-sync.service --no-pager
   ```
6. Do not treat an upload attempt as a backup. The service independently runs
   `rclone check` after the mirror completes and publishes
   `/var/lib/rclone/last-mega-sync-success.json` only after verification:
   ```bash
   mega_destination="$(nix eval --raw \
     ".#lib.nixhomeserverSettings.<vars.hostname>.rcloneMega.destination")"
   sudo jq . /var/lib/rclone/last-mega-sync-success.json
   sudo -u rclone rclone lsf --config /run/rclone/rclone.conf \
     --max-depth 2 "$mega_destination"
   ```

The scheduled oneshot job syncs `/mnt/data/backups/kopia` directly to the
configured MEGA destination. No Rclone daemon or web UI remains running between
jobs.
Check status with `systemctl status rclone-mega-kopia-sync.timer`,
`systemctl status rclone-mega-kopia-sync.service`, or
`journalctl -u rclone-mega-kopia-sync.service`.
Test a restore to a temporary directory at least quarterly; see
[Restore and Recovery](./restore-and-recovery.md). Never test a restore directly
over live `/persist` or `/mnt/data`.

Filestash and SFTP file roots:

- Filestash authenticates through OAuth2 Proxy and connects to the local SFTP endpoint as that Unix user with the managed Filestash SFTP key.
- `files-personal-users` is the base browser-workspace grant. Membership in
  `usb-access`, `files-shared-users`, or `backup-admin` only adds a view to an
  existing workspace and does not independently grant Filestash login.
- Filestash opens a single normal-user source, `Files`, rooted at the user's SFTP chroot.
- Direct SFTP opens the same personal root at `sftp://<username>@server.internal:<filesSftp-port>/`, currently port `2222`, and authenticates with the user's SSH key. Grant `files-sftp-users` for direct-only access; browser users receive the same chroot because Filestash itself uses SFTP as its backend.
- Direct SFTP password and keyboard-interactive login are disabled; install user public keys as root in `/persist/appdata/files-sftp-authorized-keys/<username>`.
- Port `22` is reserved for normal SSH administration and does not expose an SFTP subsystem.
- Users in `files-shared-users` also see `_Shared` at the top of that root.
- Users in `usb-access` also see `_USB`, backed by `/mnt/external-usb`. USB filesystems are mounted manually by an operator under that root.
- Users in `backup-admin` also see read-only `_Backups`, backed by `/mnt/data/backups`.
- `_Shared` is a delete-protected shared view. Reads, writes, edits, and same-folder renames affect the real shared storage immediately; deletes through `_Shared` should fail. Admin deletes are done directly against the real shared path.

Useful file-access checks:

```bash
kanidm group get files-personal-users
kanidm group get files-sftp-users
kanidm group get files-shared-users
kanidm group get usb-access
kanidm group get backup-admin

systemctl status 'files-shared-bindfs@<user>.service'
systemctl status 'files-usb-bindfs@<user>.service'
systemctl status 'files-backups-bindfs@<user>.service'
findmnt /mnt/data || test -d /mnt/data
findmnt /mnt/data/users/<user>/_Shared || mountpoint /mnt/data/users/<user>/_Shared
findmnt /mnt/data/users/<user>/_USB || mountpoint /mnt/data/users/<user>/_USB
findmnt /mnt/data/users/<user>/_Backups || mountpoint /mnt/data/users/<user>/_Backups

sudo -u filestash sh -lc 'probe=/mnt/data/users/<user>/_Shared/.write-probe && : >"$probe" && test -f "$probe"'
sudo -u filestash rm /mnt/data/users/<user>/_Shared/.write-probe
sudo rm /mnt/data/shared/.write-probe
```

The `rm` through `_Shared` is expected to fail with permission denied. The final admin delete against the real shared path should remove the probe from every `_Shared` view.

Kavita-managed book roots are aligned to the same simpler taxonomy used by
the rest of the stack: `_Ebooks`, `_Comics`, and `_Manga`. The old `other`
category is no longer part of the managed layout.

Current installs are expected to already use the underscore-prefixed content
layout. The repo no longer carries automatic migration helpers for old paths
such as `videos`, `books`, or `audiobooks`; restore or migration work from an
older layout should be handled deliberately before deploy.

Do not guess share hostnames manually; use the evaluated share hostname from
`nix run .#show-config-summary` or `vars.nix`.

Immich sharing flow:

1. Open Immich at the private photos hostname.
2. Create an album or photo share link
3. Send the generated public share URL to recipients.

## Mail Archive Operations

The mail archive UI stays private. `mail-archive-users` grants browser access to
the UI only. The archived sync payload stays in each user's hidden
`.internal-sync` tree, while the user-visible mailbox mirror is exposed as
hard-linked `.eml` files under that user's `_Emails/` root.

Normal checks and manual actions:

```bash
systemctl status mail-archive-ui mail-archive-oauth2-proxy mail-archive-sync.timer
sudo systemctl start mail-archive-sync.service
curl -fsS http://127.0.0.1:9011/healthz | jq .
```

Use the dashboard `Sync now` and `Reindex` actions when you need to repair or
refresh one mailbox without waiting for the timer. Use the mail archive
`/search` and `/attachments` routes with structured GET parameters such as
`sender_address`, `sender_name`, `sender_domain`, `subject`, `body_text`,
`date_from`, `date_to`, and `has_attachments`. Attachment search also accepts
`attachment_name`, `extension`, `mime_type`, `min_size`, `max_size`,
`min_attachments`, and `max_attachments`, so future tooling can scrape stable
URLs without browser automation.

Attachment downloads are backed by content-addressed blobs in each mailbox's
hidden `.internal-sync` tree. ZIP downloads include a `manifest.json` that maps
each file back to its mailbox, message, MIME type, size, and SHA-256. Inline
artifacts and `ripmime` body fragments such as `textfile0` are hidden by default
in the UI and can be included with the body-parts filter. ZIP contents are laid
out as `<mailbox>/<yyyy-mm-dd> - <subject>/<filename>`, and duplicate filenames
are suffixed as `file (1).ext`.

Attachment rows can be selected with normal click, Ctrl/Cmd-click, and
Shift-click conventions. Selected attachments can be downloaded locally as a ZIP
or copied into the configured Paperless consume inbox. The Paperless handoff is
recorded per user and attachment after the consume-file rename succeeds;
Paperless ownership and post-processing follow the normal Paperless consumer
behavior.

Saved attachment-filter presets can also be enabled as automatic Paperless
exports. Each task can run daily at a local time or at a repeating interval,
limit the number of new documents handled per run, and enable or disable
automatic retries. The scheduler polls every configured
`services.mail-archive-ui.paperlessTaskPollInterval` (five minutes by default).
Failed and partially successful runs use capped exponential retry delays; files
already published during a partial run are skipped safely on retry. An expiring
task lease prevents concurrent scheduler processes from running the same task.

Routine status and a manual scheduler run are available with:

```bash
systemctl status mail-archive-paperless-tasks.timer mail-archive-paperless-tasks.service
sudo systemctl start mail-archive-paperless-tasks.service
journalctl -u mail-archive-paperless-tasks.service --since today
```

Task configuration, counters, retry state, and the per-run
`attachment_paperless_task_runs` history are stored in the backed-up Mail
Archive SQLite database. Handoffs are staged and synced before an atomic publish
to the consume folder. A batch scans pending consume files once and reuses the
application and Paperless database connections, so large batches do not repeat
the same directory and connection work for every attachment.

To verify attachment backup readiness manually:

```bash
sudo -u mail-archive-ui env \
  MAIL_ARCHIVE_UI_DATA_DIR=/persist/appdata/mail-archive-ui \
  MAIL_ARCHIVE_UI_STORE_ROOT=/mnt/data/users \
  MAIL_ARCHIVE_UI_ACCOUNT_STATE_ROOT=/persist/appdata/mail-archive-ui/accounts \
  MAIL_ARCHIVE_UI_RUNTIME_DIR=/run/mail-archive-ui \
  MAIL_ARCHIVE_UI_LOCK_DIR=/persist/appdata/mail-archive-ui/locks \
  TMPDIR=/run/mail-archive-ui \
  SQLITE_TMPDIR=/run/mail-archive-ui \
  mail-archive-ui verify-attachments --repair --report /tmp/mail-archive-attachments.json
```

This repair command is intentionally manual and is not run by routine backup
preparation. Mail payload bytes remain on the mirrored
`/mnt/data/users` pool unless an operator intentionally adds those paths to a
Kopia policy.

## Validation Gate

The documented day-2 validation path runs on the remote server and does not need
local Nix:

```bash
./scripts/deploy.sh --debug --action test
```

That stages the current repo archive on the server and runs the full repository
gate there. A fresh remote validation stamp is reused by guarded deploys to
skip repeated repo checks for unchanged archive content.

Optional local validation remains available when you intentionally want to check
the repository before staging it on the server:

Run the flake check first.

```bash
nix flake check --no-build
```

Run the repo gate second.

```bash
scripts/validate-repo.sh
```

Default local `scripts/validate-repo.sh` behavior:
- runs the lean script suite through `scripts/tests/run-script-tests.sh`
- does not rerun `nix flake check --no-build`
- does not run Rust derivation checks

To include flake checks in the same pass:

```bash
scripts/validate-repo.sh --run-flake-check
```

For the full local gate:

```bash
scripts/validate-repo.sh --full
```

That mode runs:
- `nix flake check --no-build` unless `--skip-flake-check` is used
- `scripts/tests/run-script-tests.sh`
- `mail-archive-ui-test`

Kanidm checks use the native `kanidm` CLI. They do not rely on the old custom
helper package that was also named `kanidm-admin`; that package name is separate
from the configured `identity.adminUser` account name.

## Guarded Deploy

```bash
./scripts/deploy.sh --action test
```

That path resolves the target from `vars.localAdminUser` and `vars.serverLanIP`,
stages the current repo archive on that host, and keeps all Nix evaluation,
builds, activation, and validation on the server. Routine deploys use the lean
repository gate before `nixos-rebuild`; run `deploy.sh --debug` separately when
you want the full Nix, lint, and app check suite. The server also carries the
resulting `/nix/store` churn.

Only switch after the guarded test path passes.

```bash
./scripts/deploy.sh --action switch
```

For the slower full validation gate:

```bash
./scripts/deploy.sh --action test --debug
```

`--debug` keeps the normal deploy ordering but adds the full repository
validation gate before rebuilding. Use it for suspicious failures or broad
changes; routine deploys should stay on the fast path.

The regular deploy path stays intentionally quick. It evaluates the target
host, rebuilds remotely, and fails if systemd reports failed units afterward.

## Fast Remote Deploy

For normal remote deploys:

```bash
./scripts/deploy.sh
```

This resolves the SSH target from `vars.localAdminUser` and `vars.serverLanIP`,
stages the current repo archive, and runs `nixos-rebuild test` on the remote
host. It intentionally skips full repository validation and flake checks, but
still evaluates the host and checks failed units after the rebuild.

Use `--action switch` only after the test path passes and you want to change the
active system and boot default:

```bash
./scripts/deploy.sh --action switch
```

Use `--build-locally` when you intentionally want the workstation to perform the
Nix build and then activate the evaluated target over SSH:

```bash
./scripts/deploy.sh --build-locally --action test
```

For server-side secrets generation after local staging or edits:

```bash
ssh <admin>@<hostname> \
  'cd /path/to/repo && nix run .#generate-secrets -- --identity /persist/etc/agenix/age.key'
```

## Service Validation

```bash
sudo systemctl --failed --no-pager
./scripts/deploy.sh --debug --action test
```


Private-host troubleshooting note:
- if the passwords hostname does not resolve from a workstation browser, do not assume Vaultwarden is down
- verify the private edge directly with:

```bash
curl -kI --resolve <passwords-domain>:443:<server-lan-ip> https://<passwords-domain>/
```

- if the forced-resolution check succeeds while normal resolution fails, troubleshoot workstation DNS, LAN resolver reachability, or NetBird instead of changing Vaultwarden exposure

Storage monitoring now discovers disks live at runtime from an evaluated JSON
inventory embedded in the system generation; smartd startup does not evaluate
Nix or read the repository checkout:
- `system` is the static `vars.mainDisk`
- `dataN` are the current live `data` pool members discovered from ZFS
- `otherN` are every other attached non-system disk, including retired disks that are still physically attached

## Backup Media

Kopia uses a managed encrypted filesystem repository at
`/mnt/data/backups/kopia`. The `kopia-persist-snapshot.timer` creates daily
snapshots of `/persist` and `/mnt/data/paperless` after consistent logical
database preparation.

Rclone is an on-demand oneshot synchronizer for offsite copies of that encrypted
repository. The MEGA remote is rendered from `vars.rcloneMega` and the
`rcloneMegaPassword` agenix secret at activation time, and
`rclone-mega-kopia-sync.timer` regularly syncs the local encrypted Kopia
repository to MEGA.

The Kopia policy is deliberately bounded to 7 latest, 14 daily, 4 weekly, and
2 monthly snapshots (with no hourly or annual tier). Runtime caches, application
logs, retired Restic/pool-migration copies, and reproducible download/cache data
under `/persist` are excluded from the offsite snapshot.

MEGA synchronization uses permanent, delete-before semantics for this dedicated
Kopia mirror. This is important because the MEGA backend otherwise puts deleted
packs in its rubbish bin, where they continue consuming quota. A six-hourly
capacity check journals a warning at 80% and fails visibly at 90%, or when the
local repository reaches 18 GiB. Inspect it with:

```bash
sudo systemctl status rclone-mega-capacity-check.service --no-pager
sudo journalctl -t backup-capacity -n 50 --no-pager
```

`--mega-hard-delete` only affects future deletions made by this sync. Emptying
the account's existing MEGA rubbish bin is a separate, account-wide destructive
operation and must be performed explicitly after checking that it contains
nothing that should be recovered.

External USB storage is no longer a managed backup target. If an operator wants
to copy backups to a removable SSD, mount it manually under `/mnt/external-usb`
and copy or sync the encrypted repository files from `/mnt/data/backups`.

The previous automatic Restic `system-state` behavior is retired and no Restic
timer or backup service is enabled by this module.

Run safe repository maintenance and then propagate reclaimed packs to MEGA:

```bash
sudo systemctl start kopia-full-maintenance.service
sudo systemctl start rclone-mega-kopia-sync.service
sudo journalctl -u kopia-full-maintenance.service -u rclone-mega-kopia-sync.service -n 200 --no-pager
```

Kopia deletion safety is not overridden. UI-deleted snapshots may remain until
a later full-maintenance cycle. Routine journal retention is 14 days/256 MiB;
Kopia file logs are removed after 14 days. Caddy keeps five 25 MiB rolled access
logs for at most 30 days.

## Local ZFS Snapshots

The ZFS profile retains 24 hourly, 7 daily, and 4 weekly snapshots. The backup
and upload-staging datasets are excluded. Inspect usage with:

```bash
sudo zfs list -t snapshot -o name,creation,used -s creation -r data
sudo systemctl status zfs-snapshot-health.service --no-pager
```

`orphan-state-report.service` reports preserved legacy paths and datasets under
`/persist/appdata/backup-metadata/metadata/orphan-state.json`; it never deletes
them.

## Shared Authentication Logout

Proxy-protected applications use the shared `auth.<domain>` gateway and one
domain cookie. Signing out there signs out every gateway-protected application.
Native OIDC applications keep independent sessions because Kanidm does not
advertise an end-session, front-channel logout, or back-channel logout endpoint.

## SMART Monitoring

The retained storage monitoring workflow is:
- `systemctl --failed`
- `scripts/helpers/storage-health-common.sh`
- `scripts/discover-storage-devices.sh`
- `scripts/generate-smartd-config.sh`
- `scripts/run-storage-smart-sweep.sh`

The scheduled SMART jobs are now discovery sweeps:
- `storage-smart-short.timer`
- `storage-smart-long.timer`

Attached retired disks will keep appearing in SMART checks until they are
physically detached from the server.

Use these checks first on the target host:

```bash
sudo systemctl --failed --no-pager
systemctl status storage-smart-short.timer
systemctl status storage-smart-long.timer
```

To inspect scheduled SMART self-test activity:

```bash
journalctl -u storage-smart-short -n 100 --no-pager
journalctl -u storage-smart-long -n 100 --no-pager
```
