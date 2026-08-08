#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"
cd "$TESTS_REPO_ROOT"
ensure_tools jq nix python3 rg

test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT

python3 custom_apps/mkvmaker/auto_import.py \
  --self-test \
  --input-dir /unused \
  --movies-dir /unused \
  --shows-dir /unused \
  --state-dir /unused \
  --converter /unused

surface_json="$(nix eval --json '.#nixosConfigurations.server.config' --apply 'cfg: {
  paths = cfg.repo.mkvmaker.paths;
  personalContent = cfg.repo.storage.userRoots.contentSubdirs;
  sharedContent = cfg.repo.storage.sharedRoots.contentSubdirs;
  guarded = cfg.repo.storage.dataPool.guardedServices;
  persistence = cfg.repo.impermanence.inventory.persistenceDirectories;
  backupApps = map (entry: entry.app) cfg.repo.backups.appStateEntries;
  timer = cfg.systemd.timers.mkvmaker-import.timerConfig;
  dispatcher = cfg.systemd.services.mkvmaker-import.serviceConfig;
  dispatcherUnit = cfg.systemd.services.mkvmaker-import.unitConfig;
  worker = cfg.systemd.services.mkvmaker-import-worker.serviceConfig;
  workerUnit = cfg.systemd.services.mkvmaker-import-worker.unitConfig;
  homepageEnvironment = cfg.systemd.services.homepage.environment;
}')"

jq -e '
  (.paths.dvdInbox == "/mnt/data/shared/_ISO/_DVDs")
  and (.paths.moviesOutput == "/mnt/data/shared/_Videos/_Movies")
  and (.paths.showsOutput == "/mnt/data/shared/_Videos/_Shows")
  and (.paths.stagingRoot == "/mnt/data/shared/.mkvmaker-staging")
  and (.sharedContent | index(".mkvmaker-staging") != null)
  and (.personalContent | index("_ISO") != null)
  and (.sharedContent | index("_ISO") != null)
  and (.guarded | index("mkvmaker-storage-layout-v1") != null)
  and (.guarded | index("mkvmaker-import") != null)
  and (.guarded | index("mkvmaker-import-worker") != null)
  and (.persistence | index("/var/lib/mkvmaker") != null)
  and (.backupApps | index("mkvmaker") != null)
  and (.timer.OnBootSec == "1min")
  and (.timer.OnUnitInactiveSec == "1min")
  and (.timer.Unit == "mkvmaker-import.service")
  and (.dispatcherUnit.StartLimitIntervalSec == "1h")
  and (.dispatcherUnit.StartLimitBurst > 60)
  and (.dispatcher.Type == "oneshot")
  and (.dispatcher.ExecStart == "/run/current-system/sw/bin/systemctl start --no-block mkvmaker-import-worker.service")
  and (.dispatcher.RuntimeDirectory == null)
  and (.dispatcher.Restart == "no")
  and (.dispatcher.TimeoutStartSec == "30s")
  and (.dispatcher.ProtectSystem == "strict")
  and (.dispatcher.NoNewPrivileges == true)
  and (.worker.Type == "simple")
  and (.worker.User == "mkvmaker")
  and (.worker.Group == "mkvmaker")
  and (.worker.RuntimeDirectory == "mkvmaker")
  and (.worker.RuntimeDirectoryMode == "0755")
  and (.worker.RuntimeDirectoryPreserve == "yes")
  and (.worker.ProtectSystem == "strict")
  and (.worker.NoNewPrivileges == true)
  and (.worker.Restart == "on-failure")
  and (.worker.RestartSec == "30s")
  and (.worker.TimeoutStartSec == "8h")
  and (.worker.KillSignal == "SIGINT")
  and (.worker.KillMode == "control-group")
  and (.worker.SendSIGKILL == true)
  and (.worker.FinalKillSignal == "SIGKILL")
  and (.worker.SuccessExitStatus | map(tostring) | index("130") != null)
  and (.worker.SuccessExitStatus | map(tostring) | index("SIGINT") != null)
  and (.worker.SupplementaryGroups | index("files-shared-users") != null)
  and (.worker.SupplementaryGroups | index("nixhomeserver-maintenance") != null)
  and (.worker.ReadWritePaths == [
    "/var/lib/mkvmaker",
    "/mnt/data/shared/_ISO/_DVDs",
    "/mnt/data/shared/_Videos/_Movies",
    "/mnt/data/shared/_Videos/_Shows",
    "/mnt/data/shared/.mkvmaker-staging"
  ])
  and (.workerUnit.StartLimitBurst > 60)
  and (.homepageEnvironment.HOMEPAGE_MKVMAKER_PROGRESS_FILE == "/run/mkvmaker/progress.json")
