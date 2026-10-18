#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$repo_root/scripts/helpers/remote-build.sh"
fail() { echo "❌ $1" >&2; exit 1; }
spy_dir="$(mktemp -d "${TMPDIR:-/tmp}/remote-build-strict.XXXXXX")"
fixture_repo="$(mktemp -d "${TMPDIR:-/tmp}/remote-build-tree.XXXXXX")"
trap 'rm -rf "$spy_dir" "$fixture_repo"' EXIT
mkdir -p "$fixture_repo"
printf 'manifest fixture\n' >"$fixture_repo/tracked.txt"
git -C "$fixture_repo" init -q
git -C "$fixture_repo" -c user.name=test -c user.email=test@example.invalid add .
git -C "$fixture_repo" -c user.name=test -c user.email=test@example.invalid commit -qm fixture
manifest="$(strict_tree_manifest "$fixture_repo")"
[[ "$manifest" =~ ^[0-9a-f]{64}$ ]] || fail "strict manifest did not return a digest"
mkdir "$fixture_repo/extracted"
cp "$fixture_repo/tracked.txt" "$fixture_repo/extracted/tracked.txt"
extracted_manifest="$(strict_extracted_manifest "$fixture_repo/extracted")"
[[ "$manifest" == "$extracted_manifest" ]] || fail "strict source/extracted manifests differ"
printf 'untracked\n' >"$fixture_repo/extracted/extra.txt"
if [[ "$(strict_extracted_manifest "$fixture_repo/extracted")" == "$manifest" ]]; then
  fail "strict extracted manifest accepted an extra file"
fi
rm -rf "$fixture_repo/extracted"
mkdir -p "$fixture_repo/scripts/helpers"
cp "$repo_root/scripts/helpers/repo-common.sh" "$repo_root/scripts/helpers/remote-eval.sh" \
  "$repo_root/scripts/helpers/remote-build.sh" "$repo_root/scripts/helpers/deploy-archive-cleanup.sh" \
  "$fixture_repo/scripts/helpers/"
git -C "$fixture_repo" add scripts/helpers
git -C "$fixture_repo" -c user.name=test -c user.email=test@example.invalid commit -qm helpers
source "$fixture_repo/scripts/helpers/repo-common.sh"
fixture_head="$(git -C "$fixture_repo" rev-parse HEAD)"
fixture_tree="$(git -C "$fixture_repo" rev-parse 'HEAD^{tree}')"
NIXHOMESERVER_REQUIRE_REMOTE=1 \
  NIXHOMESERVER_EXPECTED_HEAD="$fixture_head" \
  NIXHOMESERVER_EXPECTED_TREE="$fixture_tree" \
  NIXHOMESERVER_EVIDENCE_DIR="$fixture_repo/.tmp/evidence" \
  strict_remote_preflight 1 || fail "strict preflight rejected a clean declared fixture"
printf 'receipt fixture\n' >"$fixture_repo/.tmp/evidence/phase.json"
printf 'synthetic output\n' >"$fixture_repo/.tmp/evidence/output.log"
HERMES_KANBAN_TASK=t_test \
  HERMES_KANBAN_BOARD=fixture \
  HERMES_KANBAN_RUN_ID=run-test \
  NIXHOMESERVER_EVIDENCE_DIR="$fixture_repo/.tmp/evidence" \
  NIXHOMESERVER_EXPECTED_HEAD="$fixture_head" \
  NIXHOMESERVER_EXPECTED_TREE="$fixture_tree" \
  strict_write_phase_receipt test-phase fixture-host \
    '{"hostname":"fixture.example.invalid","system":"Linux test"}' \
    "$manifest" archive-digest helper-digest '["nix","build"]' 'echo fixture' \
    0 "$fixture_repo/.tmp/evidence/output.log" "" success || fail "strict receipt could not be written"
