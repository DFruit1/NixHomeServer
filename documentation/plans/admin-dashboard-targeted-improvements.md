# Proposal: Admin Dashboard + Targeted Server Feature Improvements

Status: draft proposal (no implementation yet)
Scope: actual NixOS server features. All items are admin-only surfaces
in the homepage app, exposed through a new **Admin Dashboard** page that is
deliberately separate from the existing `/admins` command-reference page.

## New surface: Admin Dashboard

Add a new homepage route, e.g. `/admin-dashboard` (or `/dashboard`), admin-only,
that hosts live, actionable widgets for the items below. It is distinct from the
existing `/admins` page, which remains a static command reference / runbook.
The dashboard talks to the server through the same pattern already used for
Build Mode, Power Schedule, Offline Media, SFTP keys: small sudo-gated helper
scripts invoked by the homepage service, with results rendered as cards.

Design constraints carried over from the existing homepage:
- Admin group gate (reuse `adminUsers`/admin groups; no new auth system).
- Every mutating action is a button with confirmation + toast, never a raw
  command the user must copy.
- Read-only first: where an action is destructive, ship the read-only view
  first and gate the action behind an explicit confirmation + audit log.
- Each widget degrades gracefully when its backing service/app is disabled
  (follow the `lib.optionals`/`enabled` pattern used for service cards).

## Excluded (per owner)

- Idea 14 (user/group management console) — attempted before, too fragile;
  stays CLI/Kanidm.
- Idea 15 (app account reconciliation buttons) — already exists in the media
  manager app.
- Ideas 16, 24-27, 30, 32 — not in scope for this proposal.

---

## 1. Per-app disk attribution dashboard

**What:** A widget listing, per enabled app, its state roots and data-pool
datasets with current size and 7-day growth, sorted by size, with a "top
consumers" view and drill-down to path level (reusing the existing
`pathInventories`/`pathRows` metadata).

**Why:** Space pressure is the most common operational surprise; today the only
tools are `df`, `ncdu`, and threshold alerts with no breakdown. Attribution
lets an operator see *which* app grew before it becomes an incident.

**Scope/effort:** Medium. Needs a sudo helper that runs `du`/`zfs list` over a
curated allow-list of roots (never arbitrary paths), caches results, and
rate-limits. Frontend is a table + sparkline. Reuse `vars.usersRoot`,
`vars.sharedRoot`, `/persist/appdata/*`, data pool datasets.

**Risks:** `du` over large trees can be expensive; run on a timer and read a
cached JSON file rather than on page load. Must not traverse secrets or
arbitrary user input.

## 2. Orphan-state cleanup action (not just report)

**What:** The `orphan-state-report` timer already writes
`/persist/appdata/backup-metadata/metadata/orphan-state.json` with candidate
paths/datasets and sizes. Add a dashboard panel that renders those candidates
with sizes and a per-item "review & delete" flow requiring confirmation and
recording an audit entry. Automatic deletion stays off.

**Why:** Preserved state accumulates (mail-archive/workspaces/upload-staging
datasets, archived dirs) and is never reclaimed because deletion is deliberately
manual — but "manual" currently means "SSH and rm", which is error-prone.

**Scope/effort:** Medium. Backend: extend the report to include a stable id and
a deletion-safe classification; add a sudo helper that deletes only allow-listed
candidate paths. Frontend: checklist + confirm modal + result toast.

**Risks:** Deletion is irreversible; helper must re-validate the candidate
against the report file at execution time and refuse anything not listed. Keep
`automaticDeletion: false` invariant.

## 3. Image/media deduplication report (read-only)

**What:** A scheduled, read-only scan (`jdupes`/`rmlint`) over `_Videos`,
`_Music`, `_Audiobooks`, `_Books` producing a report of duplicate groups with
sizes and suggested (not executed) removals. Surface in dashboard as
"potential reclaimable space" with a copyable cleanup script the operator runs
manually.

**Why:** Media libraries accumulate duplicates from downloads/re-encodes; a
report-only pass is safe and high value, while auto-deletion is not.

**Scope/effort:** Medium. Run via timer at low priority; write JSON report.
Never delete automatically.

**Risks:** False positives across legitimate hardlinks; report only.