' <<<"$surface_json" >/dev/null || {
  echo "❌ Mkvmaker evaluated service or storage surface is invalid." >&2
  jq . <<<"$surface_json"
  exit 1
}

require_fixed custom_apps/mkvmaker/auto_import.py 'for path in args.input_dir.iterdir()' \
  "mkvmaker must inspect only the configured shared DVD inbox, not personal _ISO trees"
require_fixed custom_apps/mkvmaker/auto_import.py 'likely_play_all' \
  "mkvmaker must filter likely play-all duplicates"
require_fixed custom_apps/mkvmaker/auto_import.py 'ratio >= dominant_ratio' \
  "mkvmaker must implement the dominant-feature threshold"
require_fixed custom_apps/mkvmaker/src/main.rs 'let _ = fs::remove_file(&partial);' \
  "the converter must discard a stale partial file before restarting an encode"
require_fixed custom_apps/mkvmaker/auto_import.py 'find_duplicate' \
  "mkvmaker must hash-check ISOs against the _Processed folder before conversion"

mkdir -p "$test_root/inbox" "$test_root/movies" "$test_root/shows" "$test_root/state"
printf 'fake iso data\n' >"$test_root/inbox/Restartable_2001.iso"

fake_converter="$test_root/fake-converter"
cat >"$fake_converter" <<EOF
#!/usr/bin/env bash
set -euo pipefail
if [[ ! -e "$test_root/allow-completion" ]]; then
  printf '%s\n' "\$@" >"$test_root/converter-args"
  printf '%s\n' "\$\$" >"$test_root/converter.pid"
  touch "$test_root/converter-started"
  trap 'exit 130' INT TERM
  while true; do
    sleep 1
  done
fi
exit 0
EOF
make_test_executable "$fake_converter"

TEST_ROOT="$test_root" python3 - <<'PY'
import json
import os
from pathlib import Path

root = Path(os.environ["TEST_ROOT"])
source = root / "inbox/Restartable_2001.iso"
stat = source.stat()
state = {
    "version": 1,
    "sources": {
        source.name: {
            "signature": {"size": stat.st_size, "mtime_ns": stat.st_mtime_ns},
            "unchanged_since": 0,
            "attempts": 0,
            "plan": {
                "kind": "movie",
                "name": "Restartable",
                "year": 2001,
                "provider": None,
                "movie_disc": None,
                "titles": [1],
                "dominant_ratio": 0.9,
                "output": str(root / "movies"),
            },
        }
    },
}
another = root / "inbox/Another_1999.iso"
another.write_bytes(b"more fake iso data\n")
another_stat = another.stat()
state["sources"][another.name] = {
    "signature": {"size": another_stat.st_size, "mtime_ns": another_stat.st_mtime_ns},
    "unchanged_since": 9_999_999_999,
    "attempts": 0,
}
(root / "state/queue.json").write_text(json.dumps(state), encoding="utf-8")
PY

auto_import=(
  python3 custom_apps/mkvmaker/auto_import.py
  --input-dir "$test_root/inbox"
  --movies-dir "$test_root/movies"
  --shows-dir "$test_root/shows"
  --state-dir "$test_root/state"
  --progress-file "$test_root/progress.json"
  --converter "$fake_converter"
  --handbrake /unused
  --settle-seconds 1
  --retry-seconds 1
)

"${auto_import[@]}" >/dev/null 2>&1 &
supervisor_pid=$!
for _ in {1..100}; do
  [[ -e "$test_root/converter-started" ]] && break
  sleep 0.05
done
[[ -e "$test_root/converter-started" ]] || {
  echo "❌ Timed out waiting for the fake converter to start." >&2
  kill "$supervisor_pid" 2>/dev/null || true
  wait "$supervisor_pid" 2>/dev/null || true
  exit 1
}
python3 - "$test_root/converter-args" "$test_root/inbox" <<'PY'
import sys
from pathlib import Path