jq -e '.task == "t_test" and .board == "fixture" and .run == "run-test" and .exit_status == 0 and .cleanup == "success" and .actual_host == "fixture.example.invalid" and .argv == ["nix","build"] and .snippet_sha256 != null' \
  "$fixture_repo/.tmp/evidence/test-phase.receipt.json" >/dev/null || fail "strict receipt omitted required fixture evidence"
NIXHOMESERVER_REQUIRE_REMOTE=1 \
  NIXHOMESERVER_EXPECTED_HEAD="$fixture_head" \
  NIXHOMESERVER_EXPECTED_TREE="$fixture_tree" \
  NIXHOMESERVER_EVIDENCE_DIR="$fixture_repo/.tmp/evidence" \
  strict_remote_verify_identity || fail "strict identity check rejected its own evidence files"
printf 'modified source\n' >"$fixture_repo/tracked.txt"
if NIXHOMESERVER_REQUIRE_REMOTE=1 \
    NIXHOMESERVER_EXPECTED_HEAD="$fixture_head" \
    NIXHOMESERVER_EXPECTED_TREE="$fixture_tree" \
    NIXHOMESERVER_EVIDENCE_DIR="$fixture_repo/.tmp/evidence" \
    strict_remote_verify_identity >/dev/null 2>&1; then
  fail "strict identity check accepted source mutation"
fi
git -C "$fixture_repo" checkout -- tracked.txt
NIXHOMESERVER_REQUIRE_REMOTE=1 \
  NIXHOMESERVER_EXPECTED_HEAD="$fixture_head" \
  NIXHOMESERVER_EXPECTED_TREE="$fixture_tree" \
  NIXHOMESERVER_EVIDENCE_DIR="$fixture_repo/.tmp/evidence" \
  strict_remote_verify_identity || fail "strict identity check did not recover after fixture restore"
printf 'untracked source\n' >"$fixture_repo/untracked.txt"
if NIXHOMESERVER_REQUIRE_REMOTE=1 \
    NIXHOMESERVER_EXPECTED_HEAD="$fixture_head" \
    NIXHOMESERVER_EXPECTED_TREE="$fixture_tree" \
    NIXHOMESERVER_EVIDENCE_DIR="$fixture_repo/.tmp/evidence" \
    strict_remote_preflight 1 >/dev/null 2>&1; then
  fail "strict preflight accepted an untracked source input"
fi
rm -rf "$fixture_repo/.tmp" "$fixture_repo/untracked.txt"

git -C "$fixture_repo" config user.name test
cat >"$spy_dir/nix" <<'EOF'
#!/usr/bin/env bash
if [[ "${NIXHOMESERVER_REMOTE_EVAL_NEED_TARGET:-0}" == 1 ]]; then
  printf 'CONFIG nix %s\n' "$*" >>"$BUILD_SPY"
  printf '{"localAdminUser":"fake","serverLanIP":"192.0.2.4"}\n'
elif [[ "${FAKE_REMOTE_CONTEXT:-0}" == 1 ]]; then
  printf 'REMOTE nix %s\n' "$*" >>"$BUILD_SPY"
  case "${STRICT_BUILD_PAYLOAD:-valid}" in
    valid) printf '[{"outputs":{"out":"/nix/store/00000000000000000000000000000000-check"}}]\n' ;;
    empty) printf '[]\n' ;;
    malformed) printf 'not-json\n' ;;
    nonzero) printf 'remote build failed\n' >&2; exit 42 ;;
  esac
  if [[ -n "${FAKE_SOURCE_MUTATE:-}" ]]; then printf 'mutated during remote build\\n' >"$FAKE_SOURCE_MUTATE"; fi
elif [[ "${STRICT_BUILD_MOCK:-0}" == 1 ]]; then
  printf 'LOCAL nix %s\n' "$*" >>"$BUILD_SPY"
  printf '[{"outputs":{"out":"/nix/store/00000000000000000000000000000000-check"}}]\n'
else
  printf 'LOCAL nix %s\n' "$*" >>"$BUILD_SPY"
  printf '[]\n'
