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

# Pinned worker runs must route each exact synthetic suite through the confined
# helper. Replace that one executable in a copy so the test records dispatches.
routes="$tmpdir/routes.txt"
printf '%s\n' scripts/tests/test-kanban-owner-alerts.sh scripts/tests/test-steward-readonly.sh scripts/tests/test-steward-opportunity-scan.sh scripts/tests/test-kanban-retry-breaker.sh >"$routes"
route_runner="$tmpdir/route-runner.sh"
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
' scripts/tests/run-script-tests.sh >"$route_runner"
sed -i "s|^source .*test-common[.]sh.*$|source '$TESTS_REPO_ROOT/scripts/tests/test-common.sh'|" "$route_runner"
sed -i "s|/home/dsaw/.hermes/scripts/fixture-runner[.]py|$tmpdir/fixture-runner.py|g" "$route_runner"
cat >"$tmpdir/fixture-runner.py" <<'PY'
import json, os, sys
with open(os.environ['ROUTE_LOG'], 'a') as f:
    f.write(json.dumps(sys.argv[1:]) + '\n')
sys.exit(int(os.environ.get('ROUTE_STATUS', '0')))
PY
route_log="$tmpdir/route-log"
identity_before="${HERMES_KANBAN_TASK:-}|${HERMES_KANBAN_DB:-}|${HERMES_KANBAN_BOARD:-}|${HERMES_DELEGATED_CHILD_CONTEXT:-}|${HERMES_PROFILE:-}"
if ! env NIXHOMESERVER_DEFAULT_HOST=fixture-host ROUTE_LOG="$route_log" HERMES_KANBAN_TASK=t_fixture HERMES_KANBAN_DB=/fixture/kanban.db HERMES_KANBAN_BOARD=fixture HERMES_DELEGATED_CHILD_CONTEXT=fixture HERMES_PROFILE=fixture bash "$route_runner" >"$tmpdir/routes-output" 2>&1; then
  cat "$tmpdir/routes-output" >&2
  exit 1
fi
[[ "$(wc -l <"$route_log")" -eq 4 ]] || { echo "Expected four confined suite invocations." >&2; cat "$route_log" >&2; exit 1; }
python3 - "$route_log" "$TESTS_REPO_ROOT" <<'PY'
import json
from pathlib import Path
import sys
rows = [json.loads(line) for line in Path(sys.argv[1]).read_text().splitlines()]
root = sys.argv[2]
suites = ('test-kanban-owner-alerts.sh', 'test-steward-readonly.sh',
          'test-steward-opportunity-scan.sh', 'test-kanban-retry-breaker.sh')
assert len(rows) == 4, rows
for suite in suites:
    assert any(row == ['--repo', root, '--suite', f'{root}/scripts/tests/{suite}',
                       '--timeout', '300'] for row in rows), (suite, rows)
PY
identity_after="${HERMES_KANBAN_TASK:-}|${HERMES_KANBAN_DB:-}|${HERMES_KANBAN_BOARD:-}|${HERMES_DELEGATED_CHILD_CONTEXT:-}|${HERMES_PROFILE:-}"
[[ "$identity_before" == "$identity_after" ]] || { echo "Runner modified parent identity." >&2; exit 1; }
if env NIXHOMESERVER_DEFAULT_HOST=fixture-host ROUTE_LOG="$route_log" ROUTE_STATUS=126 HERMES_KANBAN_TASK=t_fixture HERMES_KANBAN_DB=/fixture/kanban.db HERMES_PROFILE=fixture bash "$route_runner" >"$tmpdir/refused-output" 2>&1; then
  echo "A refused helper was treated as success." >&2
  exit 1
fi
if ! grep -Eq '4 test script\(s\) failed' "$tmpdir/refused-output"; then
  echo "A refused helper did not propagate through the runner." >&2
  cat "$tmpdir/refused-output" >&2
  exit 1
fi

echo "✅ Parallel runner preserves failures and confines the exact four pinned suites."
