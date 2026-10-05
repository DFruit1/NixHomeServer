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
  workerRestartIfChanged = cfg.systemd.services.mkvmaker-import-worker.restartIfChanged;
  workerWantedBy = cfg.systemd.services.mkvmaker-import-worker.wantedBy;
  storageLayout = cfg.systemd.services.mkvmaker-storage-layout-v1.script;
  tmpfiles = cfg.systemd.tmpfiles.rules;
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
  and (.workerRestartIfChanged == true)
  and (.workerWantedBy | index("multi-user.target") != null)
  and (.tmpfiles | index("d /run/mkvmaker 0755 mkvmaker mkvmaker -") != null)
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
  and (.storageLayout | contains("/_Duplicate"))
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
require_fixed custom_apps/mkvmaker/auto_import.py 'is_jellyfin_named' \
  "mkvmaker must detect Jellyfin-style filename curation and preserve the user's chosen library name"
require_fixed custom_apps/mkvmaker/auto_import.py 'if not hints.is_jellyfin_named' \
  "mkvmaker must bypass TVmaze when the ISO filename already carries Jellyfin naming signals"
require_fixed custom_apps/mkvmaker/auto_import.py 'find_existing_series' \
  "mkvmaker must keep related discs in one Jellyfin library folder for queue continuity"
require_fixed custom_apps/mkvmaker/auto_import.py '_roman_to_int' \
  "mkvmaker must interpret Roman/Arabic series identifiers (e.g. Rumpole IV/3) as season numbers"
require_fixed custom_apps/mkvmaker/auto_import.py 'RUMPOLE_OF_THE_BAILEY_IV_DISC_2' \
  "mkvmaker self-test must cover the user's Rumpole IV / Series 3 grouping example"

mkdir -p "$test_root/inbox" "$test_root/movies" "$test_root/shows" "$test_root/state"
printf 'fake iso data\n' >"$test_root/inbox/Restartable_2001.iso"

fake_converter="$test_root/fake-converter"
cat >"$fake_converter" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf 'invoked\n' >>"$test_root/converter-invocations"
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

canonical_output = root / "movies/Restartable/Restartable.mkv"
duplicate_output = root / "movies/Restartable duplicate/Restartable duplicate.mkv"
canonical_output.parent.mkdir(parents=True, exist_ok=True)
duplicate_output.parent.mkdir(parents=True, exist_ok=True)
canonical_output.write_bytes(b"canonical mkv\n")
duplicate_output.write_bytes(b"duplicate mkv\n")

jobs = root / "state/disc-to-jellyfin/jobs"
jobs.mkdir(parents=True, exist_ok=True)
common = {
    "completed": True,
    "input_size": source.stat().st_size,
    "title": 1,
}
(jobs / "canonical.job.json").write_text(
    json.dumps({
        **common,
        "input": str(root / "inbox/Restartable_2001.iso"),
        "output": str(canonical_output),
    }),
    encoding="utf-8",
)
(jobs / "duplicate.job.json").write_text(
    json.dumps({
        **common,
        "input": str(source),
        "output": str(duplicate_output),
    }),
    encoding="utf-8",
)
PY

"${auto_import[@]}" >/dev/null
[[ -f "$test_root/inbox/_Duplicate/Restartable_2001_again.iso" ]] || {
  echo "❌ Duplicate ISO was not moved to the _Duplicate folder." >&2
  exit 1
}
[[ -f "$test_root/inbox/_Processed/Restartable_2001.iso" ]] || {
  echo "❌ Duplicate check removed the originally processed ISO." >&2
  exit 1
}
duplicate_report="$test_root/inbox/_Duplicate/Restartable_2001_again.iso.duplicate.json"
jq -e '
  (.duplicateOf == "Restartable_2001.iso")
  and (.quarantinedOutputs | length == 1)
