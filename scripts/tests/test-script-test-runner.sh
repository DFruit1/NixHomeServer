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

fixture_repo="$tmpdir/fixture-repo"
mkdir -p "$fixture_repo/scripts/tests" "$fixture_repo/scripts"
cat >"$fixture_repo/scripts/tests/test-common.sh" <<'EOF'
TESTS_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
test_default_host() { printf '%s\n' fixture-host; }
ensure_tools() { :; }
EOF
routes="$tmpdir/routes.txt"
route_log="$tmpdir/route-log"
direct_log="$tmpdir/direct-log"
for suite in test-kanban-owner-alerts.sh test-steward-readonly.sh \
  test-steward-opportunity-scan.sh test-kanban-retry-breaker.sh \
  test-hermes-autonomy.sh test-hermes-autonomy-runtime.sh test-hermes-worker-origin.sh test-hermes-recovered-resume.sh \
  test-hermes-worker-policy.sh test-other-control.sh; do
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
    close(fixture_list); replacing = 1; next
  }
  replacing && /^\)$/ { print ")"; replacing = 0; next }
  !replacing { print }
' scripts/tests/run-script-tests.sh >"$fixture_repo/scripts/tests/run-script-tests.sh"
sed -i "s|^source .*test-common[.]sh.*$|source '$fixture_repo/scripts/tests/test-common.sh'|" \
  "$fixture_repo/scripts/tests/run-script-tests.sh"
cat >"$fixture_repo/scripts/fixture-runner.py" <<'PY'
import json, os, sys
with open(os.environ['ROUTE_LOG'], 'a') as stream:
    stream.write(json.dumps([sys.argv[0], *sys.argv[1:]]) + '\n')
raise SystemExit(int(os.environ.get('ROUTE_STATUS', '0')))
PY
identity_before="${HERMES_KANBAN_TASK:-}|${HERMES_KANBAN_DB:-}|${HERMES_KANBAN_BOARD:-}|${HERMES_KANBAN_RUN_ID:-}|${HERMES_KANBAN_CLAIM_LOCK:-}|${HERMES_DELEGATED_CHILD_CONTEXT:-}|${HERMES_PROFILE_NAME:-}|${HERMES_PROFILE:-}"
if ! env NIXHOMESERVER_DEFAULT_HOST=fixture-host HERMES_FIXTURE_ACTIVE=1 \
  HERMES_ROOT="$fixture_repo" ROUTE_LOG="$route_log" DIRECT_LOG="$direct_log" \
  HERMES_KANBAN_TASK=t_fixture HERMES_KANBAN_DB=/fixture/kanban.db \
  HERMES_KANBAN_BOARD=fixture HERMES_DELEGATED_CHILD_CONTEXT=fixture \
  HERMES_PROFILE=fixture bash "$fixture_repo/scripts/tests/run-script-tests.sh" \
  >"$tmpdir/routes-output" 2>&1; then
  cat "$tmpdir/routes-output" >&2
  exit 1
fi
python3 - "$route_log" "$direct_log" "$fixture_repo" <<'PY'
import json
from pathlib import Path
import sys
routes = [json.loads(line) for line in Path(sys.argv[1]).read_text().splitlines()]
direct = Path(sys.argv[2]).read_text().splitlines()
root = sys.argv[3]
expected = ('test-kanban-owner-alerts.sh', 'test-steward-readonly.sh',
            'test-steward-opportunity-scan.sh', 'test-kanban-retry-breaker.sh',
            'test-hermes-autonomy.sh', 'test-hermes-autonomy-runtime.sh',
            'test-hermes-worker-origin.sh', 'test-hermes-recovered-resume.sh')
assert len(routes) == len(expected), routes
for suite in expected:
    argv = [f'{root}/scripts/fixture-runner.py', '--repo', root, '--suite', f'{root}/scripts/tests/{suite}', '--timeout', '300']
    assert argv in routes, (suite, routes)
