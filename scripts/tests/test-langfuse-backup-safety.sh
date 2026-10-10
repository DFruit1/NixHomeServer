#!/usr/bin/env bash
#
# Offline regression for the Langfuse complete-backup contract (CI-LFBS-001 and
# CI-LFBS-002).
#
# It executes the *evaluated* backup-preparation shell. The script text is read
# out of the NixOS configuration and only store/tool paths and state roots are
# rewritten to a synthetic sandbox. No backup decision logic is reimplemented
# here: checksum recording, checksum verification, manifest writing, the
# current-generation symlink and retention all run exactly as production
# generates them.
#
# The sandbox supplies deterministic doubles for the external commands this
# workstation cannot run (the ClickHouse BACKUP client, runuser, pg_dump,
# pg_restore) and for cp(1), which is the copy-failure injection point. Every
# fixture is synthetic: no live credential, database or service is touched.

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"
cd "$TESTS_REPO_ROOT"
ensure_tools bash jq nix sha256sum cp rm mktemp flock date find sort cut install df mountpoint sqlite3

export NIXHOMESERVER_TEST_HOST="${NIXHOMESERVER_DEFAULT_HOST:-$(test_default_host)}"

facts="$(flake_eval_json '
  host = builtins.getEnv "NIXHOMESERVER_TEST_HOST";
  cfg = (builtins.getAttr host f.nixosConfigurations).config;
  langfuseState = builtins.head (builtins.filter (e: e.app == "langfuse") cfg.repo.backups.appStateEntries);
in {
  enabled = builtins.elem "langfuse" (builtins.getAttr host f.lib.nixhomeserverSettings).enabledApps;
  prepareScript = cfg.systemd.services.backup-prepare.script;
  clickhouseClient = "${toString cfg.services.clickhouse.package}/bin/clickhouse-client";
  sqliteSources = map (d: d.source) cfg.repo.backups.sqliteDumps;
  sqliteCount = builtins.length cfg.repo.backups.sqliteDumps;
  postgresqlDbs = map (d: d.database) cfg.repo.backups.postgresqlDumps;
  retained = cfg.repo.backups.retainedSuccessfulGenerations;
  rebuildable = cfg.repo.backups.rebuildableSnapshotPaths;
  policyEnabled = cfg.systemd.services ? kopia-policy-reconcile;
  policyScript = if cfg.systemd.services ? kopia-policy-reconcile then cfg.systemd.services.kopia-policy-reconcile.script else "";
  persistence = cfg.repo.impermanence.inventory.persistenceDirectories;
  stateNotes = langfuseState.notes;
  statePayloadRoots = langfuseState.payloadRoots;
}')"

if [[ "$(jq -r '.enabled' <<<"$facts")" != true ]]; then
  echo "Langfuse is disabled; the offline backup-safety fixtures need its preparation fragment."
  exit 0
fi

# --- evaluated coverage and policy assertions --------------------------------

invalid="$(jq -r '
  [
    (if (.rebuildable | index("var/lib/clickhouse")) != null then empty else "raw ClickHouse is no longer excluded" end),
    (if (.rebuildable | index("var/lib/langfuse/minio")) == null then empty else "MinIO events/media are still excluded from the snapshot" end),
    (if (.rebuildable | index("var/lib/atticd/storage")) != null then empty else "an unrelated rebuildable exclusion was dropped" end),
    (if .policyEnabled then empty else "the /persist policy reconcile service is missing" end),
    (if ((.policyEnabled | not) or (.policyScript | contains("--clear-ignore"))) then empty else "the /persist policy no longer starts from a clean ignore set" end),
    (if ((.policyEnabled | not) or (.policyScript | contains("var/lib/langfuse/minio") | not)) then empty else "the /persist policy still ignores MinIO" end),
    (if ((.policyEnabled | not) or (.policyScript | contains("--add-ignore=var/lib/clickhouse"))) then empty else "the /persist policy no longer ignores raw ClickHouse" end),
    (if ((.policyEnabled | not) or (.policyScript | contains("--add-ignore=var/lib/atticd/storage"))) then empty else "an unrelated /persist exclusion was dropped" end),
    (if (.persistence | index("/var/lib/langfuse")) != null then empty else "Langfuse state is no longer persisted" end),
    (if (.persistence | index("/var/lib/clickhouse")) != null then empty else "ClickHouse state is no longer persisted" end),
    (if (.persistence | index("/var/lib/redis-langfuse")) != null then empty else "the Langfuse queue state is no longer persisted" end),
    (if (.statePayloadRoots | index("/var/lib/redis-langfuse")) != null then empty else "the Langfuse backup payload roots lost the queue" end),
    (if (.stateNotes | test("Object storage")) then empty else "the Langfuse backup metadata no longer describes object storage" end),
    (if (.retained >= 2) then empty else "fewer than two complete generations are retained" end)
  ] | .[]