' "$duplicate_report" >/dev/null || {
  echo "❌ Duplicate report is missing its canonical ISO or quarantined output." >&2
  exit 1
}
[[ -f "$test_root/movies/Restartable/Restartable.mkv" ]] || {
  echo "❌ Duplicate cleanup moved the canonical Jellyfin output." >&2
  exit 1
}
[[ ! -e "$test_root/movies/Restartable duplicate/Restartable duplicate.mkv" ]] || {
  echo "❌ Duplicate cleanup left the duplicate output in Jellyfin." >&2
  exit 1
}
[[ -f "$test_root/inbox/_Duplicate/_Movies/Restartable duplicate/Restartable duplicate.mkv" ]] || {
  echo "❌ Duplicate cleanup did not preserve the duplicate output for review." >&2
  exit 1
}
jq -e '.sources["Restartable_2001_again.iso"] == null' "$test_root/state/queue.json" >/dev/null
jq -e '.processed_hashes["Restartable_2001.iso"] != null' "$test_root/state/queue.json" >/dev/null
[[ "$(wc -l <"$test_root/converter-invocations")" == 2 ]] || {
  echo "❌ Byte-identical ISO reached the converter." >&2
  exit 1
}

# A repeated upload with exactly the same filename must also be detected. The
# processed and inbox paths are distinct, so excluding equal basenames would
# unnecessarily decode the same bytes again.
cp "$test_root/inbox/_Processed/Restartable_2001.iso" \
  "$test_root/inbox/Restartable_2001.iso"
TEST_ROOT="$test_root" python3 - <<'PY'
import json
import os
from pathlib import Path

root = Path(os.environ["TEST_ROOT"])
state_path = root / "state/queue.json"
source = root / "inbox/Restartable_2001.iso"
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
[[ -f "$test_root/inbox/_Duplicate/Restartable_2001.iso" ]] || {
  echo "❌ Same-name duplicate ISO was not quarantined." >&2
  exit 1
}
[[ "$(wc -l <"$test_root/converter-invocations")" == 2 ]] || {
  echo "❌ Same-name duplicate ISO reached the converter." >&2
  exit 1
}

# Hash I/O failures must never degrade into an unchecked conversion.
cp "$test_root/inbox/_Processed/Restartable_2001.iso" \
  "$test_root/inbox/Unverifiable.iso"
TEST_ROOT="$test_root" python3 - <<'PY'
import json
import os
from pathlib import Path

root = Path(os.environ["TEST_ROOT"])
state_path = root / "state/queue.json"
source = root / "inbox/Unverifiable.iso"
stat = source.stat()
state = json.loads(state_path.read_text(encoding="utf-8"))
state["processed_hashes"].pop("Restartable_2001.iso", None)
state["sources"][source.name] = {
    "signature": {"size": stat.st_size, "mtime_ns": stat.st_mtime_ns},
    "unchanged_since": 0,
    "attempts": 0,
}
state_path.write_text(json.dumps(state), encoding="utf-8")
PY
chmod 000 "$test_root/inbox/_Processed/Restartable_2001.iso"
set +e
"${auto_import[@]}" >/dev/null 2>&1
unverifiable_status=$?
set -e
chmod 0644 "$test_root/inbox/_Processed/Restartable_2001.iso"
[[ "$unverifiable_status" == 1 ]] || {
  echo "❌ Unavailable duplicate hashing did not fail the importer." >&2
  exit 1
}
[[ -f "$test_root/inbox/Unverifiable.iso" ]] || {
  echo "❌ Unverifiable ISO was not retained for a safe retry." >&2
  exit 1
}
jq -e '
  (.sources["Unverifiable.iso"].status == "duplicate-check-failed")
  and (.sources["Unverifiable.iso"].attempts == 1)
' "$test_root/state/queue.json" >/dev/null
[[ "$(wc -l <"$test_root/converter-invocations")" == 2 ]] || {
  echo "❌ Unverifiable ISO reached the converter." >&2
  exit 1
}

# A duplicate check that fails slowly must still pay its full retry backoff.
# The stamp is written when the failure is recorded, so a failure that takes
# longer than the whole backoff interval must not leave retry_after in the
# past and hand the ISO straight back to the next claim. The fake clock makes
# the slow read deterministic instead of a sleep.
backoff_root="$test_root/backoff"
mkdir -p "$backoff_root/inbox/_Processed" "$backoff_root/state" \
  "$backoff_root/movies" "$backoff_root/shows"
