# Operations

Use this as the maintained day-2 operations guide for validation, guarded deploys, rollback, service health, SMART monitoring, and first-response troubleshooting.

Normal day-2 operations no longer require local Nix on the desktop. The
documented path is to stage the repo archive over SSH and let the remote server
perform evaluation, builds, activation, and secrets generation. Blank-machine
bootstrap remains the installer-side exception.

## Common Commands

- Remote validation gate: `./scripts/deploy.sh --debug --action test`
- Local validation gate: `nix flake check --no-build` then `scripts/validate-repo.sh`
- Flake-inclusive local gate: `scripts/validate-repo.sh --run-flake-check`
- Full local gate: `scripts/validate-repo.sh --full`
- Guarded deploy: `./scripts/deploy.sh --action test`
- Full guarded deploy: `./scripts/deploy.sh --action test --debug`
- Guarded switch: `./scripts/deploy.sh --action switch`
- Local-build deploy: `./scripts/deploy.sh --build-locally --action test`
- Server-side secrets: `ssh <admin>@<hostname> 'cd /path/to/repo && ./scripts/generate-all-secrets.sh'`
- Service health: `sudo systemctl --failed --no-pager`
- SMART sweep: `sudo systemctl start storage-smart-short.service`
- Backup target selection: `manage-backup-target list` then `sudo manage-backup-target select ...`

## App Hostnames

Immich uses separate private and public hostnames on purpose. Show evaluated
URLs for a site with `nix run .#show-config-summary -- --host <host>`.

- Private Immich app: `https://<photos-domain>`
- Public Immich share links: `https://<share-photos-domain>`
- Public Copyparty uploader: `https://<uploads-domain>/`
- Authenticated Filestash UI and SFTP: `https://<files-domain>/`
- Private Vaultwarden: `https://<passwords-domain>`

Use the private photos hostname for the owner's normal Immich login on LAN or
NetBird. Use the public share hostname only for public album or photo links sent
to other people.

Use the uploads hostname for large uploads into the authenticated user's
personal `uploads` folder. Use the files hostname for browsing, moving, smaller
uploads, and SFTP access.

Long Copyparty browser uploads are most reliable when the client reaches
the uploads hostname over LAN or NetBird split DNS instead of the
Cloudflare tunnel. For very large directory trees, archive the tree first or
upload in smaller batches; hundreds of thousands of tiny files create hundreds
of thousands of upload handshakes, so a flaky network period is much more
visible. The server defaults the browser uploader to one chunk connection and
8 MiB chunks, with 16 MiB as the UI maximum, so slow paths stay below proxy
request timeouts. If a transfer has already started with larger client-side
settings, lower the Copyparty upload chunk size in the browser settings before
resuming.

Use the passwords hostname only on LAN or NetBird paths. The canonical operator
workflow for invites, break-glass local admin handling, and the standard
credential-item pattern lives in [Vaultwarden Guide](./vaultwarden.md).

Copyparty upload troubleshooting note:
- if the fix depends on declarative user or group state, a service restart alone is not enough
- use a guarded deploy or switch so the local `copyparty` account and unit runtime groups are converged
- after deploy, verify the upload bridge directly:

```bash
id copyparty
getent group users
sudo -u copyparty sh -lc 'probe=/mnt/data/users/<user>/uploads/.write-probe && : >"$probe" && rm -f "$probe"'
journalctl -u copyparty -n 100 --no-pager
```

Filestash  roots:

- Personal source: `https://<files-domain>/dav/Personal/`
- Shared source: `https://<files-domain>/dav/Shared/`

Kavita-managed book roots are now aligned to the same simpler taxonomy used by
the rest of the stack: `ebooks`, `comics`, and `manga`. The old `other`
category is no longer part of the managed layout.

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
hard-linked `.eml` files under that user's `emails/` root.

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

The system-state backup preparation runs this verifier with repair enabled and
stores `mail-archive-attachments.json` in the backup metadata. The same backup
preparation also stores `mail-archive-roots.tsv` and a
`dumps/mail-archive-ui.sqlite3` SQLite backup, which includes attachment catalog
state and Paperless handoff records. Mail payload bytes remain on the mirrored
`/mnt/data/users` pool rather than in the Restic `system-state` snapshot.

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
- `kanidm-admin-clippy`
- `kanidm-admin-test`
- `mail-archive-ui-test`

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

## Upload Quarantine Review

Copyparty uploads land in locked staging first. The upload processor scans staged
files with ClamAV, performs VirusTotal hash lookups only for high-risk
extensions, then promotes clean files or moves risky files to quarantine.

Backup policy for the upload flow:

- promoted user uploads live under `/mnt/data/users/<user>/files`
- pending uploads live under `/mnt/data/upload-staging`
- quarantined uploads live under `/mnt/data/quarantine/uploads`
- upload processor state lives under `/var/lib/upload-processor`

The `system-state` Restic backup records upload-flow metadata, shallow staging
and quarantine inventories, and `dumps/upload-processor-state.sqlite3`. It does
not copy data-pool payload bytes; the mirrored ZFS pool remains the recovery
boundary for uploaded file contents.

Admins can review quarantined uploads through the Filestash
`Quarantine` source. Manual VirusTotal file uploads, if needed, are an admin
action against files already in quarantine; the server does not automatically
upload file bytes to VirusTotal.

Storage monitoring now discovers disks live at runtime:
- `system` is the static `vars.mainDisk`
- `dataN` are the current live `data` pool members discovered from ZFS
- `otherN` are every other attached non-system disk, including retired disks that are still physically attached

## Backup Target Selection

```bash
manage-backup-target list
sudo manage-backup-target select <device-or-label>
sudo manage-backup-target mount
sudo manage-backup-target status
sudo manage-backup-target unmount
```

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
