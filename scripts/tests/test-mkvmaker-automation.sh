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
  unit = cfg.systemd.services.mkvmaker-import.unitConfig;
  service = cfg.systemd.services.mkvmaker-import.serviceConfig;
  homepageEnvironment = cfg.systemd.services.homepage.environment;
}')"

jq -e '
  (.paths.dvdInbox == "/mnt/data/shared/_ISO/_DVDs")
  and (.paths.moviesOutput == "/mnt/data/shared/_Videos/_Movies")
  and (.paths.showsOutput == "/mnt/data/shared/_Videos/_Shows")
  and (.personalContent | index("_ISO") != null)
  and (.sharedContent | index("_ISO") != null)
  and (.guarded | index("mkvmaker-storage-layout-v1") != null)
  and (.guarded | index("mkvmaker-import") != null)
  and (.persistence | index("/var/lib/mkvmaker") != null)
  and (.backupApps | index("mkvmaker") != null)
  and (.timer.OnBootSec == "1min")
  and (.timer.OnUnitInactiveSec == "1min")
  and (.unit.StartLimitIntervalSec == "1h")
  and (.unit.StartLimitBurst > 60)
  and (.service.User == "mkvmaker")
  and (.service.Group == "mkvmaker")
  and (.service.RuntimeDirectory == "mkvmaker")
  and (.service.RuntimeDirectoryMode == "0755")
  and (.service.ProtectSystem == "strict")
  and (.service.NoNewPrivileges == true)
  and (.service.Restart == "no")
  and (.service.KillSignal == "SIGINT")
  and (.service.KillMode == "control-group")
  and (.service.SendSIGKILL == true)
  and (.service.FinalKillSignal == "SIGKILL")
  and (.service.SuccessExitStatus | map(tostring) | index("130") != null)
  and (.service.SuccessExitStatus | map(tostring) | index("SIGINT") != null)
  and (.service.SupplementaryGroups | index("files-shared-users") != null)
  and (.service.SupplementaryGroups | index("nixhomeserver-maintenance") != null)
  and (.service.ReadWritePaths == [
    "/var/lib/mkvmaker",
    "/mnt/data/shared/_ISO/_DVDs",
    "/mnt/data/shared/_Videos/_Movies",
    "/mnt/data/shared/_Videos/_Shows"
  ])
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

mkdir -p "$test_root/inbox" "$test_root/movies" "$test_root/shows" "$test_root/state"
printf 'fake iso data\n' >"$test_root/inbox/Restartable_2001.iso"

fake_converter="$test_root/fake-converter"
cat >"$fake_converter" <<EOF
#!/usr/bin/env bash
set -euo pipefail
if [[ ! -e "$test_root/allow-completion" ]]; then
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
jq -e '
  (.schemaVersion == 1)
  and (.state == "converting")
  and (.conversions[0].title == "Restartable")
  and (.conversions[0].mediaKind == "movie")
  and (.conversions[0].percent == 0)
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
jq -e '(.schemaVersion == 1) and (.state == "idle") and (.conversions == [])' \
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

echo "✅ Mkvmaker queue, title-selection, path scope, and service policy are valid."