## 4. ZFS snapshot retention tuning UI

**What:** Panel showing, per opted-in dataset: snapshot count, newest snapshot
age, and pool health (reusing `zfs-snapshot-health` output). Actions:
"snapshot now" (one ZFS snapshot of a chosen dataset) and a read-only view of
retention. No automatic policy changes from the UI.

**Why:** Snapshots are created automatically but visibility is CLI-only; an
operator about to do something risky wants a one-click "snapshot now" without
SSH.

**Scope/effort:** Small-medium. Sudo helper wrapping `zfs snapshot` for an
allow-listed dataset set; read cached health JSON.

**Risks:** Must restrict dataset names to the configured opt-in set; no
arbitrary dataset arguments.

## 5. Nix store "what's keeping this alive"

**What:** When capacity GC runs (or on demand), capture the top retained
generations and the largest paths with their GC roots into a JSON report. Dashboard
shows them with "delete old generation" as a copyable command (not a button,
since profile deletion is consequential and rare).

**Why:** Capacity GC can't reclaim what's referenced; today the operator has
no visibility into *why* the store is large.

**Scope/effort:** Small. Wrap existing `nix-store --gc --print-roots` /
`nix-env --list-generations` in a helper; output JSON. Keep actions as
copyable commands, not buttons.

**Risks:** Low. Read-only.

## 6. Centralized log search in homepage

**What:** A page with unit picker, time range, and grep filter that runs
`journalctl -u <unit> --since ... -g <pattern>` via a sudo helper and renders
capped output (e.g. last 500 lines / 1 MB). Presets for "failed units",
"warnings this boot".

**Why:** Log inspection is the most frequent operational task and is entirely
CLI today (`journalctl -fu ...` in adminGuide). This is the single biggest
day-to-day time saver.

**Scope/effort:** Medium. Helper must validate unit names against an allow-list
(enabled units) and cap output. No log mutation.

**Risks:** Output can be huge; enforce hard caps and pagination. Avoid leaking
secrets that may appear in logs (redact known secret env names? at least cap).

## 7. Per-service "recent errors" canary

**What:** Extend the service-access canary so that, in addition to HTTP/login
checks, each enabled app's journal is scanned for error-level entries in the
last hour; surface a badge per service and an aggregate "N services have recent
errors" indicator.

**Why:** A green HTTP check doesn't mean the app is healthy; silent errors
(e.g. failed background jobs) go unnoticed until someone checks logs.

**Scope/effort:** Small. Reuse existing canary runner; add a journal scan step
with an allow-list of units and error patterns. Surface via existing canary
panel.

**Risks:** False positives from noisy apps; make thresholds configurable per
app and start with a conservative set.

## 8. Structured app log retention parity

**What:** Audit which enabled apps write to files vs journald and add
`services.logrotate` rules + tmpfiles aging for any app currently missing
rotation (Immich, Audiobookshelf, Calibre-Web, FreshRSS, mail-archive-ui,
others). Document the full list in operations.md.

**Why:** Only Jellyfin/Kavita/Paperless/Filestash are covered today; a chatty
app can fill the system SSD. Hygiene should be uniform and module-owned so
removing a module removes its rules.

**Scope/effort:** Small. Nix-only changes per module; no UI. Add a validation
check that every enabled app with a file log dir has a rotation rule.

**Risks:** Low. Ensure rotations use `copytruncate` where apps hold file
handles.

## 9. Backup freshness widget

**What:** Dashboard card showing: last successful Kopia snapshot time + age,
last logical-backup generation + age, offsite (rclone/Mega) sync status + age,
and ZFS snapshot health. Color-coded by staleness against configured max ages.

**Why:** Backup health is currently verified via `systemctl list-timers` and
manual inspection; a single at-a-glance card is the core of "are my backups
OK?".

**Scope/effort:** Small. Read existing status files/timers; no new backend
beyond a small aggregator helper.

**Risks:** Low. Read-only.

## 10. Restore drill / "test restore"

**What:** A scheduled (monthly) job that restores a single small, known file
from Kopia into a scratch dir and verifies its checksum; plus a dashboard button
to run it on demand. Alert on failure.

