# Operations

Use this as the maintained day-2 runbook for validation, guarded deploys, rollback, runtime readiness, system health monitoring, and first-response troubleshooting.

Normal day-2 operations no longer require local Nix on the desktop. The
documented path is to stage the repo archive over SSH and let the remote server
perform evaluation, builds, activation, and secrets generation. Blank-machine
bootstrap remains the installer-side exception.

## Common Commands

- Remote validation gate: `./scripts/validate-repo-remote.sh --host "dsaw@server" --full`
- Local validation gate: `nix flake check --no-build` then `scripts/validate-repo.sh`
- Flake-inclusive local gate: `scripts/validate-repo.sh --run-flake-check`
- Exhaustive local gate: `scripts/validate-repo.sh --full`
- Guarded deploy: `./scripts/deploy-with-validation.sh --target "dsaw@server" --build-host "dsaw@server" --action test`
- Full guarded deploy: `./scripts/deploy-with-validation.sh --target "dsaw@server" --build-host "dsaw@server" --action test --full-check`
- Guarded switch: `./scripts/deploy-with-validation.sh --target "dsaw@server" --build-host "dsaw@server" --action switch`
- Optional local-build compatibility path: `./scripts/deploy-with-validation.sh --target "dsaw@server" --local-build --action test`
- Server-side secrets: `ssh dsaw@server 'cd /path/to/repo && ./scripts/generate-all-secrets.sh'`
- Runtime readiness: `sudo ./scripts/check-runtime-readiness.sh --profile manual`
- Strict runtime readiness: `sudo ./scripts/check-runtime-readiness.sh --profile deploy`
- Deep runtime readiness: `sudo ./scripts/check-runtime-readiness.sh --profile deploy --deep`
- Access canary bootstrap: `sudo ./scripts/bootstrap-access-canaries.sh`
- Periodic report refresh: `sudo ./scripts/generate-system-health-report.sh`
- Backup target selection: `manage-backup-target list` then `sudo manage-backup-target select ...`

## App Hostnames

Immich uses separate private and public hostnames on purpose:

- Private Immich app: `https://photos.sydneybasiniot.org`
- Public Immich share links: `https://sharephotos.sydneybasiniot.org`
- Public Copyparty uploader: `https://uploads.sydneybasiniot.org/`
- Authenticated FileBrowser Quantum UI and WebDAV: `https://files.sydneybasiniot.org/`
- Private Vaultwarden: `https://passwords.sydneybasiniot.org`

Use `photos.sydneybasiniot.org` for the owner's normal Immich login on LAN or
NetBird. Use `sharephotos.sydneybasiniot.org` only for public album or photo
links sent to other people.

Use `uploads.sydneybasiniot.org` for large uploads into the authenticated
user's personal `uploads` folder. Use `files.sydneybasiniot.org` for browsing,
moving, smaller uploads, and WebDAV access.

Long Copyparty browser uploads are most reliable when the client reaches
`uploads.sydneybasiniot.org` over LAN or NetBird split DNS instead of the
Cloudflare tunnel. For very large directory trees, archive the tree first or
upload in smaller batches; hundreds of thousands of tiny files create hundreds
of thousands of upload handshakes, so a flaky network period is much more
visible. The server defaults the browser uploader to one chunk connection and
8 MiB chunks, with 16 MiB as the UI maximum, so slow paths stay below proxy
request timeouts. If a transfer has already started with larger client-side
settings, lower the Copyparty upload chunk size in the browser settings before
resuming.

Use `passwords.sydneybasiniot.org` only on LAN or NetBird paths. The canonical operator workflow for invites, break-glass local admin handling, and the standard credential-item pattern lives in [Vaultwarden Guide](./vaultwarden.md).

Copyparty upload troubleshooting note:
- if the fix depends on declarative user or group state, a service restart alone is not enough
- use a guarded deploy or switch so the local `copyparty` account and unit runtime groups are converged
- after deploy, verify the upload bridge directly:

```bash
id copyparty
getent group users
sudo -u copyparty sh -lc 'probe=/mnt/data/users/dsaw/uploads/.write-probe && : >"$probe" && rm -f "$probe"'
journalctl -u copyparty -n 100 --no-pager
```

FileBrowser Quantum WebDAV roots:

- Personal source: `https://files.sydneybasiniot.org/dav/Personal/`
- Shared source: `https://files.sydneybasiniot.org/dav/Shared/`

Kavita-managed book roots are now aligned to the same simpler taxonomy used by
the rest of the stack: `ebooks`, `comics`, and `manga`. The old `other`
category is no longer part of the managed layout.

`photoshare.sydneybasiniot.org` is not a valid hostname in this config and
should not be used.

Immich sharing flow:

1. Open Immich at `https://photos.sydneybasiniot.org`
2. Create an album or photo share link
3. Send the generated `https://sharephotos.sydneybasiniot.org/...` URL to recipients

## Mail Archive Operations

The mail archive UI stays private at `https://emails.sydneybasiniot.org`. `mail-archive-users` grants browser access to the UI only. The archived sync payload stays in each user's hidden `.internal-sync` tree, while the user-visible mailbox mirror is exposed as hard-linked `.eml` files under that user's `emails/` root.

Normal checks and manual actions:

```bash
systemctl status mail-archive-ui mail-archive-oauth2-proxy mail-archive-sync.timer
sudo systemctl start mail-archive-sync.service
curl -fsS http://127.0.0.1:9011/healthz | jq .
```

Use the dashboard `Sync now` and `Reindex` actions when you need to repair or refresh one mailbox without waiting for the timer. Use `https://emails.sydneybasiniot.org/attachments` to search indexed document attachments, select individual/page/all matching files, and download them as a ZIP for manual upload through the document-management UI.

Attachment downloads are backed by content-addressed blobs in each mailbox's
hidden `.internal-sync` tree. ZIP downloads include a `manifest.json` that maps
each file back to its mailbox, message, MIME type, size, and SHA-256. Inline
artifacts and `ripmime` body fragments such as `textfile0` are hidden by default
in the UI and can be included with the body-parts filter. ZIP contents are laid
out as `<mailbox>/<yyyy-mm-dd> - <subject>/<filename>`, and duplicate filenames
are suffixed as `file (1).ext`.

To verify attachment backup readiness manually:

```bash
sudo -u mail-archive-ui env \
  MAIL_ARCHIVE_UI_DATA_DIR=/persist/appdata/mail-archive-ui \
  MAIL_ARCHIVE_UI_STORE_ROOT=/mnt/data/users \
  MAIL_ARCHIVE_UI_ACCOUNT_STATE_ROOT=/persist/appdata/mail-archive-ui/accounts \
  MAIL_ARCHIVE_UI_RUNTIME_DIR=/run/mail-archive-ui \
  MAIL_ARCHIVE_UI_LOCK_DIR=/persist/appdata/mail-archive-ui/locks \
  mail-archive-ui verify-attachments --repair --report /tmp/mail-archive-attachments.json
```

The system-state backup preparation runs this verifier with repair enabled and
stores `mail-archive-attachments.json` in the backup metadata.

## Validation Gate

The documented day-2 validation path runs on the remote server and does not need
local Nix:

```bash
./scripts/validate-repo-remote.sh --host "dsaw@server" --full
```

That stages the current repo archive on the server and runs the full repository
gate there. A fresh remote validation stamp is reused by guarded deploys to
skip repeated repo checks for unchanged archive content.

Optional local validation remains available when you intentionally want the
desktop to evaluate or build:

Run the flake check first.

```bash
nix flake check --no-build
```

Run the repo gate second.

```bash
scripts/validate-repo.sh
```

Default local `scripts/validate-repo.sh` behavior:
- runs the fixed shell suite through `scripts/tests/run-script-tests.sh`
- does not rerun `nix flake check --no-build`
- does not run Rust derivation checks

