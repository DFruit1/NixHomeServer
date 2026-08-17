#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"
cd "$TESTS_REPO_ROOT"
ensure_tools jq python3

test_root="$(mktemp -d)"
worker_a_pid=""
worker_b_pid=""
worker_c_pid=""
worker_d_pid=""
worker_e_pid=""
worker_f_pid=""
cleanup() {
  for pid in "$worker_a_pid" "$worker_b_pid" "$worker_c_pid" "$worker_d_pid" "$worker_e_pid" "$worker_f_pid"; do
    [[ -n "$pid" ]] || continue
    kill -CONT "$pid" 2>/dev/null || true
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  rm -rf "$test_root"
}
trap cleanup EXIT

mkdir -p "$test_root/inbox" "$test_root/movies" "$test_root/shows" "$test_root/state"
printf 'alpha iso\n' >"$test_root/inbox/Alpha_2001.iso"
printf 'beta iso\n' >"$test_root/inbox/Beta_2002.iso"

TEST_ROOT="$test_root" python3 - <<'PY'
import json
import os
from pathlib import Path

root = Path(os.environ["TEST_ROOT"])
sources = {}
for name, title, year in (
    ("Alpha_2001.iso", "Alpha", 2001),
    ("Beta_2002.iso", "Beta", 2002),
):
    source = root / "inbox" / name
    stat = source.stat()
    sources[name] = {
        "signature": {
            "size": stat.st_size,
            "mtime_ns": stat.st_mtime_ns,
            "ctime_ns": stat.st_ctime_ns,
        },
        "unchanged_since": 0,
        "attempts": 0,
        "plan": {
            "kind": "movie",
            "name": title,
            "year": year,
            "provider": None,
            "movie_disc": None,
            "titles": [1],
            "dominant_ratio": 1.0,
            "output": str(root / "movies"),
        },
    }
(root / "state" / "queue.json").write_text(
    json.dumps({"version": 2, "sources": sources}), encoding="utf-8"
)
PY

make_worker_converter() {
  local worker="$1"
  local converter="$test_root/converter-$worker"
  cat >"$converter" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "\$@" >"$test_root/args-$worker"
touch "$test_root/started-$worker"
trap 'exit 130' INT TERM
while [[ ! -e "$test_root/allow-$worker" ]]; do
  sleep 0.05
done
EOF
  make_test_executable "$converter"
}

make_worker_converter a
make_worker_converter b

run_worker() {
  local worker="$1"
  python3 custom_apps/mkvmaker/auto_import.py \
    --input-dir "$test_root/inbox" \
    --movies-dir "$test_root/movies" \
    --shows-dir "$test_root/shows" \
    --state-dir "$test_root/state" \
    --converter "$test_root/converter-$worker" \
    --handbrake /unused \
    --settle-seconds 1 \
    --retry-seconds 1 \
    --worker-id "worker-$worker" \
    --lease-seconds 5
}

run_worker a >"$test_root/worker-a.log" 2>&1 &
worker_a_pid=$!
for _ in {1..100}; do
  [[ -e "$test_root/started-a" ]] && break
  sleep 0.05
done
[[ -e "$test_root/started-a" ]] || {
  echo "❌ First distributed worker did not start its encode." >&2
  exit 1
}

run_worker b >"$test_root/worker-b.log" 2>&1 &
worker_b_pid=$!
for _ in {1..100}; do
  [[ -e "$test_root/started-b" ]] && break
  sleep 0.05
done
[[ -e "$test_root/started-b" ]] || {
  echo "❌ Second distributed worker could not claim another queued ISO." >&2
  cat "$test_root/worker-b.log" >&2
  exit 1
}

grep -Fxq "$test_root/inbox/Alpha_2001.iso" "$test_root/args-a" || {
  echo "❌ First worker did not claim the first ISO." >&2
  exit 1
}
grep -Fxq "$test_root/inbox/Beta_2002.iso" "$test_root/args-b" || {
  echo "❌ Second worker did not skip the leased ISO and claim the next one." >&2
  exit 1
}

