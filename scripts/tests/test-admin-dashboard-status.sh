#!/usr/bin/env bash
# Regression tests for the admin-dashboard backup status collector.
#
# The collector is the only writer of the cached JSON the /admin-dashboard route
# renders. These tests pin its contract: raw measurements in, never policy
# decisions (the route maps ages to ok/warn/critical), and graceful degradation
# when a source is missing, empty or malformed.

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"
cd "$TESTS_REPO_ROOT"
ensure_tools bash jq mktemp readlink stat

collector="scripts/helpers/homepage-admin-dashboard-status.sh"
now=1800000000
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

kopia_marker="$tmpdir/kopia-snapshot.json"
verify_marker="$tmpdir/kopia-verify.json"
staging="$tmpdir/staging"
current_link="$staging/current"
offsite_file="$tmpdir/mega-status.json"
output="$tmpdir/status.json"

mkdir -p "$staging/generations/20261024T031500-77/metadata" "$staging/generations/20261024T031500-77/dumps"

iso() { date --utc --date="@$1" --iso-8601=seconds; }

write_marker() {
  local path="$1" completed_at="$2"
  jq -n --arg completedAt "$completed_at" '{schemaVersion:1,completedAt:$completedAt}' >"$path"
}

write_generation() {
  local dumps="${1:-yes}"
  local generation_dir="$staging/generations/20261024T031500-77"
  mkdir -p "$generation_dir/metadata" "$generation_dir/dumps"
  ln -sfn "generations/20261024T031500-77" "$current_link"
  jq -n --arg createdAt "$(iso $((now - 3600)))" '
    {schemaVersion:1, createdAt:$createdAt, host:"test", sqliteDumps:1, postgresqlDumps:["paperless"]}
  ' >"$generation_dir/metadata/manifest.json"
  printf '{}' >"$generation_dir/dumps/kanidm.sqlite"
  if [[ "$dumps" == yes ]]; then
    jq -n '
      {
        schemaVersion:1,
        createdAt:"2026-10-24T03:15:00Z",
        expected:[{name:"kanidm.sqlite",kind:"sqlite"},{name:"paperless.dump",kind:"postgresql"}],
        dumps:[
          {name:"kanidm.sqlite",kind:"sqlite",bytes:4194304,sha256:("a" * 64),integrityCheck:"ok",createdAt:"2026-10-24T03:15:00Z"},
          {name:"paperless.dump",kind:"postgresql",bytes:8388608,sha256:("b" * 64),integrityCheck:"ok",createdAt:"2026-10-24T03:15:00Z"}
        ]
      }
    ' >"$generation_dir/metadata/dumps.json"
  fi
}

run_collector() {
  HOME_ADMIN_DASHBOARD_NOW_EPOCH="" \
    bash "$collector" \
      --output "$output" \
      --now "$now" \
      --kopia-snapshot-marker "$kopia_marker" \
      --kopia-snapshot-max-age-seconds 129600 \
      --kopia-verify-marker "$verify_marker" \
      --kopia-verify-max-age-seconds 691200 \
      --logical-current-link "$current_link" \
      --logical-max-age-seconds 129600 \
      "$@"
}

reset_fixtures() {
  rm -rf "${staging:?}/generations" "$current_link" "$offsite_file"
  mkdir -p "$staging/generations/20261024T031500-77/metadata"
}

# 1. Healthy: every configured source is reported with raw ages.
reset_fixtures
write_generation
write_marker "$kopia_marker" "$(iso $((now - 60)))"
write_marker "$verify_marker" "$(iso $((now - 86400)))"
run_collector --offsite-status-file "$offsite_file" 2>"$tmpdir/err"
jq -e '.schemaVersion == 1' "$output" >/dev/null
jq -e --arg now "$(iso "$now")" '.generatedAt == $now' "$output" >/dev/null
jq -e '.kopiaSnapshot.ageSeconds == 60 and .kopiaSnapshot.maxAgeSeconds == 129600' "$output" >/dev/null
jq -e '.kopiaVerify.ageSeconds == 86400' "$output" >/dev/null
jq -e '.logicalBackup.generation == "20261024T031500-77"' "$output" >/dev/null
jq -e '.logicalBackup.ageSeconds == 3600' "$output" >/dev/null
jq -e '.logicalBackup.dumps | length == 2' "$output" >/dev/null
jq -e '.logicalBackup.expected | length == 2' "$output" >/dev/null
jq -e '.offsiteSync.error == "missing"' "$output" >/dev/null
jq -e '.zfsSnapshots.disabled == true' "$output" >/dev/null
[[ "$(stat -c '%a' "$output")" == "640" ]] || { echo "Cached status must be group-readable 0640" >&2; exit 1; }
if compgen -G "$tmpdir/.status.json.*" >/dev/null; then
  echo "Collector left a temporary status file behind" >&2
  exit 1
fi

