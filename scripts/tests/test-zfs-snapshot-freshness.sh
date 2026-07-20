#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"
cd "$TESTS_REPO_ROOT"
ensure_tools bash jq nix rg

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
health_script="$tmpdir/zfs-snapshot-health"
output="$tmpdir/output"

nix eval --raw '.#nixosConfigurations.server.config.systemd.services.zfs-snapshot-health.script' \
  >"$health_script"
chmod +x "$health_script"

cat >"$tmpdir/zpool" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "${TEST_POOL_HEALTH:-ONLINE}"
EOF

cat >"$tmpdir/zfs" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$1 $2" in
  "get -H")
    if [[ "$*" == *"com.sun:auto-snapshot"* ]]; then
      printf 'data\ttrue\n'
    else
      printf '%s\n' "${TEST_DATASET_CREATED:?}"
    fi
    ;;
  "list -H")
    if [[ -n "${TEST_NEWEST_EPOCH:-}" ]]; then
      printf '%s\tdata@zfs-auto-snap_hourly-fixture\n' "$TEST_NEWEST_EPOCH"
    fi
    ;;
  *)
    echo "Unexpected zfs invocation: $*" >&2
    exit 2
    ;;
esac
EOF
chmod +x "$tmpdir/zpool" "$tmpdir/zfs"

now="$(date +%s)"
PATH="$tmpdir:$PATH" \
  TEST_DATASET_CREATED="$((now - 86400))" \
  TEST_NEWEST_EPOCH="$((now - 60))" \
  bash "$health_script" >"$output"
jq -e '.health == "ONLINE" and .datasets[0].state == "fresh" and .datasets[0].fresh' \
  "$output" >/dev/null

if PATH="$tmpdir:$PATH" \
  TEST_DATASET_CREATED="$((now - 86400))" \
  TEST_NEWEST_EPOCH="$((now - 20000))" \
  bash "$health_script" >"$output" 2>&1; then
  echo "Stale automatic ZFS snapshot unexpectedly passed health validation." >&2
  exit 1
fi
jq -e '.datasets[0].state == "stale" and (.datasets[0].fresh | not)' "$output" >/dev/null

if PATH="$tmpdir:$PATH" \
  TEST_DATASET_CREATED="$((now - 86400))" \
  TEST_NEWEST_EPOCH="" \
  bash "$health_script" >"$output" 2>&1; then
  echo "Old dataset with no automatic snapshot unexpectedly passed health validation." >&2
  exit 1
fi
jq -e '.datasets[0].state == "missing"' "$output" >/dev/null

PATH="$tmpdir:$PATH" \
  TEST_DATASET_CREATED="$((now - 60))" \
  TEST_NEWEST_EPOCH="" \
  bash "$health_script" >"$output"
jq -e '.datasets[0].state == "initializing" and .datasets[0].fresh' "$output" >/dev/null

if PATH="$tmpdir:$PATH" \
  TEST_DATASET_CREATED="$((now + 60))" \
  TEST_NEWEST_EPOCH="" \
  bash "$health_script" >"$output" 2>&1; then
  echo "Future-created dataset unexpectedly passed the snapshot initialization grace period." >&2
  exit 1
fi
jq -e '.datasets[0].state == "missing" and .datasets[0].ageSeconds < 0 and (.datasets[0].fresh | not)' \
  "$output" >/dev/null

echo "✅ ZFS automatic snapshot freshness regression tests passed."