assert sorted(direct) == ['test-hermes-worker-policy.sh', 'test-other-control.sh'], direct
PY
if [[ -z "${HERMES_KANBAN_TASK:-}${HERMES_KANBAN_DB:-}${HERMES_KANBAN_BOARD:-}${HERMES_KANBAN_RUN_ID:-}${HERMES_KANBAN_CLAIM_LOCK:-}${HERMES_DELEGATED_CHILD_CONTEXT:-}${HERMES_PROFILE_NAME:-}${HERMES_PROFILE:-}" ]]; then
  : >"$route_log"
  : >"$direct_log"
  env HERMES_FIXTURE_ACTIVE=1 HERMES_ROOT="$fixture_repo" \
    ROUTE_LOG="$route_log" DIRECT_LOG="$direct_log" \
    bash "$fixture_repo/scripts/tests/run-script-tests.sh" >"$tmpdir/unpinned-output" 2>&1
  [[ ! -s "$route_log" ]] || { echo "Unpinned synthetic runner routed through the helper." >&2; exit 1; }
  [[ "$(wc -l <"$direct_log")" -eq 10 ]] || {
    echo "Unpinned synthetic runner did not preserve all direct suite paths." >&2
    exit 1
  }
fi
[[ "$identity_before" == "${HERMES_KANBAN_TASK:-}|${HERMES_KANBAN_DB:-}|${HERMES_KANBAN_BOARD:-}|${HERMES_KANBAN_RUN_ID:-}|${HERMES_KANBAN_CLAIM_LOCK:-}|${HERMES_DELEGATED_CHILD_CONTEXT:-}|${HERMES_PROFILE_NAME:-}|${HERMES_PROFILE:-}" ]] || {
  echo "Runner modified parent identity." >&2
  exit 1
}

# Actual nonzero helper statuses propagate without a direct retry.
: >"$route_log"
: >"$direct_log"
if env NIXHOMESERVER_DEFAULT_HOST=fixture-host HERMES_ROOT="$fixture_repo" ROUTE_LOG="$route_log" DIRECT_LOG="$direct_log" \
  ROUTE_STATUS=23 HERMES_KANBAN_TASK=t_fixture HERMES_KANBAN_DB=/fixture/kanban.db \
  bash "$fixture_repo/scripts/tests/run-script-tests.sh" >"$tmpdir/nonzero-output" 2>&1; then
  echo "A nonzero confined-helper result was treated as success." >&2
  exit 1
fi
[[ "$(wc -l <"$route_log")" -eq 8 && "$(wc -l <"$direct_log")" -eq 2 ]] || {
  echo "A nonzero helper result changed route count or retried directly." >&2
  exit 1
}

# Timeout status propagates through the aggregate runner without a direct retry.
: >"$route_log"
: >"$direct_log"
if env NIXHOMESERVER_DEFAULT_HOST=fixture-host HERMES_ROOT="$fixture_repo" ROUTE_LOG="$route_log" DIRECT_LOG="$direct_log" \
  ROUTE_STATUS=124 HERMES_KANBAN_TASK=t_fixture HERMES_KANBAN_DB=/fixture/kanban.db \
  bash "$fixture_repo/scripts/tests/run-script-tests.sh" >"$tmpdir/timeout-output" 2>&1; then
  echo "A timeout-status confined-helper result was treated as success." >&2
  exit 1
fi
[[ "$(wc -l <"$route_log")" -eq 8 && "$(wc -l <"$direct_log")" -eq 2 ]] || {
  echo "A timeout-status helper result changed route count or retried directly." >&2
  exit 1
}
grep -Fq '8 test script(s) failed' "$tmpdir/timeout-output" || {
  echo "Timeout-status failure did not propagate through all required routes." >&2
  cat "$tmpdir/timeout-output" >&2
  exit 1
}

# Required-helper failures never fall back to direct execution.
: >"$route_log"
: >"$direct_log"
mv "$fixture_repo/scripts/fixture-runner.py" "$tmpdir/fixture-runner.py"
if env NIXHOMESERVER_DEFAULT_HOST=fixture-host HERMES_ROOT="$fixture_repo" ROUTE_LOG="$route_log" DIRECT_LOG="$direct_log" \
  HERMES_KANBAN_TASK=t_fixture HERMES_KANBAN_DB=/fixture/kanban.db \
  bash "$fixture_repo/scripts/tests/run-script-tests.sh" >"$tmpdir/missing-output" 2>&1; then
  echo "A missing required helper was treated as success." >&2
  exit 1
fi
[[ "$(wc -l <"$direct_log")" -eq 2 ]] || {
  echo "A missing helper caused a confined suite to run directly." >&2
  exit 1
}
grep -Fq '8 test script(s) failed' "$tmpdir/missing-output" || {
  echo "Missing helper did not fail all eight required routes." >&2
  cat "$tmpdir/missing-output" >&2
  exit 1
}

echo "✅ Parallel runner preserves failures and confines exactly eight pinned suites."