jq -e '
  (.sources["Alpha_2001.iso"].lease.workerId == "worker-a")
  and (.sources["Beta_2002.iso"].lease.workerId == "worker-b")
  and (.sources["Alpha_2001.iso"].lease.expiresAt > 0)
  and (.sources["Beta_2002.iso"].lease.expiresAt > 0)
' "$test_root/state/queue.json" >/dev/null

touch "$test_root/allow-a" "$test_root/allow-b"
wait "$worker_a_pid"
worker_a_pid=""
wait "$worker_b_pid"
worker_b_pid=""

[[ -f "$test_root/inbox/_Processed/Alpha_2001.iso" ]]
[[ -f "$test_root/inbox/_Processed/Beta_2002.iso" ]]
jq -e '.sources == {}' "$test_root/state/queue.json" >/dev/null

printf 'gamma iso\n' >"$test_root/inbox/Gamma_2003.iso"
TEST_ROOT="$test_root" python3 - <<'PY'
import json
import os
import time
from pathlib import Path

root = Path(os.environ["TEST_ROOT"])
source = root / "inbox" / "Gamma_2003.iso"
stat = source.stat()
entry = {
    "signature": {
        "size": stat.st_size,
        "mtime_ns": stat.st_mtime_ns,
        "ctime_ns": stat.st_ctime_ns,
    },
    "unchanged_since": 0,
    "attempts": 0,
    "lease": {
        "workerId": "worker-c",
        "leaseId": "still-running-elsewhere",
        "claimedAt": int(time.time()),
        "expiresAt": int(time.time()) + 60,
    },
    "plan": {
        "kind": "movie",
        "name": "Gamma",
        "year": 2003,
        "provider": None,
        "movie_disc": None,
        "titles": [1],
        "dominant_ratio": 1.0,
        "output": str(root / "movies"),
    },
}
(root / "state" / "queue.json").write_text(
    json.dumps({"version": 2, "sources": {source.name: entry}}), encoding="utf-8"
)
PY

make_worker_converter c
run_worker c >"$test_root/worker-c-active.log" 2>&1 &
worker_c_pid=$!
for _ in {1..100}; do
  [[ -e "$test_root/started-c" ]] && break
  sleep 0.05
done
[[ -e "$test_root/started-c" ]] || {
  echo "❌ An abandoned future-dated lease stranded its ISO." >&2
  cat "$test_root/worker-c-active.log" >&2
  exit 1
}
touch "$test_root/allow-c"
wait "$worker_c_pid"
worker_c_pid=""
[[ -f "$test_root/inbox/_Processed/Gamma_2003.iso" ]]

printf 'delta iso\n' >"$test_root/inbox/Delta_2004.iso"
TEST_ROOT="$test_root" python3 - <<'PY'
import json
import os
from pathlib import Path

root = Path(os.environ["TEST_ROOT"])
source = root / "inbox" / "Delta_2004.iso"
stat = source.stat()
entry = {
    "signature": {
        "size": stat.st_size,
        "mtime_ns": stat.st_mtime_ns,
        "ctime_ns": stat.st_ctime_ns,
    },
    "unchanged_since": 0,
    "attempts": 0,
    "plan": {
        "kind": "movie",
        "name": "Delta",
        "year": 2004,
        "provider": None,
        "movie_disc": None,
        "titles": [1],
        "dominant_ratio": 1.0,
        "output": str(root / "movies"),
    },
}
(root / "state" / "queue.json").write_text(
    json.dumps({"version": 2, "sources": {source.name: entry}}), encoding="utf-8"
)
PY

make_worker_converter d
make_worker_converter e
run_worker d >"$test_root/worker-d.log" 2>&1 &
worker_d_pid=$!
for _ in {1..100}; do
  [[ -e "$test_root/started-d" ]] && break
  sleep 0.05
done
[[ -e "$test_root/started-d" ]] || {
  echo "❌ Worker did not start the source-lock test encode." >&2
  cat "$test_root/worker-d.log" >&2
  exit 1
}