' <<<"$facts")"
if [[ -n "$invalid" ]]; then
  echo "❌ Langfuse backup coverage or /persist policy regressed:" >&2
  printf '   %s\n' "$invalid" >&2
  exit 1
fi

# --- sandbox -----------------------------------------------------------------

sandbox="$(mktemp -d "${TMPDIR:-/tmp}/nixhomeserver-langfuse-backup-safety.XXXXXX")"
trap 'rm -rf "$sandbox"' EXIT

real_cp="$(command -v cp)"
mkdir -p "$sandbox/bin" "$sandbox/logs" "$sandbox/staging/generations" \
  "$sandbox/run/lock" "$sandbox/var/lib/langfuse/clickhouse-backups"
archive_dir="$sandbox/var/lib/langfuse/clickhouse-backups"

# Prefix -> sandbox root. Every entry is a synthetic state root; nothing outside
# the sandbox is read or written by the executed preparation.
sandbox_prefixes=(
  "/run/lock|$sandbox/run/lock"
  "/run/postgresql|$sandbox/run/postgresql"
  "/run/langfuse|$sandbox/run/langfuse"
  "/persist/appdata/backup-metadata|$sandbox/staging"
  "/persist/appdata/mail-archive-ui|$sandbox/mail-archive-ui-src"
  "/var/lib/|$sandbox/var/lib/"
  "/mnt/data|$sandbox/mnt/data"
)

to_sandbox() {
  local path="$1" entry from to
  for entry in "${sandbox_prefixes[@]}"; do
    from="${entry%%|*}"
    to="${entry#*|}"
    if [[ "$path" == "$from"* ]]; then
      printf '%s%s\n' "$to" "${path#"$from"}"
      return 0
    fi
  done
  printf '%s\n' "$path"
}

# Rewrite the evaluated script in two passes, so an expanded sandbox path can
# never be re-matched by a later prefix.
rewrite_script() {
  local body="$1" entry from to token index=0
  for entry in "${sandbox_prefixes[@]}"; do
    from="${entry%%|*}"
    token="@LFBS_PATH_${index}@"
    body="${body//"$from"/$token}"
    index=$((index + 1))
  done
  body="${body//"$(jq -r '.clickhouseClient' <<<"$facts")"/@LFBS_CLICKHOUSE_CLIENT@}"
  index=0
  for entry in "${sandbox_prefixes[@]}"; do
    to="${entry#*|}"
    body="${body//"@LFBS_PATH_${index}@"/$to}"
    index=$((index + 1))
  done
  printf '%s\n' "${body//@LFBS_CLICKHOUSE_CLIENT@/$sandbox/bin/clickhouse-client}"
}

jq -r '.prepareScript' <<<"$facts" >"$sandbox/prepare.raw"
rewrite_script "$(cat "$sandbox/prepare.raw")" >"$sandbox/prepare.sh"
rm -f "$sandbox/prepare.raw"

# --- fixture sources ---------------------------------------------------------