fi
EOF
cat >"$spy_dir/ssh" <<'EOF'
#!/usr/bin/env bash
while (($#)); do
  case "$1" in
    -o) shift 2 ;;
    -T) shift ;;
    -*) shift ;;
    *) break ;;
  esac
done
host="$1"; shift
[[ "$host" == fake-server || "$host" == fake@192.0.2.4 ]] || exit 91
if [[ "${1:-}" == "true" ]]; then exit 0; fi
if [[ "${1:-}" == "hostname" ]]; then printf 'fixture.example.invalid\n'; exit 0; fi
if [[ "${1:-}" == "uname" ]]; then printf 'Linux fixture 1.0 x86_64\n'; exit 0; fi
if [[ $# == 1 && "$1" == "mktemp -d /tmp/nixhomeserver-remote-build."* ]]; then
  dir="$(mktemp -d "$FAKE_REMOTE_ROOT/run.XXXXXX")"
  printf '%s\n' "$dir"
  exit 0
fi
if [[ "${1:-}" == "bash" ]]; then
  if [[ -n "${FAKE_REMOTE_EXIT:-}" ]]; then exit "$FAKE_REMOTE_EXIT"; fi
  if [[ "${FAKE_CLEANUP_FAIL:-0}" == 1 ]]; then
    PATH="$FAKE_REMOTE_ROOT/bin:$PATH" FAKE_REMOTE_CONTEXT=1 exec bash "$@"
  fi
  FAKE_REMOTE_CONTEXT=1 exec bash "$@"
fi
if [[ $# == 1 ]]; then
  if [[ -n "${FAKE_REMOTE_EXIT:-}" ]]; then exit "$FAKE_REMOTE_EXIT"; fi
  if [[ "${FAKE_CLEANUP_FAIL:-0}" == 1 ]]; then
    PATH="$FAKE_REMOTE_ROOT/bin:$PATH" FAKE_REMOTE_CONTEXT=1 exec bash -c "$1"
  fi
  FAKE_REMOTE_CONTEXT=1 exec bash -c "$1"
fi
exit 92
EOF
chmod +x "$spy_dir/nix" "$spy_dir/ssh"
cat >"$spy_dir/tar" <<'EOF'
#!/usr/bin/env bash
/usr/bin/tar "$@"
status=$?
if [[ "$status" == 0 && "${FAKE_MANIFEST_MISMATCH:-0}" == 1 && "${1:-}" == -C ]]; then
  printf 'manifest mutation\\n' >>"$2/tracked.txt"
fi
exit "$status"
EOF
chmod +x "$spy_dir/tar"
if PATH="$spy_dir:$PATH" BUILD_SPY="$spy_dir/calls" NIXHOMESERVER_REQUIRE_REMOTE=1 \
    NIXHOMESERVER_EXPECTED_HEAD='' NIXHOMESERVER_EXPECTED_TREE='' \
    NIXHOMESERVER_EVIDENCE_DIR='' remote_build_flake .#checks.demo >/dev/null 2>&1; then
  fail "strict build accepted missing identity"
fi
[[ ! -s "$spy_dir/calls" ]] || fail "strict preflight invoked local or remote work"
if PATH="$spy_dir:$PATH" BUILD_SPY="$spy_dir/calls" NIXHOMESERVER_REQUIRE_REMOTE=1 \
    REMOTE_BUILD=0 remote_build_flake .#checks.demo >/dev/null 2>&1; then
  fail "strict build accepted local opt-out"
fi
[[ ! -s "$spy_dir/calls" ]] || fail "strict opt-out invoked local or remote work"
out="$(PATH="$spy_dir:$PATH" BUILD_SPY="$spy_dir/calls" REMOTE_BUILD=0 remote_build_flake .#checks.demo)"
[[ "$out" == '[]' ]] || fail "ordinary local build behavior changed"
grep -q '^LOCAL nix build' "$spy_dir/calls" || fail "ordinary opt-out did not run nix build"

source "$fixture_repo/scripts/helpers/remote-build.sh"
remote_build_host=fake-server
fixture_remote="$spy_dir/remote"
mkdir -p "$fixture_remote/bin"
cat >"$fixture_remote/bin/rm" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
for arg in "$@"; do
  if [[ "$arg" == "$FAKE_REMOTE_ROOT"/run.* ]]; then
    exit 45
  fi
done
exec /bin/rm "$@"
EOF
chmod +x "$fixture_remote/bin/rm"
stage_archive_on_remote() {
  [[ "${FAKE_STAGE_MODE:-ok}" != fail ]] || return 1
  cp "$1" "$fixture_remote/source.tar"
  if [[ "${FAKE_STAGE_MODE:-ok}" == corrupt ]]; then printf 'corrupt' >>"$fixture_remote/source.tar"; fi
  printf '%s\n' "$fixture_remote/source.tar"
}
: >"$spy_dir/calls"
strict_out="$(cd "$fixture_repo" && PATH="$spy_dir:$PATH" BUILD_SPY="$spy_dir/calls" \
  STRICT_BUILD_MOCK=1 FAKE_REMOTE_ROOT="$fixture_remote" HERMES_KANBAN_TASK=t_fixture \
  HERMES_KANBAN_BOARD=fixture HERMES_KANBAN_RUN_ID=r_fixture NIXHOMESERVER_REQUIRE_REMOTE=1 \
  NIXHOMESERVER_EXPECTED_HEAD="$fixture_head" NIXHOMESERVER_EXPECTED_TREE="$fixture_tree" \
  NIXHOMESERVER_EVIDENCE_DIR="$fixture_repo/.tmp/evidence" \
  remote_build_flake .#checks.fixture)"
[[ "$(jq -r '.[0].outputs.out' <<<"$strict_out")" == /nix/store/00000000000000000000000000000000-check ]] || fail "strict remote build lost its output manifest"
receipt="$(printf '%s\n' "$fixture_repo"/.tmp/evidence/build-*.receipt.json)"
jq -e '.task == "t_fixture" and .board == "fixture" and .run == "r_fixture" and .exit_status == 0 and .cleanup == "success" and .actual_host == "fixture.example.invalid" and .actual_system == "Linux fixture 1.0 x86_64" and (.argv | index(".#checks.fixture") != null)' "$receipt" >/dev/null || fail "strict build receipt is incomplete"
grep -q '^REMOTE nix build ' "$spy_dir/calls" && grep -q -- '--json' "$spy_dir/calls" \
  || fail "strict build did not pass JSON-mode argv to Nix"

# The shared configured-target resolver selects the existing remote override.
remote_build_host=""
: >"$spy_dir/calls"
resolved_out="$(cd "$fixture_repo" && PATH="$spy_dir:$PATH" BUILD_SPY="$spy_dir/calls" \
  STRICT_BUILD_MOCK=1 FAKE_REMOTE_ROOT="$fixture_remote" HERMES_KANBAN_TASK=t_fixture \
  HERMES_KANBAN_BOARD=fixture HERMES_KANBAN_RUN_ID=r_fixture \
  NIXHOMESERVER_REQUIRE_REMOTE=1 NIXHOMESERVER_EXPECTED_HEAD="$fixture_head" \
  NIXHOMESERVER_EXPECTED_TREE="$fixture_tree" NIXHOMESERVER_EVIDENCE_DIR="$fixture_repo/.tmp/evidence" \
  remote_build_flake .#checks.resolved)"
jq -e '.[0].outputs.out == "/nix/store/00000000000000000000000000000000-check"' <<<"$resolved_out" >/dev/null \
  || fail "configured target resolution lost remote output"
grep -q '^CONFIG nix eval --json' "$spy_dir/calls" || fail "configured host was not resolved from fixture settings"
remote_build_host=fake-server

expect_strict_failure() {
  local label="$1"; shift
  : >"$spy_dir/calls"
  if (export "$@"; cd "$fixture_repo" && PATH="$spy_dir:$PATH" BUILD_SPY="$spy_dir/calls" \
      FAKE_REMOTE_ROOT="$fixture_remote" \
      HERMES_KANBAN_TASK=t_fixture HERMES_KANBAN_BOARD=fixture HERMES_KANBAN_RUN_ID=r_fixture \
      NIXHOMESERVER_REQUIRE_REMOTE=1 NIXHOMESERVER_EXPECTED_HEAD="$fixture_head" \
      NIXHOMESERVER_EXPECTED_TREE="$fixture_tree" \
      NIXHOMESERVER_EVIDENCE_DIR="$fixture_repo/.tmp/evidence" \
      remote_build_flake .#checks.fixture) >"$spy_dir/$label.out" 2>"$spy_dir/$label.err"; then
    fail "$label unexpectedly succeeded"
  fi
  if grep -q '^LOCAL nix' "$spy_dir/calls"; then
    fail "$label fell back to a local build"
  fi
}

# An explicit strict local opt-out refuses before any build command.
: >"$spy_dir/calls"
if (cd "$fixture_repo" && PATH="$spy_dir:$PATH" BUILD_SPY="$spy_dir/calls" \
    NIXHOMESERVER_REQUIRE_REMOTE=1 REMOTE_BUILD=0 remote_build_flake .#checks.fixture) \
    >/dev/null 2>&1; then fail "strict REMOTE_BUILD=0 was accepted"; fi
[[ ! -s "$spy_dir/calls" ]] || fail "strict REMOTE_BUILD=0 invoked a local build"

# Remote build failures, malformed output, and transfer failures are fail-closed.
for payload in empty malformed nonzero; do
  expect_strict_failure "payload-$payload" "STRICT_BUILD_PAYLOAD=$payload"
done
expect_strict_failure remote-255 FAKE_REMOTE_EXIT=255
expect_strict_failure cleanup-failure FAKE_CLEANUP_FAIL=1
cleanup_receipt="$(printf '%s\n' "$fixture_repo"/.tmp/evidence/build-*.receipt.json | sort | tail -n 1)"
jq -e '.cleanup == "failed" and .exit_status != 0' "$cleanup_receipt" >/dev/null ||
  fail "strict build cleanup failure was not recorded in its receipt"
expect_strict_failure transfer-failure FAKE_STAGE_MODE=fail
expect_strict_failure archive-digest-mismatch FAKE_STAGE_MODE=corrupt
expect_strict_failure extracted-manifest-mismatch FAKE_MANIFEST_MISMATCH=1
expect_strict_failure source-mutation "FAKE_SOURCE_MUTATE=$fixture_repo/tracked.txt"
git -C "$fixture_repo" checkout -- tracked.txt

# Declared commit/tree mismatches refuse before either local or remote work.
for identity in commit tree; do
  : >"$spy_dir/calls"
  if (cd "$fixture_repo" && PATH="$spy_dir:$PATH" BUILD_SPY="$spy_dir/calls" \
      NIXHOMESERVER_REQUIRE_REMOTE=1 \
      NIXHOMESERVER_EXPECTED_HEAD="$([[ "$identity" == commit ]] && printf '%040d' 1 || printf '%s' "$fixture_head")" \
      NIXHOMESERVER_EXPECTED_TREE="$([[ "$identity" == tree ]] && printf '%040d' 2 || printf '%s' "$fixture_tree")" \
      NIXHOMESERVER_EVIDENCE_DIR="$fixture_repo/.tmp/evidence" \
      remote_build_flake .#checks.fixture) >/dev/null 2>&1; then
    fail "strict $identity mismatch was accepted"
  fi
  [[ ! -s "$spy_dir/calls" ]] || fail "strict $identity mismatch invoked a build"
done

echo "✅ remote-build strict failure matrix rejected local fallback and source mismatches"
echo "✅ remote-build strict preflight, synthetic receipt, and ordinary opt-out tests passed"
