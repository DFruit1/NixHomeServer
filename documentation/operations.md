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
- Guarded switch: `./scripts/deploy-with-validation.sh --target "dsaw@server" --build-host "dsaw@server" --action switch`
- Optional local-build compatibility path: `./scripts/deploy-with-validation.sh --target "dsaw@server" --local-build --action test`
- Server-side secrets: `ssh dsaw@server 'cd /path/to/repo && ./scripts/generate-all-secrets.sh'`
- Runtime readiness: `sudo ./scripts/check-runtime-readiness.sh --profile manual`
- Strict runtime readiness: `sudo ./scripts/check-runtime-readiness.sh --profile deploy`
- Periodic report refresh: `sudo ./scripts/generate-system-health-report.sh`
- Backup target selection: `manage-backup-target list` then `sudo manage-backup-target select ...`

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

For server-side secrets generation after local staging or edits:

```bash
ssh dsaw@server 'cd /path/to/repo && ./scripts/generate-all-secrets.sh'
```

## Runtime Validation

```bash
sudo ./scripts/check-runtime-readiness.sh --profile manual
sudo ./scripts/check-runtime-readiness.sh --profile deploy
sudo ./scripts/generate-system-health-report.sh
```

Use `--profile manual` for survivability checks and `--profile deploy` for strict deploy gating.

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