while IFS= read -r source; do
  target="$(to_sandbox "$source")"
  mkdir -p "$(dirname "$target")"
  sqlite3 "$target" 'CREATE TABLE fixture (id INTEGER PRIMARY KEY, note TEXT);' >/dev/null
done < <(jq -r '.sqliteSources[]' <<<"$facts")

# --- tool doubles ------------------------------------------------------------

cat >"$sandbox/bin/runuser" <<'EOF'
#!/usr/bin/env bash
# The sandbox runs as a single unprivileged user, so drop "-u <user> --" and
# run the requested command directly.
while (($#)); do
  case "$1" in
    -u) shift 2 ;;
    --) shift; break ;;
    *) break ;;
  esac
done
exec "$@"
EOF

cat >"$sandbox/bin/pg_dump" <<'EOF'
#!/usr/bin/env bash
# Emit deterministic custom-format bytes for the requested database.
database=""
for argument in "$@"; do
  case "$argument" in
    --*) ;;
    *) database="$argument" ;;
  esac
done
printf 'PGDMP fixture dump for %s\n' "${database:-unknown}"
EOF

cat >"$sandbox/bin/pg_restore" <<'EOF'
#!/usr/bin/env bash
# Accept the fixture dump produced by the pg_dump double.
file=""
while (($#)); do
  case "$1" in
    --list) shift; file="${1:-}"; break ;;
    *) shift ;;
  esac
done
[[ -n "$file" && -s "$file" ]] || { echo "pg_restore: fixture dump is missing" >&2; exit 1; }
printf 'fixture table list\n'
EOF

cat >"$sandbox/bin/clickhouse-client" <<'EOF'
#!/usr/bin/env bash
# ClickHouse BACKUP client double. LFBS_CH_MODE selects the outcome:
#   ok                  write a real fixture archive
#   backup-fail         report failure and write nothing
#   no-archive          report success without producing the archive
#   empty-archive       produce a zero-length archive
#   unreadable-archive  produce an archive nobody can read
mode="${LFBS_CH_MODE:-ok}"
query=""
while (($#)); do
  case "$1" in
    --query) shift; query="${1:-}"; shift ;;
    *) shift ;;
  esac
done
pattern="Disk\('backups', '([^']+)'\)"
name=""
if [[ "$query" =~ $pattern ]]; then
  name="${BASH_REMATCH[1]}"
fi
[[ -n "$name" ]] || { echo "clickhouse-client double: no backup name in: $query" >&2; exit 2; }
archive="${LFBS_ARCHIVE_DIR:?LFBS_ARCHIVE_DIR is required}/$name"
case "$mode" in
  ok)
    printf 'fixture clickhouse archive %s\n' "$name" >"$archive"
    ;;
  backup-fail)
    echo "simulated ClickHouse BACKUP failure" >&2
    exit 1
    ;;
  no-archive)
    :
    ;;
  empty-archive)
    : >"$archive"
    ;;
  unreadable-archive)
    printf 'fixture clickhouse archive %s\n' "$name" >"$archive"
    chmod 000 "$archive"
    ;;
  *)
    echo "unknown LFBS_CH_MODE: $mode" >&2
    exit 2
    ;;
esac
EOF

cat >"$sandbox/bin/cp" <<'EOF'
#!/usr/bin/env bash
# cp(1) double used only to inject archive-copy failures. Copies that are not
# the Langfuse archive delegate to the workstation's own cp.
mode="${LFBS_CP_MODE:-ok}"
real_cp="${LFBS_REAL_CP:?LFBS_REAL_CP is required}"
destination="${!#}"
if [[ "$destination" != */dumps/langfuse-clickhouse.zip ]]; then
  exec "$real_cp" "$@"
fi
case "$mode" in
  ok)
    exec "$real_cp" "$@"
    ;;
  partial)
    # A copy that fails midway, leaving a partial attempt-local file behind.
    printf 'partial archive\n' >"$destination"
    echo "simulated partial archive copy failure" >&2
    exit 1
    ;;
  unreadable-dest)
    "$real_cp" "$@" || exit 1
    chmod 000 "$destination"
    ;;
  *)
    echo "unknown LFBS_CP_MODE: $mode" >&2
    exit 2
    ;;