To include flake checks in the same pass:

```bash
scripts/validate-repo.sh --run-flake-check
```

For the exhaustive local gate:

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
./scripts/deploy-with-validation.sh \
  --target "dsaw@server" \
  --build-host "dsaw@server" \
  --action test
```

That path stages the current repo archive on the build host and keeps all Nix
evaluation, builds, activation, and validation on the server. The server also
carries the resulting `/nix/store` churn.

Use `--local-build` only when you intentionally want the workstation to build
the same target system directly.

```bash
./scripts/deploy-with-validation.sh \
  --target "dsaw@server" \
  --local-build \
  --action test \
  --hostname server
```

Only switch after the guarded test path passes.

```bash
./scripts/deploy-with-validation.sh \
  --target "dsaw@server" \
  --build-host "dsaw@server" \
  --action switch
```

For the slower, browser-backed runtime gate:

```bash
./scripts/deploy-with-validation.sh \
  --target "dsaw@server" \
  --build-host "dsaw@server" \
  --action test \
  --full-check
```

`--full-check` keeps the normal guarded deploy ordering, but upgrades the
runtime step from `--profile deploy` to `--profile deploy --deep`. Use it when
you want authenticated app-access verification through the synthetic Kanidm
canaries. Do not use it for routine timer-based monitoring.

The regular guarded deploy path stays intentionally quick. It covers units,
storage, backups, local upstream HTTP checks, local unauthenticated auth-edge
checks through Caddy/TLS, and the expected access matrix from config. It does
not run browser logins, negative auth-path checks, or the full synthetic-canary
loop.

For server-side secrets generation after local staging or edits:

```bash
ssh dsaw@server 'cd /path/to/repo && ./scripts/generate-all-secrets.sh'
```

## Runtime Validation

```bash
sudo ./scripts/check-runtime-readiness.sh --profile manual
sudo ./scripts/check-runtime-readiness.sh --profile deploy
sudo ./scripts/check-runtime-readiness.sh --profile deploy --deep
sudo ./scripts/generate-system-health-report.sh
```

Use `--profile manual` for survivability checks and `--profile deploy` for strict deploy gating.
Use `--deep` only for explicit operator checks or `deploy-with-validation.sh --full-check`.

Private-host troubleshooting note:
- if `https://passwords.sydneybasiniot.org/` does not resolve from a workstation browser, do not assume Vaultwarden is down
- verify the private edge directly with:

```bash
curl -kI --resolve passwords.sydneybasiniot.org:443:192.168.8.12 https://passwords.sydneybasiniot.org/
```

- if the forced-resolution check succeeds while normal resolution fails, troubleshoot workstation DNS, LAN resolver reachability, or NetBird instead of changing Vaultwarden exposure

Deep runtime access checks require the canary bootstrap state on the server:

```bash
sudo ./scripts/bootstrap-access-canaries.sh
```

That helper:
- creates short-lived Kanidm reset links for the synthetic canary accounts
- sets their password from the root-only agenix secrets under `/run/agenix/`
- warms expected first-login app state
- writes `/var/lib/runtime-access-canaries/bootstrap-state.json`

The periodic system-health report stays on the shallow runtime path and does not
run browser logins.

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

## System Health Monitoring

The retained monitoring workflow is:
- `scripts/generate-system-health-report.sh`
- `scripts/check-runtime-readiness.sh`
- `scripts/helpers/send-storage-health-alert.sh`

The scheduled SMART jobs are now discovery sweeps:
- `storage-smart-short.timer`
- `storage-smart-long.timer`

Attached retired disks will keep appearing in monitoring and can still raise
alerts until they are physically detached from the server.

Use these checks first on the target host:

```bash
systemctl status system-health-report.timer
sudo cat /var/lib/system-health-monitoring/latest.json
sudo cat /var/lib/system-health-monitoring/latest.txt
```

If the persisted report looks stale, inspect the timer and service logs:

```bash
journalctl -u system-health-report -n 100 --no-pager
```