arguments = Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()

def argument_value(name: str) -> str:
    index = arguments.index(name)
    return arguments[index + 1]

assert argument_value("--queue-directory") == sys.argv[2]
assert argument_value("--active-queue-item") == "Restartable_2001.iso"
PY
jq -e '
  (.schemaVersion == 1)
  and (.state == "converting")
  and (.conversions[0].title == "Restartable")
  and (.conversions[0].mediaKind == "movie")
  and (.conversions[0].percent == 0)
  and (.queued == ["Another_1999"])
' "$test_root/progress.json" >/dev/null
kill -TERM "$supervisor_pid"
set +e
wait "$supervisor_pid"
interrupted_status=$?
set -e
[[ "$interrupted_status" == 130 ]] || {
  echo "❌ Interrupted conversion returned $interrupted_status instead of 130." >&2
  exit 1
}
jq -e '
  (.sources["Restartable_2001.iso"].status == "interrupted")
  and (.sources["Restartable_2001.iso"].attempts == 0)
  and (.sources["Restartable_2001.iso"].plan.titles == [1])
' "$test_root/state/queue.json" >/dev/null
jq -e '
  (.schemaVersion == 1)
  and (.state == "idle")
  and (.conversions == [])
  and (.queued == ["Another_1999", "Restartable_2001"])
' \
  "$test_root/progress.json" >/dev/null
[[ -f "$test_root/inbox/Restartable_2001.iso" ]] || {
  echo "❌ Interrupted conversion did not preserve its source ISO." >&2
  exit 1
}
converter_pid="$(<"$test_root/converter.pid")"
if kill -0 "$converter_pid" 2>/dev/null; then
  echo "❌ Interrupted supervisor left its converter process running." >&2
  kill -KILL "$converter_pid" 2>/dev/null || true
  exit 1
fi

touch "$test_root/allow-completion"
"${auto_import[@]}" >/dev/null
[[ -f "$test_root/inbox/_Processed/Restartable_2001.iso" ]] || {
  echo "❌ Restarted conversion did not complete from its durable plan." >&2
  exit 1
}
jq -e '.sources["Restartable_2001.iso"] == null' "$test_root/state/queue.json" >/dev/null

cp "$test_root/inbox/_Processed/Restartable_2001.iso" \
  "$test_root/inbox/Restartable_2001_again.iso"
TEST_ROOT="$test_root" python3 - <<'PY'
import json
import os
from pathlib import Path

root = Path(os.environ["TEST_ROOT"])
state_path = root / "state/queue.json"
source = root / "inbox/Restartable_2001_again.iso"
stat = source.stat()
state = json.loads(state_path.read_text(encoding="utf-8"))
state["sources"][source.name] = {
    "signature": {"size": stat.st_size, "mtime_ns": stat.st_mtime_ns},
    "unchanged_since": 0,
    "attempts": 0,
}
state_path.write_text(json.dumps(state), encoding="utf-8")
PY

"${auto_import[@]}" >/dev/null
[[ -f "$test_root/inbox/_Failed/Restartable_2001_again.iso" ]] || {
  echo "❌ Duplicate ISO was not moved to the _Failed folder." >&2
  exit 1
}
[[ -f "$test_root/inbox/_Processed/Restartable_2001.iso" ]] || {
  echo "❌ Duplicate check removed the originally processed ISO." >&2
  exit 1
}
error_log="$test_root/inbox/_Failed/Restartable_2001_again.iso.error.txt"
grep -q "Duplicate ISO" "$error_log" || {
  echo "❌ Duplicate note is missing from the error log." >&2
  exit 1
}
grep -q "Restartable_2001.iso" "$error_log" || {
  echo "❌ Duplicate note does not name the existing ISO." >&2
  exit 1
}
jq -e '.sources["Restartable_2001_again.iso"] == null' "$test_root/state/queue.json" >/dev/null
jq -e '.processed_hashes["Restartable_2001.iso"] != null' "$test_root/state/queue.json" >/dev/null

echo "✅ Mkvmaker queue, title-selection, path scope, deduplication, and service policy are valid."
