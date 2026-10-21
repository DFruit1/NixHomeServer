#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"
cd "$TESTS_REPO_ROOT"
ensure_tools awk bash chmod mktemp nproc

tmpdir="$(mktemp -d)"
cleanup() { rm -rf "$tmpdir"; }
trap cleanup EXIT

max_jobs="$(nproc 2>/dev/null || echo 2)"
(( max_jobs > 0 )) || max_jobs=2

failing_test="$tmpdir/test-fails.sh"
cat >"$failing_test" <<'EOF'
#!/usr/bin/env bash
exit 42
EOF
chmod +x "$failing_test"

fixture_list="$tmpdir/fixtures.txt"
printf '%s\n' "$failing_test" >"$fixture_list"
for ((index = 1; index <= max_jobs; index++)); do
  passing_test="$tmpdir/test-passes-$index.sh"
  cat >"$passing_test" <<'EOF'
#!/usr/bin/env bash
sleep 1
exit 0
EOF
  chmod +x "$passing_test"
  printf '%s\n' "$passing_test" >>"$fixture_list"
done

runner_copy="$tmpdir/run-script-tests.sh"
awk -v fixture_list="$fixture_list" '
  /^test_scripts=\($/ {
    print "test_scripts=("
    while ((getline fixture < fixture_list) > 0) {
      printf "  \"%s\"\n", fixture
    }
    close(fixture_list)
    replacing = 1
    next
  }
  replacing && /^\)$/ {
    print ")"
    replacing = 0
    next
  }
  !replacing { print }
' scripts/tests/run-script-tests.sh >"$runner_copy"
chmod +x "$runner_copy"

sed -i \
  "s|^source .*test-common[.]sh.*$|source '$TESTS_REPO_ROOT/scripts/tests/test-common.sh'|" \
  "$runner_copy"

output="$tmpdir/output"
if bash "$runner_copy" >"$output" 2>&1; then
  echo "Parallel script-test runner lost an early child failure while enforcing its concurrency limit." >&2
  cat "$output" >&2
  exit 1
fi

if ! grep -Eq '1 test script\(s\) failed' "$output"; then
  echo "Parallel script-test runner failed without reporting the child failure count." >&2
  cat "$output" >&2
  exit 1
fi