**Why:** Backups exist but restore is never exercised; the first time you
discover a broken backup should not be during an incident.

**Scope/effort:** Medium. Needs a Kopia restore helper with a fixed test
object, checksum verification, cleanup. Careful not to overwrite real data
(scratch dir only).

**Risks:** Must use a dedicated scratch path and never touch production paths;
treat any restore failure as an alert.

## 11. Database dump verification panel

**What:** Surface `backup-prepare` results: which SQLite/PostgreSQL dumps ran,
their sizes, integrity-check outcomes, and age. Alert if a configured dump is
missing or stale.

**Why:** `backup-prepare` already does integrity checks internally but the
results aren't visible; a silent dump failure leaves you thinking backups are
good.

**Scope/effort:** Small. Have `backup-prepare` write a small status JSON
(additive); dashboard reads it.

**Risks:** Low. Additive to existing service.

## 12. Per-app "what's backed up" manifest

**What:** A generated dashboard page listing, per enabled app: its state roots,
whether each is in Kopia snapshot roots, whether it has logical dumps, and which
paths are marked rebuildable/excluded. Answers "if this app dies, what do I
lose?".

**Why:** Backup coverage is declared across modules (`appStateEntries`,
`criticalPaths`, `rebuildableSnapshotPaths`, `snapshotRoots`) but never
presented as a single view; coverage gaps are invisible until an incident.

**Scope/effort:** Small-medium. Generate a JSON manifest at eval/build time
from the already-declared options; render as a table.

**Risks:** Low. Read-only, build-time data.

## 13. Offsite sync status & manual trigger UI

**What:** Card showing rclone/Mega sync: last run time, result, bytes
transferred, errors, and a "sync now" button with progress. Replaces the
copy-paste `systemctl start rclone-mega-kopia-sync.service` command.

**Why:** Offsite sync is the disaster-recovery backstop and is currently
operated via CLI; visibility + one-click trigger removes friction and makes
failures obvious.

**Scope/effort:** Small. Read journal/timer status; trigger via existing unit.
Add progress parsing if rclone outputs stats.

**Risks:** Low. Trigger is already a safe oneshot.

## 17. Build mode toggle + deploy status

**What:** Extend the existing Build Mode card into a deploy-status card: current
build mode, last deploy generation, pending source changes (git status summary),
and "test deploy / switch" actions with confirmation dialogs. Keep the actual
deploy invocation as a sudo helper (already pattern).

**Why:** Deploy is the riskiest routine operation and is currently a set of
copy-paste commands in adminGuide; a guided, confirmed flow reduces mistakes.

**Scope/effort:** Medium. Needs careful UX (two-step confirm, show diff
summary, block on dirty tree). Reuse `deploy.sh`.

**Risks:** Deploy has real blast radius; keep confirmations explicit and show
the exact command that will run before executing. Consider making "switch"
require typing the hostname.

## 19. SFTP key management: bulk revoke & expiry

**What:** Extend the existing SFTP key management UI with: list of keys with
last-used timestamp, "revoke all for user", and auto-expiry of keys unused for
N days (configurable), with a warning before expiry.

**Why:** Keys accumulate; unused keys are a latent access risk and manual
revocation is tedious.

**Scope/effort:** Medium. Needs last-used tracking (sshd logs or a small
access log), which is new state. Expiry should be opt-in with a grace period
and notification.

**Risks:** Tracking last-used requires parsing auth logs or instrumenting;
start with manual revoke-all and defer auto-expiry to a second pass.

## 20. Backup freshness (see 9) — *covered above.*

## 21. Homepage status board

**What:** A single aggregate page: green/yellow/red per enabled service
combining HTTP reachability, login flow, recent errors (idea 7), backup age
(idea 9), and disk pressure. One screen to answer "is everything OK?".

**Why:** Today status is spread across canary, monitoring alerts, and CLI;
operators want one glance.

**Scope/effort:** Medium. Aggregation layer over existing signals; no new
probes. Reuse canary results + status files.

**Risks:** Low. Read-only aggregation; avoid implying health where a signal is
missing (show "unknown", not green).

## 22. Canary coverage auto-suggest

