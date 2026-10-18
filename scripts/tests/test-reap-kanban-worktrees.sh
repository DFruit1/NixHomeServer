#!/usr/bin/env bash
# Regression test for the fail-closed worktree-reaper pause.
# All invocations use copied candidate bytes under a synthetic fixture root.

set -euo pipefail

TESTS_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$TESTS_REPO_ROOT/scripts/tests/test-common.sh"
ensure_tools bash

root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT
mkdir -p "$root/scripts/hermes" "$root/bin" "$root/.worktrees/protected"
printf 'preserve-this-sentinel\n' >"$root/.worktrees/protected/sentinel"
cp "$TESTS_REPO_ROOT/scripts/hermes/reap-kanban-worktrees.sh" "$root/scripts/hermes/"
reap="$root/scripts/hermes/reap-kanban-worktrees.sh"
call_log="$root/external-calls"
assert_sentinel() {
  [[ "$(<"$root/.worktrees/protected/sentinel")" == 'preserve-this-sentinel' ]] \
    || { echo "❌ $1 changed the protected sentinel" >&2; exit 1; }
}

for tool in git hermes jq flock du realpath rm awk cut dirname pwd; do
  cat >"$root/bin/$tool" <<'STUB'
#!/bin/bash
printf '%s\n' "${0##*/}" >>"$CALL_LOG"
exit 97
STUB
  chmod +x "$root/bin/$tool"
done
cat >"$root/bin/cat" <<'STUB'
#!/bin/bash
echo "${0##*/}" >>"$CALL_LOG"
while IFS= read -r line || [[ -n "$line" ]]; do
  echo "$line"
done
STUB
chmod +x "$root/bin/cat"

expect_refusal() {
  local name="$1" expected_status="$2" stdout="$root/$1.stdout" stderr="$root/$1.stderr"
  shift 2
  : >"$call_log"
  set +e
  PATH="$root/bin" CALL_LOG="$call_log" "$BASH" "$reap" "$@" >"$stdout" 2>"$stderr"
  local status=$?
  set -e
  [[ "$status" -eq "$expected_status" ]] \
    || { printf '❌ %s exited %s, expected %s\n' "$name" "$status" "$expected_status" >&2; exit 1; }
  if [[ "$expected_status" -eq 2 ]]; then
    grep -Fxq 'Worktree reaping paused: ownership and retained-use clearance are not established.' "$stderr" \
      || { cat "$stderr" >&2; echo "❌ $name missing stable pause diagnostic" >&2; exit 1; }
    ! grep -Eq 'Reapable|--apply' "$stdout" "$stderr" \
      || { echo "❌ $name emitted a reclaim summary or retry instruction" >&2; exit 1; }
  fi
  [[ ! -s "$call_log" ]] || { cat "$call_log" >&2; echo "❌ $name made an external call" >&2; exit 1; }
  assert_sentinel "$name"
}

expect_invalid() {
  local name="$1"
  shift
  : >"$call_log"
  set +e
  PATH="$root/bin" CALL_LOG="$call_log" "$BASH" "$reap" "$@" >"$root/$name.stdout" 2>"$root/$name.stderr"
  local status=$?
  set -e
  [[ "$status" -ne 0 ]] || { echo "❌ $name was accepted" >&2; exit 1; }
  [[ -z "$(<"$call_log")" || "$(<"$call_log")" == cat ]] || { cat "$call_log" >&2; echo "❌ $name made an unexpected external call" >&2; exit 1; }
  assert_sentinel "$name"
}

echo "▶ kanban worktree reaper pause contract"

for args in \
  '' \
  '--dry-run' \
  '--bytes' \
  '--board fixture' \
  '--apply' \
  '--apply --bytes --board fixture' \
  '--apply --dry-run' \
  '--dry-run --apply'; do
  # Intentional word splitting supplies the CLI argument vector from this fixture table.
  # shellcheck disable=SC2086
  expect_refusal "operational-${args// /-}" 2 $args
  echo "  ✅ refused operational arguments: ${args:-default}"
done

for help_flag in --help -h; do
  : >"$call_log"
  set +e
  PATH="$root/bin" CALL_LOG="$call_log" "$BASH" "$reap" "$help_flag" >"$root/help.stdout" 2>"$root/help.stderr"
  status=$?
  set -e
  [[ "$status" -eq 0 ]] || { echo "❌ $help_flag exited $status" >&2; exit 1; }
  grep -q '^Usage:' "$root/help.stdout" || { echo "❌ $help_flag omitted usage" >&2; exit 1; }
  [[ "$(<"$call_log")" == cat ]] || { printf '%s\\n' "$(<"$call_log")" >&2; echo "❌ $help_flag made an unexpected external call" >&2; exit 1; }
  assert_sentinel "$help_flag"
done

expect_invalid invalid-option --unknown
expect_invalid missing-board-value --board

echo "  ✅ help and invalid arguments are safe; invalid input does not mutate"
echo "✅ kanban worktree reaper pause contract passed"