# Exercise confined routing with a private copy of the runner and four synthetic
# suite paths. This keeps the routing test independent of worker-owned suites.
fixture_repo="$tmpdir/repo"
mkdir -p "$fixture_repo/scripts/tests" "$fixture_repo/scripts/helpers"
cat >"$fixture_repo/scripts/tests/test-common.sh" <<'EOF'
TESTS_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
test_default_host() { printf '%s\\n' "${NIXHOMESERVER_DEFAULT_HOST:-fixture-host}"; }
EOF
routes="$tmpdir/routes.txt"
route_log="$tmpdir/route-log"
for suite in test-kanban-owner-alerts.sh test-steward-readonly.sh \
  test-steward-opportunity-scan.sh test-kanban-retry-breaker.sh; do
  printf 'scripts/tests/%s\n' "$suite" >>"$routes"
  cat >"$fixture_repo/scripts/tests/$suite" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${BASH_SOURCE[0]##*/}" >>"$DIRECT_LOG"
EOF
  chmod +x "$fixture_repo/scripts/tests/$suite"
done
awk -v fixture_list="$routes" '
  /^test_scripts=\($/ {
    print "test_scripts=("
    while ((getline fixture < fixture_list) > 0) printf "  \"%s\"\n", fixture
    close(fixture_list)
    replacing = 1
    next
  }
  replacing && /^\)$/ { print ")"; replacing = 0; next }
  !replacing { print }
' scripts/tests/run-script-tests.sh >"$fixture_repo/scripts/tests/run-script-tests.sh"
helper="$tmpdir/fixture-runner.py"
cat >"$helper" <<'PY'
import json, os, sys
with open(os.environ['ROUTE_LOG'], 'a') as stream:
    stream.write(json.dumps(sys.argv[1:]) + '\n')
raise SystemExit(int(os.environ.get('ROUTE_STATUS', '0')))
PY
sed -i \
  "s|^source .*test-common[.]sh.*$|source '$fixture_repo/scripts/tests/test-common.sh'|" \
  "$fixture_repo/scripts/tests/run-script-tests.sh"
sed -i "s|/home/dsaw/.hermes/scripts/fixture-runner[.]py|$helper|g" \
  "$fixture_repo/scripts/tests/run-script-tests.sh"

identity_before="${HERMES_KANBAN_TASK:-}|${HERMES_KANBAN_DB:-}|${HERMES_KANBAN_BOARD:-}|${HERMES_DELEGATED_CHILD_CONTEXT:-}|${HERMES_PROFILE:-}"
if ! env NIXHOMESERVER_DEFAULT_HOST=fixture-host ROUTE_LOG="$route_log" \
  HERMES_KANBAN_TASK=t_fixture HERMES_KANBAN_DB=/fixture/kanban.db \
  HERMES_KANBAN_BOARD=fixture HERMES_DELEGATED_CHILD_CONTEXT=fixture \
  HERMES_PROFILE=fixture bash "$fixture_repo/scripts/tests/run-script-tests.sh" \
  >"$tmpdir/routes-output" 2>&1; then
  cat "$tmpdir/routes-output" >&2
  exit 1
fi
[[ "$(wc -l <"$route_log")" -eq 4 ]] || {
  echo "Expected exactly four confined suite invocations." >&2
  cat "$route_log" >&2
  exit 1
}
python3 - "$route_log" "$fixture_repo" <<'PY'
import json
from pathlib import Path
import sys
rows = [json.loads(line) for line in Path(sys.argv[1]).read_text().splitlines()]
root = sys.argv[2]
suites = ('test-kanban-owner-alerts.sh', 'test-steward-readonly.sh',
          'test-steward-opportunity-scan.sh', 'test-kanban-retry-breaker.sh')
assert len(rows) == 4, rows
for suite in suites:
    expected = ['--repo', root, '--suite', f'{root}/scripts/tests/{suite}', '--timeout', '300']
    assert expected in rows, (suite, rows)
PY
identity_after="${HERMES_KANBAN_TASK:-}|${HERMES_KANBAN_DB:-}|${HERMES_KANBAN_BOARD:-}|${HERMES_DELEGATED_CHILD_CONTEXT:-}|${HERMES_PROFILE:-}"
[[ "$identity_before" == "$identity_after" ]] || {
  echo "Runner modified parent identity." >&2
  exit 1
}

# Unpinned CI must use direct execution without depending on the helper.
: >"$route_log"
: >"$tmpdir/direct-log"
if ! env -u HERMES_KANBAN_TASK -u HERMES_KANBAN_DB -u HERMES_KANBAN_BOARD \
  -u HERMES_KANBAN_RUN_ID -u HERMES_KANBAN_CLAIM_LOCK \
  -u HERMES_DELEGATED_CHILD_CONTEXT -u HERMES_PROFILE_NAME -u HERMES_PROFILE \
  NIXHOMESERVER_DEFAULT_HOST=fixture-host DIRECT_LOG="$tmpdir/direct-log" \
  ROUTE_LOG="$route_log" bash "$fixture_repo/scripts/tests/run-script-tests.sh" \
  >"$tmpdir/direct-output" 2>&1; then
  cat "$tmpdir/direct-output" >&2
  exit 1
fi
[[ ! -s "$route_log" && "$(wc -l <"$tmpdir/direct-log")" -eq 4 ]] || {
  echo "Unpinned CI did not directly execute all four suites." >&2
  exit 1
}

# A missing required helper fails closed and never falls back to direct tests.
: >"$tmpdir/direct-log"
sed -i "s|$helper|$tmpdir/absent-fixture-runner.py|g" \
  "$fixture_repo/scripts/tests/run-script-tests.sh"
if env NIXHOMESERVER_DEFAULT_HOST=fixture-host DIRECT_LOG="$tmpdir/direct-log" \
  HERMES_KANBAN_TASK=t_fixture HERMES_KANBAN_DB=/fixture/kanban.db \
  bash "$fixture_repo/scripts/tests/run-script-tests.sh" >"$tmpdir/missing-output" 2>&1; then
  echo "A missing required helper was treated as success." >&2
  exit 1
fi
if ! grep -Eq '4 test script\(s\) failed' "$tmpdir/missing-output" ||
   [[ -s "$tmpdir/direct-log" ]]; then
  echo "A missing helper did not fail closed." >&2
  cat "$tmpdir/missing-output" >&2
  exit 1
fi

echo "✅ Parallel runner preserves failures, confines pinned suites, and keeps ordinary CI direct."
