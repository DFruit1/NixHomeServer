#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"
cd "$TESTS_REPO_ROOT"

ensure_tools jq nix rg

integration_json="$(nix eval --json '.#nixosConfigurations.server.config' --apply '
  cfg: {
    snapshotScript = cfg.systemd.services.mail-archive-ui-paperless-db-snapshot.script;
    snapshotTimer = cfg.systemd.timers.mail-archive-ui-paperless-db-snapshot.timerConfig;
    mailWants = cfg.systemd.services.mail-archive-ui.wants;
    taskRequires = cfg.systemd.services.mail-archive-paperless-tasks.requires;
    dbPath = cfg.services.mail-archive-ui.paperlessDatabasePath;
    groups = cfg.users.users.mail-archive-ui.extraGroups;
  }
')"

jq -e '
  .dbPath == "/run/mail-archive-ui/paperless-db-snapshot.sqlite3"
  and (.mailWants | index("mail-archive-ui-paperless-db-snapshot.service") != null)
  and (.taskRequires | index("mail-archive-ui-paperless-db-snapshot.service") != null)
  and (.snapshotScript | contains(".backup"))
  and (.snapshotScript | contains("PRAGMA quick_check"))
  and (.snapshotTimer.OnUnitActiveSec == "2m")
  and ((.groups // []) | index("paperless") == null)
' <<<"$integration_json" >/dev/null || {
  echo "❌ Mail Archive does not use a consistent, least-privilege Paperless database snapshot." >&2
  exit 1
}

require_fixed custom_apps/rust/apps/mail-archive-ui/src/paperless.rs \
  'Paperless duplicate-check snapshot is unavailable' \
  "Paperless publication must fail closed when duplicate detection is unavailable"
require_fixed custom_apps/rust/apps/mail-archive-ui/src/paperless.rs \
  'acquire_paperless_handoff_lock' \
  "concurrent Paperless publications must be serialized per attachment"
require_fixed custom_apps/rust/apps/mail-archive-ui/src/tests.rs \
  'paperless_handoff_fails_closed_when_duplicate_snapshot_is_unavailable' \
  "Paperless snapshot failure must have a Rust regression test"
require_fixed custom_apps/rust/apps/mail-archive-ui/src/tests.rs \
  'paperless_handoff_lock_prevents_concurrent_duplicate_publication' \
  "Paperless concurrent publication must have a Rust regression test"

echo "✅ Mail Archive Paperless handoff snapshot, locking, and fail-closed checks passed."
