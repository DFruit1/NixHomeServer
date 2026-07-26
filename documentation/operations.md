# Operations

Use this as the maintained day-2 operations guide for validation, guarded deploys, rollback, service health, SMART monitoring, and first-response troubleshooting.

## Service Access Canary

`canary-user` is a non-privileged Kanidm person used by the Homepage admin
service-access test. It belongs to normal application groups plus monitoring
access, but never to the exactly reconciled backup groups, `app-admin`,
`domain_admins`, `system_admins`, or delegated `idm_*` groups.

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
Jellyfin is checked through native OIDC plus a separate Quick Connect exchange
that verifies the expected user and revokes the canary token. Vaultwarden has a
native login; Kopia and Beszel add native login after SSO. Those remaining
services are reported as boundary-only checks and no app-local credentials are
stored.

Guarded deploys run the suite after public-route checks and return nonzero on a
failure. A failing health gate immediately restores the previous live
generation; the target-side rollback timer remains the backstop if immediate
recovery cannot complete. Failure JSON is stored under
`/var/lib/homepage-canary/failures` for 14 days; it contains statuses and render
metrics but no screenshots, HTML, cookies, or passwords.

```bash
sudo systemctl start homepage-canary.service
sudo homepage-canary-assert
sudo journalctl -u homepage-canary.service -n 100 --no-pager
```

Normal day-2 builds run on the server, but the administrator's workstation still
needs the `nix` command. The deploy wrapper uses it for local flake/hostname
validation before staging the repository over SSH; the server performs the
resource-intensive NixOS evaluation, build, activation, and secret generation.
Use the Nix-capable workstation prepared in the quickstart for both bootstrap
and routine deploys.

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

## Failure Alerts

Important backup, snapshot-freshness, SMART, offsite-sync, and authenticated
canary failures always create a `daemon.alert` journal event through
`nixhomeserver-failure-alert@.service`.

To deliver those events externally, stage and encrypt the optional manifest
secret containing the full HTTPS webhook URL:

```bash
install -d -m 0700 secrets/unencrypted
install -m 0600 /path/to/webhook-url secrets/unencrypted/failureAlertWebhookUrl
nix run .#generate-secrets -- \
--replace-external failureAlertWebhookUrl \
--identity /path/to/current/age.key
rm -f secrets/unencrypted/failureAlertWebhookUrl
rmdir secrets/unencrypted 2>/dev/null || true
git add secrets/failureAlertWebhookUrl.age
```

The default webhook body is JSON. For a full ntfy topic URL, set this in host
configuration and deploy:

```nix
repo.monitoring.failureAlerts.format = "ntfy";
```

Test the local delivery path without breaking a production service:

```bash
sudo systemd-run --unit=nixhomeserver-alert-test \
--property='OnFailure=nixhomeserver-failure-alert@%n.service' \
/bin/false
sudo journalctl -t nixhomeserver-failure-alert -n 20 --no-pager
```

## Disabling Optional Applications

Application modules are independent of one another. Removing an application's
entry from `modules/catalog.nix` is the strongest disabled state and is
appropriate for applications with no enable switch. Integrations are cataloged
separately and detect absent application options as no-ops. The repository
regression suite evaluates Core-only, every optional module removed
independently, and a targeted single-app topology.

The following imported modules also have a convenient active-feature switch.
Setting one to `false` removes its services, routes, DNS, configured identity
surfaces, app-owned secret materialization/requirements, backup registrations,
and integrations while leaving centrally managed persistence in place:

```nix
repo.groundwaterLogger.enable = false;
repo.bonsai.enable = false;
repo.kiwix.enable = false;
repo.prowlarr.enable = false;
repo.qbittorrent.enable = false;
repo.radarr.enable = false;
repo.seerr.enable = false;
repo.sonarr.enable = false;
services.mail-archive-ui.enable = false;
```

Seerr already defaults to disabled. Offline Media uses
`offlineMedia.enable = false` in `vars.nix`; its cleanup unit revokes generated
Syncthing runtime configuration without deleting persisted application data.
Do not remove application paths from the central impermanence inventory merely
because an app is disabled. After changing imports or flags, run a guarded test
deploy before switching. Kanidm automatic deletion is intentionally disabled,
so identity objects provisioned by an earlier generation may remain inert until
an administrator explicitly retires them; the Homepage admin guide documents
that separate cleanup workflow.

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
- Reconcile Jellyfin OIDC and Quick Connect: `sudo systemctl start jellyfin-oidc-bootstrap-v1.service`
- SMART sweep: `sudo systemctl start storage-smart-short.service`
- Local encrypted backup repository: `/mnt/data/backups/kopia`
- Manual external USB media root for operators: `/mnt/external-usb/`