# 2. Stale measurements are reported as raw ages, not pre-judged states.
write_marker "$kopia_marker" "$(iso $((now - 259200)))"
run_collector
jq -e '.kopiaSnapshot.ageSeconds == 259200' "$output" >/dev/null
jq -e '.kopiaSnapshot | has("fresh") | not' "$output" >/dev/null

# 3. Missing and malformed markers degrade without failing the whole report.
rm -f "$kopia_marker"
printf 'not-json' >"$verify_marker"
run_collector
jq -e '.kopiaSnapshot.error == "missing"' "$output" >/dev/null
jq -e '.kopiaVerify.error == "invalid"' "$output" >/dev/null
jq -e '.logicalBackup.generation == "20261024T031500-77"' "$output" >/dev/null

# 4. A broken current-generation link reports a missing logical backup.
write_marker "$kopia_marker" "$(iso $((now - 60)))"
write_marker "$verify_marker" "$(iso $((now - 60)))"
rm -f "$current_link"
run_collector
jq -e '.logicalBackup.error == "missing"' "$output" >/dev/null

# 5. Generations published before per-dump reporting simply omit the detail.
reset_fixtures
write_generation no
run_collector
jq -e '.logicalBackup | has("dumps") | not' "$output" >/dev/null
jq -e '.logicalBackup | has("expected") | not' "$output" >/dev/null

# 6. An existing offsite status is passed through with its own state and age.
jq -n --arg timestamp "$(iso $((now - 7200)))" '
  {schemaVersion:1,event:"mega_kopia_sync_state",timestamp:$timestamp,attemptId:"a1",
   state:"success",failureClass:"none",reason:"mirror_verified",message:"MEGA mirror verified",
   retryable:false,operatorActionRequired:false,repositoryBytes:4096,limitBytes:8192}
' >"$offsite_file"
run_collector --offsite-status-file "$offsite_file" --offsite-max-age-seconds 93600
jq -e '.offsiteSync.state == "success" and .offsiteSync.ageSeconds == 7200' "$output" >/dev/null
jq -e '.offsiteSync.repositoryBytes == 4096 and .offsiteSync.limitBytes == 8192' "$output" >/dev/null
jq -e '.offsiteSync.reason == "mirror_verified"' "$output" >/dev/null

# 7. ZFS health is read from the pool, not assumed.
zfs_stub="$tmpdir/zfs-stub"
zpool_stub="$tmpdir/zpool-stub"
cat >"$zpool_stub" <<'STUB'
#!/usr/bin/env bash
printf 'ONLINE\n'
STUB
cat >"$zfs_stub" <<STUB
#!/usr/bin/env bash
set -euo pipefail
case "\$*" in
  "get -H -o name,value -t filesystem -r com.sun:auto-snapshot tank") printf 'tank/core\ttrue\ntank/other\tfalse\n' ;;
  "get -H -o value mounted tank/core") printf 'yes\n' ;;
  "list -H -p -d 1 -t snapshot -o creation,name -s creation tank/core")
    printf '$((now - 1800))\ttank/core@zfs-auto-snap_hourly-1\n'
    ;;
  *) exit 2 ;;
esac
STUB
chmod +x "$zfs_stub" "$zpool_stub"
ZFS_BIN="$zfs_stub" ZPOOL_BIN="$zpool_stub" \
  run_collector --zfs-pool tank --zfs-max-age-seconds 172800
jq -e '.zfsSnapshots.pool == "tank" and .zfsSnapshots.health == "ONLINE"' "$output" >/dev/null
jq -e '.zfsSnapshots.managedDatasets == 1' "$output" >/dev/null
jq -e '.zfsSnapshots.staleDatasets == 0' "$output" >/dev/null
jq -e '.zfsSnapshots.newestAgeSeconds == 1800' "$output" >/dev/null

# 8. A dataset whose newest automatic snapshot is older than the limit is counted stale.
cat >"$zfs_stub" <<STUB
#!/usr/bin/env bash
set -euo pipefail
case "\$*" in
  "get -H -o name,value -t filesystem -r com.sun:auto-snapshot tank") printf 'tank/core\ttrue\n' ;;
  "get -H -o value mounted tank/core") printf 'yes\n' ;;
  "list -H -p -d 1 -t snapshot -o creation,name -s creation tank/core")
    printf '$((now - 400000))\ttank/core@zfs-auto-snap_daily-1\n'
    ;;
  *) exit 2 ;;
esac
STUB
chmod +x "$zfs_stub"
ZFS_BIN="$zfs_stub" ZPOOL_BIN="$zpool_stub" \
  run_collector --zfs-pool tank --zfs-max-age-seconds 172800
jq -e '.zfsSnapshots.staleDatasets == 1' "$output" >/dev/null

# 9. Unknown arguments are rejected instead of silently ignored.
if bash "$collector" --output "$output" --nonsense 2>"$tmpdir/err"; then
  echo "Collector accepted an unknown argument" >&2
  exit 1
fi
rg -q 'Unknown argument' "$tmpdir/err"

echo "✅ Admin dashboard status collector regression tests passed."