**What:** A dashboard panel listing Caddy hosts that are enabled but have no
canary target or exemption, with the suggested exemption reason based on host
type (identity provider, gateway login, embedded editor, public share, API-only,
device-local). Links to the exemption config.

**Why:** The lean test fails on uncovered hosts, but discovering *which* and
*why* requires running the test; surfacing it in the dashboard shortens the
feedback loop when adding apps.

**Scope/effort:** Small. Parse the canary config + Caddy vhosts; read-only.

**Risks:** Low.

## 23. Alert routing preferences

**What:** Allow configuring per-severity and per-service routing of failure
alerts (which webhook/ntfy topic), plus a "mute for 1 hour" button with an
audit log. Today there is a single webhook URL and format.

**Why:** Alert fatigue: a single channel means either everything is noisy or
important things get buried; muting during maintenance is currently impossible
without editing config.

**Scope/effort:** Medium. Needs a small mutable config store (JSON) read by
the alert script, with validation. Mute state must be time-bounded and audited.

**Risks:** Alerting is safety-critical; changes must be reversible and never
silently drop critical alerts. Keep a hard floor: critical severity always
delivers to the primary channel.

## 28. Shared-folder quota/usage

**What:** Per-user and shared-root sizes for the files roots (`_Shared`,
personal roots, `_Backups` read-only view), with growth trends and a soft
warning when a user/root exceeds a configurable threshold.

**Why:** Files roots are the largest mutable data and the only place users can
fill the disk; no visibility today beyond aggregate capacity alerts.

**Scope/effort:** Small-medium. Reuse disk attribution helper (idea 1) with
per-user breakdown; thresholds in vars.

**Risks:** Must not expose other users' data to non-admins; admin-only.

## 29. USB drive attach/detach events

**What:** Dashboard notification/event list when a drive appears or disappears
under `_USB`, with mount health, filesystem type, and free space. Optional
"unmount safely" button.

**Why:** USB drives are hot-plugged and their state is opaque today; a failed
mount or full drive is discovered only when a user complains.

**Scope/effort:** Small-medium. Use udev/systemd mount events or periodic
polling; render recent events.

**Risks:** "Unmount safely" must be careful not to unmount in-use drives; show
open-file warnings.

## 31. Secret rotation checklist

**What:** A dashboard page listing age secrets with "last rotated" (derived
from git history of the encrypted file / a small metadata file), rotation
cadence, and a per-secret rotation runbook link/command. Highlights overdue
secrets.

**Why:** Secret rotation is entirely manual and undocumented in the UI; an
overdue highlight prevents "set and forget" credentials.

**Scope/effort:** Small. Read-only metadata + git log; no secret values ever
displayed.

**Risks:** Must never display or handle plaintext secrets; only metadata and
commands. Deriving "last rotated" from git blame of `.age` files is an
approximation; allow manual override in a metadata file.

---

## Cross-cutting implementation notes

- **New route:** add `custom_apps/node/apps/homepage/src/routes/admin-dashboard/index.tsx`
  (or `/dashboard`) gated to admin users, separate from `/admins`.
- **Backend pattern:** follow `BuildModeCard` / `PowerScheduleCard` / Offline
  Media: Nix-defined sudo helpers exposed via env vars, results rendered as
  cards. Each widget is independently enabled based on backing services.
- **Caching:** expensive scans (du, journal, dedup) run on timers and write
  JSON; the UI reads cached files. Never run heavy work on page load.
- **Audit log:** every mutating action appends a structured entry (timestamp,
  actor, action, target, result) to a root-owned log surfaced in the dashboard.
- **Validation:** add lean-tier checks for helper allow-lists and for log
  rotation coverage (idea 8).
- **Canary:** the new page host is already covered by the homepage canary;
  no new canary target needed, but widgets that call new endpoints should be
  exercised by the canary where they have HTTP surfaces.

## Suggested first slice

1. Idea 9 (backup freshness) + 11 (dump verification) — small, read-only,
   highest trust value.
2. Idea 6 (log search) + 7 (recent-errors canary) — biggest daily time saver.
3. Idea 1 (disk attribution) + 28 (shared-folder usage) — inform capacity
   decisions.
4. Idea 21 (status board) once 6/7/9 exist — pure aggregation.

Everything else follows once the widget framework and helper pattern are proven.