## Nix Store Capacity Garbage Collection

`nixhomeserver-nix-gc.timer` checks the Nix store hourly. It starts collection
when `/nix/store` reaches 90% of `system.nixStoreMaxSizeGiB` or when the
filesystem containing the store reaches 90% usage. The shared maintenance lock
prevents it from overlapping Nix store optimisation.

`system.nixGcRetentionDays` defaults to 45. The collector passes that value to
`nix-collect-garbage --delete-older-than`, which deletes profile generations
older than the retention period before collecting all unreachable store paths.
The active generation is retained, but deleted generations can no longer be
used for rollback. Unreachable paths themselves are not filtered by age.

Every check emits a structured `nix_store_gc_check` journal event containing
the measured store bytes, exact filesystem used/total bytes, threshold,
decision, and trigger reason. A pressured check that cannot obtain the shared
maintenance lock emits `nix_store_gc_deferred`; the next hourly run checks
again. Collection adds `nix_store_gc_recheck`, `nix_store_gc_started`, and
`nix_store_gc_completed`; completion records before/after sizes and freed
bytes. Failures emit `nix_store_gc_failed` and use the normal systemd failure
alert path. Collector failures include the final 8 KiB of diagnostic output as
base64 in `collector_output_base64`; decode it with
`jq -r .collector_output_base64 | base64 -d`.

```bash
systemctl status nixhomeserver-nix-gc.timer
journalctl -u nixhomeserver-nix-gc.service --output=cat
sudo systemctl start nixhomeserver-nix-gc.service
```

`/mnt/data` is the configured data root for both storage profiles. On
`zfs-mirror` it is a ZFS pool mountpoint; on `single-disk-ext4` it is a normal
directory on the root filesystem.

## App Hostnames

Immich uses separate private and public hostnames on purpose. Show evaluated
URLs for a site with `nix run .#show-config-summary -- --host <host>`.

- Private Immich app: `https://<photos-domain>`
- Public Immich share links: `https://<share-photos-domain>`
- Authenticated Filestash browser UI: `https://<files-domain>/`
- LAN-only direct SFTP: `sftp://<username>@<server-lan-host>:<filesSftp-port>/`
- Private Vaultwarden: `https://<passwords-domain>`
- Local Kopia backup management UI: `https://<kopia-domain>/`

Use the private photos hostname for the owner's normal Immich login on LAN or
NetBird. Use the public share hostname only for public album or photo links sent
to other people.

### Jellyfin login paths

Jellyfin keeps its existing accounts authoritative, so watch history, personal
preferences, administrator state, and repository-managed library policies stay
attached to the same exact username.

1. In a browser, choose **Sign in with Kanidm**. The confidential `jellyfin-web`
   client permits only members of `jellyfin-users`, and the plugin matches the
   validated `preferred_username` to an existing Jellyfin account. It does not
   create users or apply role mappings.
2. On a TV or native app, initiate ordinary Jellyfin Quick Connect. Authorize
   the six-digit code from an existing Jellyfin browser session or open
   `https://videos.<domain>/sso/OIDC/QuickConnect/kanidm` and sign in to Kanidm.
3. If a client cannot use either path, use the native username/password
   fallback. List available usernames with `sudo jellyfin-initial-credential`,
   retrieve one with `sudo jellyfin-initial-credential USERNAME`, then change it
   after the first login.

The root-only password handoff files live under
`/var/lib/jellyfin/.nixos-managed/initial-credentials/`; reconciliation never
overwrites a password after its durable initialization marker is recorded.
Native password authentication is intentionally enabled for client
compatibility.

Jellyfin OIDC is pinned to locally built `jellyfin-plugin-oidc` 1.0.8.0 with
automatic plugin updates disabled. Its immutable assemblies are read-only bound
into Jellyfin from the Nix store. The provider uses
`https://videos.<domain>` only for OIDC redirects; Jellyfin has no global
published-server URL override, so LAN discovery continues advertising its
direct address on TCP 8096 after a UDP 7359 discovery response.

