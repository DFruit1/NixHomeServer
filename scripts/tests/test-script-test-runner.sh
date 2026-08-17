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

echo "✅ Parallel script-test runner preserves failures reaped at the concurrency limit."
