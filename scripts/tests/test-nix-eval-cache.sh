#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"
ensure_tools bash sha256sum

test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT
mkdir -p "$test_root/bin"
export EVAL_CACHE_TEST_ROOT="$test_root"
export REPO_NIX_EVAL_CACHE_DIR="$test_root/cache"
cat >"$test_root/bin/nix" <<'STUB'
#!/usr/bin/env bash
printf 'call\n' >>"$EVAL_CACHE_TEST_ROOT/calls"
sleep 0.2
if [[ "${EVAL_CACHE_TEST_FAIL:-0}" == 1 ]]; then
  printf 'evaluation failed\n' >&2
  exit 17
fi
printf '%s|%s|%s\n' "$NIXHOMESERVER_FLAKE_REF_FOR_EVAL" "$NIXHOMESERVER_REPO_ROOT_FOR_EVAL" "${EVAL_CACHE_TEST_MODE:-}"
STUB
make_test_executable "$test_root/bin/nix"
export PATH="$test_root/bin:$PATH"
failures=0
check() {
  if ! "$@"; then
    echo "❌ Cache contract failed: $*" >&2
    failures=$((failures + 1))
  fi
}

# All requests are launched before the fake evaluator finishes. A cache hit
# after waiting must reuse the successful result without duplicate evaluation.
pids=()
for index in {1..8}; do
  nix_eval_with_optional_cache raw 'concurrent-fixture' >"$test_root/result-$index" &
  pids+=("$!")
done
for pid in "${pids[@]}"; do check wait "$pid"; done
check test "$(wc -l <"$test_root/calls")" -eq 1
for index in {2..8}; do check cmp "$test_root/result-1" "$test_root/result-$index"; done

# The evaluator consumes these environment variables, so their values are part
# of result identity even when the textual expression is unchanged.
first="$(nix_eval_with_optional_cache raw 'environment-fixture')"
export NIXHOMESERVER_FLAKE_REF_FOR_EVAL='path:/fixture/another-flake'
second="$(nix_eval_with_optional_cache raw 'environment-fixture')"
check test "$first" != "$second"
export NIXHOMESERVER_REPO_ROOT_FOR_EVAL='/fixture/another-root'
third="$(nix_eval_with_optional_cache raw 'environment-fixture')"
check test "$second" != "$third"

# Generic evaluation helpers also accept expressions depending on operator or
# fixture environment variables outside the repository's fixed root/ref pair.
export EVAL_CACHE_TEST_MODE=first
fourth="$(nix_eval_with_optional_cache raw 'builtins.getEnv "EVAL_CACHE_TEST_MODE"')"
export EVAL_CACHE_TEST_MODE=second
fifth="$(nix_eval_with_optional_cache raw 'builtins.getEnv "EVAL_CACHE_TEST_MODE"')"
check test "$fourth" != "$fifth"
unset EVAL_CACHE_TEST_MODE

# A failing evaluation must propagate its status and leave no reusable entry.
export EVAL_CACHE_TEST_FAIL=1
if nix_eval_with_optional_cache raw 'failure-fixture' >"$test_root/failed-result"; then
  echo '❌ Failed evaluation was reported as successful.' >&2
  failures=$((failures + 1))
fi
export EVAL_CACHE_TEST_FAIL=0
recovered="$(nix_eval_with_optional_cache raw 'failure-fixture')"
check test -n "$recovered"

if ((failures)); then exit 1; fi
echo '✅ Nix evaluation caching coalesces misses, tracks its environment, and propagates failures.'