esac
EOF
make_test_executable "$sandbox/bin/runuser" "$sandbox/bin/pg_dump" "$sandbox/bin/pg_restore" \
  "$sandbox/bin/clickhouse-client" "$sandbox/bin/cp"

# --- seeded complete generations --------------------------------------------

seed_generation() {
  local name="$1" mtime="$2" root="$sandbox/staging/generations/$1"
  mkdir -p "$root/dumps" "$root/metadata"
  printf 'fixture pg dump %s\n' "$name" >"$root/dumps/langfuse.pgdump"
  printf 'fixture clickhouse archive %s\n' "$name" >"$root/dumps/langfuse-clickhouse.zip"
  jq -n --arg name "$name" '{schemaVersion:1,host:"server",generation:$name}' >"$root/metadata/manifest.json"
  (
    cd "$root"
    sha256sum dumps/langfuse.pgdump dumps/langfuse-clickhouse.zip >metadata/SHA256SUMS
  )
  touch -d "$mtime" "$root"
}

generation_oldest="gen-1-20200101T000000-fixture"
generation_middle="gen-2-20210101T000000-fixture"
generation_newest="gen-3-20220101T000000-fixture"
seed_generation "$generation_oldest" "2020-01-01 00:00:00"
seed_generation "$generation_middle" "2021-01-01 00:00:00"
seed_generation "$generation_newest" "2022-01-01 00:00:00"
ln -s "generations/$generation_newest" "$sandbox/staging/current"

snapshot_state() {
  printf 'current=%s\n' "$(readlink "$sandbox/staging/current" 2>/dev/null || echo MISSING)"
  find "$sandbox/staging" -mindepth 1 -printf '%y %P\n' | LC_ALL=C sort
  find "$sandbox/staging" -type f -exec sha256sum {} + | sed "s|$sandbox/staging/||" | LC_ALL=C sort
}

run_case() {
  local name="$1" ch_mode="$2" cp_mode="$3"
  rm -rf "$sandbox/staging/generations"/.prepare.* 2>/dev/null || true
  set +e
  LFBS_CH_MODE="$ch_mode" \
    LFBS_CP_MODE="$cp_mode" \
    LFBS_ARCHIVE_DIR="$archive_dir" \
    LFBS_REAL_CP="$real_cp" \
    PATH="$sandbox/bin:$PATH" \
    bash "$sandbox/prepare.sh" >"$sandbox/logs/$name.log" 2>&1
  case_status=$?
  set -e
}

failures=0

expect_failure() {
  local name="$1" expected_message="$2"
  local log="$sandbox/logs/$name.log"
  if ((case_status == 0)); then
    echo "❌ [$name] preparation reported success; it must abort nonzero." >&2
    failures=$((failures + 1))
    return
  fi
  if ! grep -Fq "$expected_message" "$log"; then
    echo "❌ [$name] aborted without the expected diagnostic: $expected_message" >&2
    sed 's/^/   /' "$log" >&2
    failures=$((failures + 1))
    return
  fi
  snapshot_state >"$sandbox/logs/$name.after"
  if ! cmp -s "$sandbox/logs/seed.before" "$sandbox/logs/$name.after"; then
    echo "❌ [$name] changed the published generations, their checksums or the current symlink." >&2
    diff -u "$sandbox/logs/seed.before" "$sandbox/logs/$name.after" | sed 's/^/   /' >&2
    failures=$((failures + 1))
    return
  fi
  echo "  ✅ [$name] exit $case_status; prior generation, checksums and current symlink intact"
}

echo "▶ Langfuse backup failure safety"

snapshot_state >"$sandbox/logs/seed.before"