printf 'slow fake iso data\n' >"$backoff_root/inbox/Slow_1999.iso"
printf 'slow fake iso data\n' >"$backoff_root/inbox/_Processed/Slow_1999.iso"
BACKOFF_ROOT="$backoff_root" python3 - <<'PY'
import importlib.util
import json
import os
import sys
from pathlib import Path

root = Path(os.environ["BACKOFF_ROOT"])
retry_seconds = 60
slow_read = retry_seconds * 3

# Importing the importer would otherwise leave a __pycache__ in the tree.
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location(
    "mkvmaker_auto_import", "custom_apps/mkvmaker/auto_import.py"
)
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module  # dataclass resolution requires the registration
spec.loader.exec_module(module)

# Pre-seed the queue the way a settled upload looks, so the run reaches
# duplicate detection instead of only waiting out the settle window.
source = root / "inbox/Slow_1999.iso"
stat = source.stat()
(root / "state/queue.json").write_text(
    json.dumps(
        {
            "version": 1,
            "sources": {
                source.name: {
                    "signature": {
                        "size": stat.st_size,
                        "mtime_ns": stat.st_mtime_ns,
                        "ctime_ns": stat.st_ctime_ns,
                    },
                    "unchanged_since": 0,
                    "attempts": 0,
                }
            },
        }
    ),
    encoding="utf-8",
)

# A fake clock makes a slow duplicate check deterministic: each observation
# advances time, and the slow whole-ISO read advances it past the whole
# backoff interval. No sleeps and no wall-clock sensitivity.
clock = {"now": 1_700_000_000}
failure_clock: dict[str, int] = {}


class FakeClock:
    def time(self) -> int:
        clock["now"] += 1
        return clock["now"]

    def monotonic(self) -> float:
        return float(clock["now"])


def slow_failing_hash(path: Path) -> str:
    # Reading the whole ISO is what makes duplicate detection slow.
    clock["now"] += slow_read
    failure_clock["now"] = clock["now"]
    raise OSError(f"simulated read failure for {path.name}")


module.time = FakeClock()
module.iso_sha256 = slow_failing_hash

sys.argv = [
    "auto_import.py",
    "--input-dir", str(root / "inbox"),
    "--movies-dir", str(root / "movies"),
    "--shows-dir", str(root / "shows"),
    "--state-dir", str(root / "state"),
    "--progress-file", str(root / "progress.json"),
    "--converter", "/bin/true",
    "--settle-seconds", "1",
    "--retry-seconds", str(retry_seconds),
]
args = module.parse_args()
status = module.run(args)

assert status == 1, f"duplicate-check failure returned {status}, expected 1"
state = json.loads((root / "state/queue.json").read_text(encoding="utf-8"))
entry = state["sources"].get("Slow_1999.iso")
# With a claim-time stamp the backoff is already expired when it is written, so
# the loop re-claims the same ISO within the one run and burns every attempt.
assert entry is not None, (
    "Slow_1999.iso left the queue after a single run: its backoff had already "
    f"expired, so all attempts were consumed back to back ({state['sources']})"
)
assert entry["attempts"] == 1, entry
assert entry["status"] == "duplicate-check-failed", entry
assert "lease" not in entry, entry
# The whole backoff must still be ahead of the failure. A claim-time stamp
# would be retry_seconds * attempts after a claim that happened slow_read
# seconds earlier, so it lands in the past here and the ISO is retried at once.
recorded = entry["retry_after"]
assert recorded >= failure_clock["now"] + retry_seconds, (
    f"retry_after {recorded} is less than "
    f"{failure_clock['now']} + {retry_seconds}; the slow duplicate check "
    "consumed its own backoff, so the ISO is retried without any delay"
)
PY

echo "✅ Mkvmaker queue, title-selection, path scope, deduplication, and service policy are valid."
