# Operations

Use this as the maintained day-2 operations guide for validation, guarded deploys, rollback, service health, SMART monitoring, and first-response troubleshooting.

Normal day-2 operations no longer require local Nix on the desktop. The
documented path is to stage the repo archive over SSH and let the remote server
perform evaluation, builds, activation, and secrets generation. Blank-machine
bootstrap remains the installer-side exception.

## After Bootstrap

A first install is complete when the host accepts SSH for `vars.localAdminUser`,
the agenix key is installed at `/etc/agenix/age.key`, the storage mounts are
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
- Server-side secrets: `ssh <admin>@<hostname> 'cd /path/to/repo && ./scripts/generate-all-secrets.sh'`
- Service health: `sudo systemctl --failed --no-pager`
- SMART sweep: `sudo systemctl start storage-smart-short.service`
- Local encrypted backup repository: `/mnt/data/backups/kopia`
- Manual external USB media root for operators: `/mnt/external-usb/`

## App Hostnames

Immich uses separate private and public hostnames on purpose. Show evaluated
URLs for a site with `nix run .#show-config-summary -- --host <host>`.

- Private Immich app: `https://<photos-domain>`
- Public Immich share links: `https://<share-photos-domain>`
- Authenticated Filestash UI and SFTP: `https://<files-domain>/`
- Private Vaultwarden: `https://<passwords-domain>`
- Local Kopia backup management UI: `https://<kopia-domain>/`
- Offsite rclone backup GUI: `https://<rclone-domain>/`

Use the private photos hostname for the owner's normal Immich login on LAN or
NetBird. Use the public share hostname only for public album or photo links sent
to other people.

Use the files hostname for browser access. For large transfers, use the
dedicated OpenSSH SFTP endpoint on the configured `filesSftp` port over LAN.

Use the passwords hostname only on LAN or NetBird paths. The canonical operator
workflow for invites, break-glass local admin handling, and the standard
credential-item pattern lives in [Vaultwarden Guide](./vaultwarden.md).

Use the kopia hostname for local Kopia backup management. Browser access is gated by
Kanidm through OAuth2 Proxy and requires membership in `backup-admin`.
After OAuth2 succeeds, Kopia still requires its native `kopia-admin` password
from the generated `kopiaServerPassword` secret. The managed repository is a
local encrypted Kopia filesystem repository at `/mnt/data/backups/kopia`, and
`kopia-persist-snapshot.timer` snapshots `/persist` into it daily.

Use the rclone hostname for offsite backup inspection. Browser access is gated
by Kanidm through OAuth2 Proxy and requires membership in `backup-admin`.
The MEGA remote and regular Kopia offsite sync are managed declaratively:

1. Set `rcloneMega.email` in `vars.nix` to the MEGA account email.
2. Confirm `rcloneMega.destination`, normally `mega:NixHomeServer/kopia`.
3. Stage the MEGA password locally:
   ```bash
   install -d -m 0700 secrets/unencrypted
   install -m 0440 /path/to/mega-password-file secrets/unencrypted/rcloneMegaPassword
   ./scripts/generate-all-secrets.sh
   ```
4. Deploy the host. Activation renders `/run/rclone/rclone.conf` from the
   agenix secret and keeps the plaintext password out of the Nix store and repo.
5. The recurring sync is `rclone-mega-kopia-sync.timer`. Start an immediate
   upload with:
   ```bash
   systemctl start rclone-mega-kopia-sync.service
   ```

The scheduled job syncs `/mnt/data/backups/kopia` to the configured MEGA
destination through the running Rclone RC daemon, so jobs are visible from the
Rclone Web GUI while systemd remains the source of truth for schedule and logs.
Check status with `systemctl status rclone-mega-kopia-sync.timer`,
`systemctl status rclone-mega-kopia-sync.service`, or
`journalctl -u rclone-mega-kopia-sync.service`.

Filestash and SFTP file roots:

- Filestash authenticates through OAuth2 Proxy and connects to the local SFTP endpoint as that Unix user with the managed Filestash SFTP key.
- Filestash opens a single normal-user source, `Files`, rooted at the user's SFTP chroot.
- Direct SFTP opens the same personal root at `sftp://<username>@server.internal:<filesSftp-port>/`, currently port `2222`, and authenticates with the user's SSH key.
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
mountpoint /mnt/data/users/<user>/_Shared
mountpoint /mnt/data/users/<user>/_USB
mountpoint /mnt/data/users/<user>/_Backups

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

Kopia policies should include this verifier output if mail archive attachment
metadata is part of the backup set. Mail payload bytes remain on the mirrored
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

Kanidm checks are now native to the runtime scripts and do not rely on the archived `kanidm-admin` package.

## Guarded Deploy

```bash
./scripts/deploy.sh --action test
```

That path resolves the target from `vars.localAdminUser` and `vars.hostname`,
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

This resolves the SSH target from `vars.localAdminUser` and `vars.hostname`,
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
ssh <admin>@<hostname> 'cd /path/to/repo && ./scripts/generate-all-secrets.sh'
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

Storage monitoring now discovers disks live at runtime:
- `system` is the static `vars.mainDisk`
- `dataN` are the current live `data` pool members discovered from ZFS
- `otherN` are every other attached non-system disk, including retired disks that are still physically attached

## Backup Media

Kopia uses a managed encrypted filesystem repository at
`/mnt/data/backups/kopia`. The `kopia-persist-snapshot.timer` creates daily
snapshots of `/persist`.

Rclone provides an authenticated Web GUI for inspecting offsite copies of that
encrypted repository. The MEGA remote is rendered from `vars.rcloneMega` and the
`rcloneMegaPassword` agenix secret at activation time, and
`rclone-mega-kopia-sync.timer` regularly syncs the local encrypted Kopia
repository to MEGA.

External USB storage is no longer a managed backup target. If an operator wants
to copy backups to a removable SSD, mount it manually under `/mnt/external-usb`
and copy or sync the encrypted repository files from `/mnt/data/backups`.

The previous automatic Restic `system-state` behavior is retired and no Restic
timer or backup service is enabled by this module.

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
