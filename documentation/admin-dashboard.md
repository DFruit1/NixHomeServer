# Admin dashboard

`/admin-dashboard` is the operator health surface of the Homepage app. It is
deliberately separate from `/admins`, which stays a static command reference.

Everything on this page is **read-only**. The browser never receives root
privileges, credentials or arbitrary command output; it renders a small cache
that a root timer writes.

## Data path

1. `homepage-admin-dashboard-status.service` (root, oneshot) runs
   `scripts/helpers/homepage-admin-dashboard-status.sh` on boot and every ten
   minutes via `homepage-admin-dashboard-status.timer`.
2. The helper collects measurements only — timestamps, ages, sizes, counts — from
   existing status files:
   - Kopia snapshot marker: `${backupRoot}/.kopia-last-snapshot-success.json`
   - Kopia deep-verification marker: `/persist/appdata/kopia/last-verify-success.json`
   - Current logical backup generation: `/persist/appdata/backup-metadata/current`
     (`metadata/manifest.json` and the additive `metadata/dumps.json`)
   - Offsite mirror status: `/var/lib/rclone/last-mega-sync-status.json`, only
     when the MEGA mirror is enabled
   - ZFS pool health and automatic snapshot ages, only when the data pool uses ZFS
3. The cache is written atomically to `/run/homepage-admin-dashboard/status.json`
   (root:homepage, `0640`); the directory is `0750 root:homepage`.
4. `GET /api/admin-dashboard` re-validates that file, applies the ok/warn/critical
   thresholds and returns widget rows. `homepage-admin-dashboard-status.service`
   is not involved in serving requests.

Missing or corrupt sources degrade one widget section at a time — a widget never
reports "healthy" for a signal it has no data for.

The cache ages too. Cached ages are observations frozen at `generatedAt`, so the
API advances every one of them by the time elapsed since collection, states the
cache age in a `Status cache` row on each widget, and degrades the widgets when
the timer stops refreshing the report: three missed ten-minute runs (`warn`) and
twelve, two hours (`critical`). A stale cache is never rendered as a healthy
one, and the page shows a notice naming the cache age.

## Widgets (first slice)

- **Backup freshness** — Kopia snapshot, Kopia deep verification, logical backup
  generation, offsite mirror and ZFS snapshots, each with its age and limit.
  Thresholds reuse the existing options: `repo.backups.kopiaSnapshotHealthMaxAgeSeconds`,
  `repo.storage.snapshotHealth.maxAgeSeconds` and
  `repo.backups.offsiteMirrorMaxAgeSeconds` (default 26h). Deep verification is a
  weekly job, so it allows one missed window (8 days).
- **Dump verification** — per-dump kind, size, integrity result and age written by
  `backup-prepare` into `metadata/dumps.json`, compared against the configured
  dump list. A configured dump that is missing from the generation, or whose
  integrity result is not `ok`, is reported as critical. A dump older than the
  logical generation's configured limit (`repo.backups.kopiaSnapshotHealthMaxAgeSeconds`)
  is critical too, and approaching it is a warning, so idea 11's stale-dump alert
  is covered. Generations published before this file existed show a warning
  instead of a false pass.
- A per-dump record the collector cannot read — malformed JSON or missing
  `expected`/`dumps` arrays — is reported as `verificationMetadata: "invalid"`
  and rendered as a warning, never as an empty configured dump set. An unreadable
  entry inside `expected` is counted and warned about rather than skipped, and a
  legitimately empty configured set is shown as `Unknown`, not verified.

A widget whose backing service is disabled is omitted rather than rendered green.

## Adding a widget

1. Add a raw measurement section to the collector (no severity decisions there).
2. Map it to a widget in `custom_apps/node/apps/homepage/src/server/adminDashboard.ts`
   and cover the mapping with a case in `src/server/__tests__/adminDashboard.test.ts`.
3. Register the widget's title and description in
   `src/components/dashboard/registry.tsx`; the route renders any widget the API
   returns, so later slices do not have to touch the layout.
4. Load the frontend-design skill and check the rendered page at desktop and
   phone widths.

## Mutating actions

The cache and API are read-only by design. Any future mutating widget must:

- go through a Nix-defined, allow-listed helper exposed as an environment
  variable (the Build mode / Power schedule pattern), never a free-form command;
- confirm the action in the UI before calling it;
- append a structured entry (timestamp, actor, action, target, result) to a
  root-owned audit log surfaced in the dashboard.

Credentials, token values and secret material are never displayed or passed
through this page.

## Related

- Proposal: `documentation/plans/admin-dashboard-targeted-improvements.md`
- Backup preparation: `modules/Core_Modules/backups/default.nix`
- Kopia snapshot/verification jobs: `modules/Core_Modules/kopia/service.nix`
- Offsite mirror: `modules/Core_Modules/rclone/service.nix`