Useful diagnostics:

```bash
sudo systemctl status jellyfin.service jellyfin-oidc-bootstrap-v1.service --no-pager
sudo journalctl -u jellyfin.service -u jellyfin-oidc-bootstrap-v1.service --since today
curl -fsS https://videos.<domain>/QuickConnect/Enabled
curl -fsS https://videos.<domain>/sso/OIDC/Providers
sudo stat -c '%U:%G %a %n' /var/lib/jellyfin/plugins/configurations/Jellyfin.Plugin.OIDC.xml
```

The bootstrap journal deliberately omits API keys, tokens, client secrets, and
complete provider JSON. A malformed managed branding marker makes
reconciliation fail closed instead of overwriting unrelated administrator
branding.

To roll back, use the guarded deployment helper to select the previous NixOS
generation. The plugin bind mount then disappears. The persistent CSS hides the
manual web form only while the plugin adds the
`nixhomeserver-oidc-ready` root class, so a missing or rolled-back plugin
automatically exposes the normal password login again.

Use the files hostname for browser access. For large transfers, use the
dedicated OpenSSH SFTP endpoint on the configured `filesSftp` port over LAN.

Use the passwords hostname only on LAN or NetBird paths. The canonical operator
workflow for invites, break-glass local admin handling, and the standard
credential-item pattern lives in [Vaultwarden Guide](./vaultwarden.md).

Use the kopia hostname for local Kopia backup management. Browser access is gated by
Kanidm through OAuth2 Proxy and requires membership in the fixed `backup-admin`
group. Repository browsing is a separate permission granted by the fixed
`backup-storage-users` group. Backup admins inherit storage membership;
users listed only in `backupAccess.storageUsers` never receive Kopia admin access.
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

1. Set `offsiteBackup.enable = true` and set `offsiteBackup.email` in `vars.nix`.
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
`usb-access`, `files-shared-users`, or `backup-storage-users` only adds a view to an
existing workspace and does not independently grant Filestash login.
- Filestash opens a single normal-user source, `Files`, rooted at the user's SFTP chroot.
- Direct SFTP opens the same personal root at `sftp://<username>@server.internal:<filesSftp-port>/`, currently port `2222`, and authenticates with the user's SSH key. Grant `files-sftp-users` for direct-only access; browser users receive the same chroot because Filestash itself uses SFTP as its backend.
- Direct SFTP password and keyboard-interactive login are disabled. Eligible
users add a device public key from Homepage's SFTP setup page; the root-owned
files under `/persist/appdata/files-sftp-authorized-keys/<username>` are the
administrator recovery/audit surface, not something users edit directly.
- Port `22` is reserved for normal SSH administration and does not expose an SFTP subsystem.
- Users in `files-shared-users` also see `_Shared` at the top of that root.
- Users in `usb-access` also see `_USB`, backed by `/mnt/external-usb`. USB filesystems are mounted manually by an operator under that root.
- Users in `backup-storage-users` also see read-only `_Backups`, backed by
`/mnt/data/backups`. Members of `backup-admin` inherit this storage group.
- GID `2005` is the fixed on-disk identity of `backup-storage-users`. It is
  intentionally derived outside `vars.nix`; changing it requires a deliberate
  ownership and ACL migration.
- `_Shared` is a delete-protected shared view. Reads, writes, edits, and same-folder renames affect the real shared storage immediately; deletes through `_Shared` should fail. Admin deletes are done directly against the real shared path.

Useful file-access checks:

```bash
kanidm group get files-personal-users
kanidm group get files-sftp-users
kanidm group get files-shared-users
kanidm group get usb-access
kanidm group get backup-admin
kanidm group get backup-storage-users

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

### Automatic DVD ISO conversion

Every personal file root and the shared file root contain an `_ISO` directory.
Only ISOs placed in `_Shared/_ISO/_DVDs` are watched; personal `_ISO` folders
are storage only. An unchanged `.iso` is picked up after approximately one
minute and converted serially into the shared Jellyfin `_Movies` or `_Shows`
library with the balanced H.264/AAC-plus-original-audio profile.

The converter uses the ISO label for its initial media name and performs a
conservative TVmaze lookup for series and episode names. If metadata is
unavailable or the match is weak, conversion continues with safe names derived
from the ISO and DVD title numbers. Name TV images descriptively, for example
`The_Wire_S03_Disc_2.iso`, to improve automatic season, disc, and metadata
matching.

If one title accounts for at least 85% of the substantial runtime, only that
feature is converted. Otherwise every title of at least five minutes is
converted, excluding an obvious play-all duplicate. Completed source ISOs are
preserved in `_Shared/_ISO/_DVDs/_Processed`. After three failed attempts an ISO
is preserved in `_Failed` beside an `.error.txt` file.

Useful checks and controls:

```bash
systemctl status mkvmaker-import.timer mkvmaker-import.service
journalctl -u mkvmaker-import.service
sudo systemctl start mkvmaker-import.service
```

The queue and detailed HandBrake job logs live under `/var/lib/mkvmaker`.
Change `repo.mkvmaker.dominantTitleRatio`, `minimumTitleSeconds`, `audioProfile`,
or `videoPreset` declaratively if the defaults need adjustment.

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

The documented day-2 validation path runs resource-intensive checks on the
remote server. The local wrapper still needs `nix` for its lightweight flake and
target validation:

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
refuses untracked files that have not been reviewed, and stages the current repo
archive on that host. By default, all Nix evaluation, builds, activation, and
validation happen on the server, so the server also carries the resulting
`/nix/store` churn.

Run deploys from a real Git checkout. A copied directory or source ZIP is
rejected because it has no trustworthy tracked-file manifest; broadly archiving
such a tree could otherwise include ignored plaintext secrets, dependency
caches, or other host-local files in the build host's Nix store.

The test action checks free space on both the build host and target, builds and
copies the closure without activating it, then activates that exact closure
through the guarded target-side test unit without changing the boot default. It
then checks failed systemd units, public routes, and the authenticated Homepage
canary when that module is enabled. Only after every gate passes does it record
a root-only stamp containing the exact repository hash and NixOS closure. That
closure is also kept alive with a dedicated GC root.

Only switch after the guarded test path passes.

```bash
./scripts/deploy.sh --action switch
```

The switch action does not rebuild a possibly different result. It refuses to
continue if any archived repository content changed after the passing test,
reactivates the exact stamped closure, repeats the health gates, and only then
makes that closure the boot default. If you edit, stage, or remove a file after
`--action test`, run the test action again before switching.

Deploys are serialized with a per-host lock. A failed transaction restores both
the previous live generation and previous boot profile immediately. `SIGHUP`,
`SIGINT`, and `SIGTERM` trigger that same immediate recovery before the deploy
process exits. Building and copying happen before the rollback timer is armed
and do not mutate the live generation. The later activation atomically verifies
the transaction owner and recovery barriers as it starts; recovery stops that
unique target-side unit and refuses to mutate generations unless it can prove
the activation is no longer running. A target-side timer remains armed during
activation as a backstop for an abruptly killed process or lost SSH session,
and is cancelled only after the transaction completes. If an immediate rollback
itself fails, leave the timer and lock in place and inspect them instead of
starting a competing deploy:

```bash
sudo systemctl list-timers 'nixhomeserver-deploy-*'
sudo systemctl status 'nixhomeserver-deploy-rollback-*'
```

A completed target-side rollback retains a `recovery-complete` barrier under
`/run/lock/nixhomeserver-deploy-<host>/` so a stalled executor cannot resume and
commit stale work. If that executor resumes, it repeats recovery, cancels the
finished timer, and removes the barrier before exiting; otherwise the ordinary
stale-lock expiry removes a successful barrier. A failed delayed rollback writes
`recovery-failed` instead, and stale-lock expiry deliberately refuses to remove
it. Inspect the rollback service and restore a known-good live and boot
generation before manually clearing that failed-recovery lock.

For the slower full validation gate:

```bash
./scripts/deploy.sh --action test --debug
```

`--debug` keeps the transactional deploy ordering but adds the full repository
validation gate before rebuilding. Use it for broad changes or suspicious
failures; routine deploys can use the focused fast path.

The regular deploy path stays intentionally focused. It evaluates the target,
checks build and target capacity, uses the build allocation selected in
`vars.nix`, and runs the runtime health gates described above.

## Build Allocation

Set `system.buildMode` in `vars.nix` to choose where guarded test deployments
build:

| Value | Workstation slots | Server slots | Cores requested per job |
| --- | ---: | ---: | ---: |
| `"local"` | all available (`auto`) | 0 | all available (`0`) |
| `"remote"` | 0 | all available (`auto`) | all available (`0`) |
| `"balanced"` | 2 | 2 | 1 |
| `"maximum-effort"` | all available (`auto`) | all available | all available (`0`) |

The deployed server limit is written through the native
`nix.settings.max-jobs` NixOS option. In `local` mode the server daemon remains
build-capable so a later mode change cannot deadlock, but the deploy omits it
from the builders list and therefore sends it no build work. For `balanced` and
`maximum-effort`, the workstation coordinates a native Nix distributed build
and registers the target server as an `ssh-ng` builder. The server's processor
count and advertised Nix system features are detected over the same SSH
connection used by the guarded deploy.

Because the workstation's multi-user Nix daemon opens the builder connection as
root, combined modes require a passphrase-free private key file in the
workstation user's effective SSH `IdentityFile` list. Its public key must match
`identity.sshPublicKey` in `vars.nix`. The deploy helper passes that exact
identity path to Nix and pins the server's Ed25519 host key after retrieving it
through the already-authenticated operator SSH connection. Agent-only or
passphrase-protected identities cannot be used by the daemon; the helper fails
before building with an actionable diagnostic instead of silently falling back
to one host.

`balanced` sets Nix's advisory `cores = 1` hint as well as limiting each host to
two simultaneous jobs. Nixpkgs builders that honor `NIX_BUILD_CORES` therefore
stay near two busy cores per host; derivations that ignore the hint may still
use more CPU.

Preview a configured allocation without building:

```bash
DEPLOY_DRY_RUN=1 ./scripts/deploy.sh --action test
```

Use `--build-mode <value>` for a one-shot override. The older
`--build-locally` flag remains an alias for `--build-mode local`.

## Fast Remote Deploy

With `system.buildMode = "remote"`, run:

```bash
./scripts/deploy.sh
```

This resolves the SSH target from `vars.localAdminUser` and `vars.serverLanIP`,
stages the current repo archive, runs the build/copy-only `nixos-rebuild build`,
and activates the returned closure through the guarded target-side test unit. It
intentionally skips the full repository and flake-check suite, but it still
evaluates the host, checks capacity, verifies failed units and public routes,
runs the authenticated canary when enabled, and records the exact passing
source/closure pair.

Use `--action switch` only after the test path passes without subsequent repo
changes and you want to commit that exact tested closure as the boot default:

```bash
./scripts/deploy.sh --action switch
```

Use `--build-locally` when you intentionally want a one-shot workstation-only
build and then activate the evaluated target over SSH:

```bash
./scripts/deploy.sh --build-locally --action test
```

## Local Attic Build Cache

The optional Attic module is enabled by default and listens only on
`127.0.0.1:8080`. It is not opened in the firewall or published through Caddy.
The server's Nix daemon uses the public `nixhomeserver` cache at that loopback
endpoint, while a root-only Attic client token permits the store watcher to
upload newly built paths. Attic's default upstream filter avoids duplicating
paths already signed by `cache.nixos.org`.

On first activation, `attic-cache-bootstrap.service` creates or reconciles the
cache, sets a six-month retention period, learns the cache signing public key,
and restarts the Nix daemon only when that key changes. The client token lives
under `/run`; Attic's database and cache live under `/var/lib/atticd`.
Impermanence retains that directory across root rollback and module removal,
but Kopia deliberately excludes it because all cached content is reproducible.

Check the service chain and cache:

```bash
systemctl status atticd.service attic-cache-bootstrap.service attic-watch-store.service
sudo env XDG_CONFIG_HOME=/run/attic-client attic cache info nixhomeserver
curl --fail http://127.0.0.1:8080/nixhomeserver/nix-cache-info
journalctl -u attic-watch-store.service -n 100 --no-pager
sudo du -sh /var/lib/atticd/storage
```

To stop caching without deleting retained cache data, set:

```nix
repo.attic.enable = false;
```

The watcher only sees builds that complete in the server's Nix store. Local
workstation builds are not uploaded to this loopback-only cache.

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
