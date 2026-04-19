# Restore and Recovery

Use this when the backup disk is connected and you need to stage a restore
without overwriting the live system blindly.

## Scope

Current first-pass protected paths:

- `/var/lib/acme`
- `/var/lib/kanidm`
- `/var/lib/snapraid`
- `/etc/ssh`
- `/mnt/data/appdata`

Current intentional exclusions:

- `/mnt/data/media`
- `/mnt/data/workspaces`
- general data-drive content outside explicitly added future critical paths

This backup scaffold is for system and app state first. It improves recovery on
the server, but it is not an off-host backup strategy by itself.

## Before you restore

1. Provision the base machine and place the agenix age key at `/etc/agenix/age.key`.
2. Ensure the repo is present on the machine.
3. Rebuild the base system so the normal services, secrets, and restore tooling exist.
4. Connect the dedicated backup disk and confirm `backupDisk` still points at the intended `/dev/disk/by-id` entry in `vars.nix`.
5. Rebuild again so the disk is mounted at `/mnt/backup`.

The backup disk is part of the active configuration now. The cold-storage disk remains manual-only and should stay outside restore automation unless you intentionally mount it with `scripts/cold-storage.sh`.

## Staged restore

Never restore directly into live system paths first.

List snapshots and restore into an empty staging directory:

```bash
./scripts/restore-state.sh --target /tmp/server-state-restore
```

Select a specific snapshot if needed:

```bash
./scripts/restore-state.sh \
  --target /tmp/server-state-restore \
  --snapshot <snapshot-id>
```

Restore only a subset when needed:

```bash
./scripts/restore-state.sh \
  --target /tmp/server-state-restore \
  --include /var/lib/kanidm \
  --include /etc/ssh
```

## Restore order

When moving restored state back into live paths, use this order:

1. `/var/lib/acme`
2. `/var/lib/kanidm`
3. `/var/lib/snapraid`
4. `/etc/ssh`
5. `/mnt/data/appdata`

Apply each step deliberately:

- stop the affected service if needed
- copy the staged data into place
- confirm ownership and permissions
- restart the affected service before moving on when that reduces ambiguity

## After restore

1. Rebuild the system:

```bash
nix flake check --no-build
scripts/check-repo.sh
```

2. Run the post-restore readiness checks:

```bash
./scripts/runtime-readiness.sh
```

3. Run the broader validation pass if the restore touched auth, routing, or app state:

```bash
./scripts/runtime-readiness.sh
```

Then work through the short manual checklist in [Runtime Validation](./runtime-validation.md).

## Notes

- The restore helper is intentionally non-destructive. It restores only into a
  staging directory.
- Future critical data-drive coverage should be added only in
  `modules/backup/default.nix`.
- If the backup disk is not mounted at `/mnt/backup`, restic backup jobs are
  expected to stay disabled or fail fast rather than silently writing to the
  root filesystem.
- Runtime readiness now includes SMART degradation warnings, so review those
  before resuming normal write workloads on restored storage.