# Freeze the supervisor beyond its JSON lease. The kernel-backed source lock
# must still prevent another worker from starting the same ISO.
kill -STOP "$worker_d_pid"
sleep 6
run_worker e >"$test_root/worker-e.log" 2>&1 &
worker_e_pid=$!
for _ in {1..40}; do
  if ! kill -0 "$worker_e_pid" 2>/dev/null; then
    wait "$worker_e_pid"
    worker_e_pid=""
    break
  fi
  sleep 0.05
done
[[ -z "$worker_e_pid" ]] || {
  echo "❌ An expired JSON lease allowed a second live encode of the same ISO." >&2
  cat "$test_root/worker-e.log" >&2
  exit 1
}
[[ ! -e "$test_root/started-e" ]] || {
  echo "❌ The source lock did not protect an encode whose supervisor was paused." >&2
  exit 1
}

kill -CONT "$worker_d_pid"
touch "$test_root/allow-d"
wait "$worker_d_pid"
worker_d_pid=""
[[ -f "$test_root/inbox/_Processed/Delta_2004.iso" ]]

printf 'epsilon original\n' >"$test_root/inbox/Epsilon_2005.iso"
TEST_ROOT="$test_root" python3 - <<'PY'
import json
import os
from pathlib import Path

root = Path(os.environ["TEST_ROOT"])
source = root / "inbox" / "Epsilon_2005.iso"
stat = source.stat()
entry = {
    "signature": {
        "size": stat.st_size,
        "mtime_ns": stat.st_mtime_ns,
        "ctime_ns": stat.st_ctime_ns,
    },
    "unchanged_since": 0,
    "attempts": 0,
    "plan": {
        "kind": "movie",
        "name": "Epsilon",
        "year": 2005,
        "provider": None,
        "movie_disc": None,
        "titles": [1],
        "dominant_ratio": 1.0,
        "output": str(root / "movies"),
    },
}
(root / "state" / "queue.json").write_text(
    json.dumps({"version": 2, "sources": {source.name: entry}}), encoding="utf-8"
)
PY

make_worker_converter f
run_worker f >"$test_root/worker-f.log" 2>&1 &
worker_f_pid=$!
for _ in {1..100}; do
  [[ -e "$test_root/started-f" ]] && break
  sleep 0.05
done
[[ -e "$test_root/started-f" ]] || {
  echo "❌ Worker did not start the source replacement test encode." >&2
  cat "$test_root/worker-f.log" >&2
  exit 1
}
printf 'epsilon replaced\n' >"$test_root/inbox/.Epsilon_2005.iso.new"
mv -f "$test_root/inbox/.Epsilon_2005.iso.new" "$test_root/inbox/Epsilon_2005.iso"
touch "$test_root/allow-f"
if wait "$worker_f_pid"; then
  echo "❌ A replaced source was reported as successfully converted." >&2
  exit 1
fi
worker_f_pid=""
[[ -f "$test_root/inbox/Epsilon_2005.iso" ]]
[[ ! -e "$test_root/inbox/_Processed/Epsilon_2005.iso" ]]
jq -e '
  (.sources["Epsilon_2005.iso"].status == "source-changed")
  and (.sources["Epsilon_2005.iso"] | has("lease") | not)
' "$test_root/state/queue.json" >/dev/null

printf '{definitely not valid queue json\n' >"$test_root/state/queue.json"
cp "$test_root/state/queue.json" "$test_root/corrupt-queue.original"
if run_worker f >"$test_root/corrupt-state.log" 2>&1; then
  echo "❌ A corrupt durable queue was treated as an empty queue." >&2
  exit 1
fi
cmp "$test_root/corrupt-queue.original" "$test_root/state/queue.json" || {
  echo "❌ A failed queue read overwrote durable state." >&2
  exit 1
}

echo "✅ Mkvmaker workers preserve queue integrity, source identity, and exclusive live claims."