# CI-LFBS-002: a failed or partial ClickHouse archive must abort the whole
# preparation. The previously published generation, its checksums, the current
# symlink and the attempt-local work directory must all be unchanged.
run_case backup-fail backup-fail ok
expect_failure backup-fail \
  "Langfuse ClickHouse archive failed; aborting the backup preparation"

run_case copy-partial ok partial
expect_failure copy-partial \
  "Langfuse ClickHouse archive copy failed; aborting the backup preparation"

run_case archive-missing no-archive ok
expect_failure archive-missing \
  "Langfuse ClickHouse archive is missing or empty"

run_case archive-empty empty-archive ok
expect_failure archive-empty \
  "Langfuse ClickHouse archive is missing or empty"

run_case archive-unreadable unreadable-archive ok
expect_failure archive-unreadable \
  "Langfuse ClickHouse archive copy failed; aborting the backup preparation"

run_case checksum-failure ok unreadable-dest
expect_failure checksum-failure \
  "Langfuse ClickHouse archive checksum failed"

if ((failures > 0)); then
  echo "❌ $failures Langfuse backup-safety case(s) failed." >&2
  exit 1
fi

# Success control: a real fixture archive is copied, its checksum verifies, the
# central manifest and current symlink are published, and retention still prunes
# to the configured bound. It runs on the same seeded state every failure case
# preserved, so this is also the failure-then-success retry path.
run_case success ok ok
if ((case_status != 0)); then
  echo "❌ [success] preparation should have succeeded but exited $case_status." >&2
  sed 's/^/   /' "$sandbox/logs/success.log" >&2
  exit 1
fi

newest_generation="$(readlink "$sandbox/staging/current")"
newest_generation="${newest_generation#generations/}"
newest_root="$sandbox/staging/generations/$newest_generation"
retained="$(jq -r '.retained' <<<"$facts")"

problem=""
[[ "$newest_generation" != "$generation_newest" ]] || problem="the current symlink still points at the seeded generation"
[[ -s "$newest_root/dumps/langfuse-clickhouse.zip" ]] || problem="the published ClickHouse archive is missing or empty"
grep -q 'dumps/langfuse-clickhouse.zip' "$newest_root/metadata/SHA256SUMS" ||
  problem="the published generation has no ClickHouse checksum record"
(
  cd "$newest_root"
  sha256sum --check metadata/SHA256SUMS
) >/dev/null || problem="the published checksums do not verify"
[[ "$(jq -r '.host' "$newest_root/metadata/manifest.json")" == "server" ]] ||
  problem="the published manifest lost its host identity"
[[ "$(jq -r '.sqliteDumps' "$newest_root/metadata/manifest.json")" == "$(jq -r '.sqliteCount' <<<"$facts")" ]] ||
  problem="the published manifest lost its SQLite dump count"
jq -e --argjson dbs "$(jq -c '.postgresqlDbs' <<<"$facts")" '.postgresqlDumps == $dbs' \
  "$newest_root/metadata/manifest.json" >/dev/null ||
  problem="the published manifest lost the Langfuse PostgreSQL dump"
[[ -d "$sandbox/staging/generations/$generation_newest" ]] ||
  problem="the previous complete current generation did not survive"
mapfile -t surviving < <(find "$sandbox/staging/generations" -mindepth 1 -maxdepth 1 \
  -type d ! -name '.prepare.*' -printf '%f\n' | LC_ALL=C sort)
((${#surviving[@]} == retained)) ||
  problem="retention kept ${#surviving[@]} generations, expected $retained"
[[ " ${surviving[*]} " != *" $generation_oldest "* ]] ||
  problem="retention did not prune the oldest seeded generation"

if [[ -n "$problem" ]]; then
  echo "❌ [success] $problem" >&2
  sed 's/^/   /' "$sandbox/logs/success.log" >&2
  exit 1
fi
echo "  ✅ [success] published $newest_generation with a verified ClickHouse archive; retention kept $retained"

echo "✅ Langfuse complete-backup contract restored: MinIO stays in the snapshot and an incomplete archive cannot publish."
