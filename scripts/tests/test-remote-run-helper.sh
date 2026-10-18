#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$repo_root/scripts/helpers/remote-run.sh"
fail() { echo "❌ $1" >&2; exit 1; }
spy_dir="$(mktemp -d "${TMPDIR:-/tmp}/remote-run-strict.XXXXXX")"
trap 'rm -rf "$spy_dir"' EXIT
cat >"$spy_dir/ssh" <<'EOF'
#!/usr/bin/env bash
printf 'ssh\n' >>"$RUN_SPY"
exit 99
EOF
chmod +x "$spy_dir/ssh"
if PATH="$spy_dir:$PATH" RUN_SPY="$spy_dir/calls" NIXHOMESERVER_REQUIRE_REMOTE=1 \
    NIXHOMESERVER_EXPECTED_HEAD='' NIXHOMESERVER_EXPECTED_TREE='' \
    NIXHOMESERVER_EVIDENCE_DIR='' remote_run 'printf local' >/dev/null 2>&1; then
  fail "strict run accepted missing identity"
fi
[[ ! -s "$spy_dir/calls" ]] || fail "strict preflight contacted SSH"
if PATH="$spy_dir:$PATH" RUN_SPY="$spy_dir/calls" NIXHOMESERVER_REQUIRE_REMOTE=1 \
    REMOTE_RUN=0 remote_run 'printf local' >/dev/null 2>&1; then
  fail "strict run accepted local opt-out"
fi
[[ ! -s "$spy_dir/calls" ]] || fail "strict opt-out contacted SSH"
out="$(PATH="$spy_dir:$PATH" REMOTE_RUN=0 remote_run 'printf "%s" "$1"')"
[[ "$out" == "$repo_root" ]] || fail "ordinary local snippet behavior changed"

# Exercise the complete strict execution boundary with an isolated committed
# fixture and a synthetic SSH endpoint; no host connection or Nix is used.
fixture_repo="$(mktemp -d "$spy_dir/source.XXXXXX")"
fixture_remote="$spy_dir/remote"
mkdir -p "$fixture_repo/scripts/helpers" "$fixture_remote/archive" "$fixture_repo/scripts/tests"
chmod 0700 "$fixture_remote/archive"
printf 'fixture source\n' >"$fixture_repo/tracked.txt"
cp "$repo_root/scripts/helpers/repo-common.sh" "$repo_root/scripts/helpers/remote-eval.sh" \
  "$repo_root/scripts/helpers/remote-run.sh" "$repo_root/scripts/helpers/deploy-archive-cleanup.sh" \
  "$fixture_repo/scripts/helpers/"
git -C "$fixture_repo" init -q
git -C "$fixture_repo" -c user.name=test -c user.email=test@example.invalid add .
git -C "$fixture_repo" -c user.name=test -c user.email=test@example.invalid commit -qm fixture
fixture_head="$(git -C "$fixture_repo" rev-parse HEAD)"
fixture_tree="$(git -C "$fixture_repo" rev-parse 'HEAD^{tree}')"
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
if [[ -n "${SSH_SPY:-}" ]]; then printf '%s\n' "$*" >>"$SSH_SPY"; fi
[[ "$host" == fake-server || "$host" == fixture@127.0.0.1 ]] || exit 91
if [[ "${FAKE_STAGE_MODE:-}" == fail && "${1:-}" == set\ -e\;\ helper=* ]]; then exit 42; fi
if [[ "${1:-}" == set\ -e\;\ helper=* ]]; then
  helper_file="$(mktemp "$FAKE_REMOTE_ROOT/helper.XXXXXX")"
  cat >"$helper_file"
  chmod 0700 "$helper_file"
  NIXHOMESERVER_DEPLOY_ARCHIVE_NAMESPACE="$FAKE_REMOTE_ROOT/archive" \
    bash "$helper_file" stage nixhomeserver-remote-run
  status=$?
  rm -f "$helper_file"
  exit "$status"
fi
if [[ "${1:-}" == cat\ \>* ]]; then
  target="${1#cat > }"
  mkdir -p "$(dirname "$target")"
  cat >"$target" || exit $?
  if [[ "${FAKE_STAGE_MODE:-}" == corrupt && "$target" == "$FAKE_REMOTE_ROOT/archive/"* ]]; then
    printf 'corrupt' >>"$target"
  fi
  exit 0
fi
if [[ "${1:-}" == rm\ -f\ * ]]; then
  target="${1#rm -f }"
  rm -f -- "$target"
  exit $?
fi
if [[ "${1:-}" == "true" ]]; then
  [[ "${FAKE_SSH_MODE:-}" != unreachable ]] || exit 255
  exit 0
fi
if [[ "${FAKE_SSH_MODE:-}" == remote-255 && "${1:-}" == bash\ -s\ --* ]]; then exit 255; fi
if [[ "${FAKE_SSH_MODE:-}" == remote-42 && "${1:-}" == bash\ -s\ --* ]]; then exit 42; fi
if [[ "${FAKE_SSH_MODE:-}" == mutate-source && "${1:-}" == bash\ -s\ --* ]]; then
  printf 'mutated fixture source\\n' >"$FIXTURE_REPO/tracked.txt"
fi
if [[ $# == 1 && "$1" == "mktemp -d /tmp/nixhomeserver-remote-run."* ]]; then
  dir="$(mktemp -d "$FAKE_REMOTE_ROOT/run.XXXXXX")"
  printf '%s\n' "$dir" >"$FAKE_REMOTE_ROOT/active"
  printf '%s\n' "$dir"
  exit 0
fi
if [[ $# == 1 && "$1" == cat* ]]; then
  dir="$(<"$FAKE_REMOTE_ROOT/active")"
  exec cat >"$dir/${1##*/}"
fi
if [[ "${1:-}" == "hostname" ]]; then printf 'fixture.example.invalid\n'; exit 0; fi
if [[ "${1:-}" == "uname" ]]; then printf 'Linux fixture 1.0 x86_64\n'; exit 0; fi
if [[ "${1:-}" == "mktemp" ]]; then
  dir="$(mktemp -d "$FAKE_REMOTE_ROOT/run.XXXXXX")"
  printf '%s\n' "$dir"
  exit 0
fi
if [[ "${1:-}" == "bash" ]]; then exec bash "$@"; fi
if [[ $# == 1 ]]; then exec bash -c "$1"; fi
exit 92
EOF
chmod +x "$spy_dir/ssh"
cat >"$spy_dir/nix" <<'EOF'
#!/usr/bin/env bash
if [[ "${NIXHOMESERVER_REMOTE_EVAL_NEED_TARGET:-0}" == 1 ]]; then
  printf 'CONFIG nix %s\n' "$*" >>"$RUN_SPY"
  printf '{"localAdminUser":"fixture","serverLanIP":"127.0.0.1"}\n'
  exit 0
fi
printf 'FORBIDDEN nix %s\\n' "$*" >>"$RUN_SPY"
exit 93
EOF
for command_name in cargo chromium chromium-browser google-chrome playwright; do
  cat >"$spy_dir/$command_name" <<'EOF'
#!/usr/bin/env bash
printf 'FORBIDDEN %s %s\\n' "${0##*/}" "$*" >>"$RUN_SPY"
exit 97
EOF
  chmod +x "$spy_dir/$command_name"
done
chmod +x "$spy_dir/nix"
cat >"$spy_dir/tar" <<'EOF'
#!/usr/bin/env bash
"$REAL_TAR" "$@" || exit $?
if [[ "${FAKE_TAR_MODE:-}" == mutate && "${1:-}" == -C ]]; then
  printf 'changed extraction\\n' >>"$2/tracked.txt"
fi
EOF
chmod +x "$spy_dir/tar"
REAL_TAR="$(command -v tar)"
export REAL_TAR
source "$fixture_repo/scripts/helpers/remote-run.sh"
remote_run_host=fake-server
run_output="$(cd "$fixture_repo" && PATH="$spy_dir:$PATH" FAKE_REMOTE_ROOT="$fixture_remote" \
  HERMES_KANBAN_TASK=t_fixture HERMES_KANBAN_BOARD=fixture HERMES_KANBAN_RUN_ID=r_fixture \
  NIXHOMESERVER_REQUIRE_REMOTE=1 NIXHOMESERVER_EXPECTED_HEAD="$fixture_head" \
  NIXHOMESERVER_EXPECTED_TREE="$fixture_tree" NIXHOMESERVER_EVIDENCE_DIR="$fixture_repo/.tmp/evidence" \
  remote_run 'printf synthetic-result; printf synthetic-diagnostic >&2')"
[[ "$run_output" == 'synthetic-result' ]] || fail "strict remote result was not returned"
receipt="$(printf '%s\n' "$fixture_repo"/.tmp/evidence/run-*.receipt.json)"
[[ -f "$receipt" ]] || fail "strict run did not write a phase receipt"
jq -e '.task == "t_fixture" and .board == "fixture" and .run == "r_fixture" and .exit_status == 0 and .cleanup == "success" and .actual_host == "fixture.example.invalid" and .actual_system == "Linux fixture 1.0 x86_64" and (.snippet_sha256 | type == "string") and (.output_sha256 | type == "string") and (.stderr_sha256 | type == "string")' "$receipt" >/dev/null || fail "strict run receipt is incomplete"
[[ ! -d "$fixture_remote"/run.* ]] || fail "strict remote run did not clean its staging tree"
: >"$spy_dir/calls"
if cd "$fixture_repo" && PATH="$spy_dir:$PATH" RUN_SPY="$spy_dir/calls" FAKE_REMOTE_ROOT="$fixture_remote" \
  HERMES_KANBAN_TASK=t_fixture HERMES_KANBAN_BOARD=fixture HERMES_KANBAN_RUN_ID=r_fixture \
  NIXHOMESERVER_REQUIRE_REMOTE=1 NIXHOMESERVER_EXPECTED_HEAD="$fixture_head" \
  NIXHOMESERVER_EXPECTED_TREE="$fixture_tree" NIXHOMESERVER_EVIDENCE_DIR="$fixture_repo/.tmp/evidence" \
  remote_run 'true'; then
  fail "strict run accepted an empty output and log payload"
fi
[[ ! -s "$spy_dir/calls" ]] || fail "empty payload invoked a local heavy command"
receipts=("$fixture_repo"/.tmp/evidence/run-*.receipt.json)
[[ ${#receipts[@]} == 2 ]] || {
  printf 'Expected two phase receipts; found %s: %s\\n' "${#receipts[@]}" "${receipts[*]}" >&2
  fail "strict run did not receipt both success and empty-payload attempts"
}
jq -s -e 'any(.[]; .exit_status == 1 and .cleanup == "success")' "${receipts[@]}" >/dev/null \
  || fail "empty-payload failure receipt did not preserve the verified cleanup status"
assert_strict_refusal() {
  local name="$1" mode="$2" snippet="${3:-printf local}" status=0
  : >"$spy_dir/calls"
  if (cd "$fixture_repo" && PATH="$spy_dir:$PATH" RUN_SPY="$spy_dir/calls" \
      FIXTURE_REPO="$fixture_repo" \
      FAKE_REMOTE_ROOT="$fixture_remote" FAKE_SSH_MODE="$mode" \
      HERMES_KANBAN_TASK=t_fixture HERMES_KANBAN_BOARD=fixture HERMES_KANBAN_RUN_ID=r_fixture \
      NIXHOMESERVER_REQUIRE_REMOTE=1 NIXHOMESERVER_EXPECTED_HEAD="$fixture_head" \
      NIXHOMESERVER_EXPECTED_TREE="$fixture_tree" \
      NIXHOMESERVER_EVIDENCE_DIR="$fixture_repo/.tmp/evidence" \
      remote_run "$snippet") >"$spy_dir/$name.out" 2>"$spy_dir/$name.err"; then
    fail "$name unexpectedly succeeded"
  else
    status=$?
  fi
  ((status != 0)) || fail "$name returned success"
  [[ ! -s "$spy_dir/calls" ]] || fail "$name invoked a local evaluator/build/browser/cargo command"
}

for optout in missing-identity invalid-identity missing-evidence; do
  : >"$spy_dir/calls"
  : >"$spy_dir/ssh-calls"
  case "$optout" in
    missing-identity) head=""; tree="$fixture_tree"; evidence="$fixture_repo/.tmp/evidence" ;;
    invalid-identity) head="bad"; tree="$fixture_tree"; evidence="$fixture_repo/.tmp/evidence" ;;
    missing-evidence) head="$fixture_head"; tree="$fixture_tree"; evidence="" ;;
  esac
  if (cd "$fixture_repo" && PATH="$spy_dir:$PATH" RUN_SPY="$spy_dir/calls" SSH_SPY="$spy_dir/ssh-calls" \
      NIXHOMESERVER_REQUIRE_REMOTE=1 NIXHOMESERVER_EXPECTED_HEAD="$head" \
      NIXHOMESERVER_EXPECTED_TREE="$tree" NIXHOMESERVER_EVIDENCE_DIR="$evidence" \
      remote_run 'printf local') >/dev/null 2>&1; then
    fail "strict $optout was accepted"
  fi
  [[ ! -s "$spy_dir/calls" ]] || fail "strict $optout started local work"
  [[ ! -s "$spy_dir/ssh-calls" ]] || fail "strict $optout contacted SSH"
done
for identity in commit tree; do
  : >"$spy_dir/calls"
  : >"$spy_dir/ssh-calls"
  if [[ "$identity" == commit ]]; then
    bad_head=0000000000000000000000000000000000000000
    bad_tree="$fixture_tree"
  else
    bad_head="$fixture_head"
    bad_tree=0000000000000000000000000000000000000000
  fi
  if (cd "$fixture_repo" && PATH="$spy_dir:$PATH" RUN_SPY="$spy_dir/calls" SSH_SPY="$spy_dir/ssh-calls" \
      NIXHOMESERVER_REQUIRE_REMOTE=1 NIXHOMESERVER_EXPECTED_HEAD="$bad_head" \
      NIXHOMESERVER_EXPECTED_TREE="$bad_tree" \
      NIXHOMESERVER_EVIDENCE_DIR="$fixture_repo/.tmp/evidence" \
      remote_run 'printf local') >/dev/null 2>&1; then
    fail "strict $identity mismatch was accepted"
  fi
  [[ ! -s "$spy_dir/calls" ]] || fail "strict $identity mismatch started local work"
  [[ ! -s "$spy_dir/ssh-calls" ]] || fail "strict $identity mismatch contacted SSH"
done

: >"$spy_dir/calls"
remote_run_host=""
resolved_output="$(cd "$fixture_repo" && PATH="$spy_dir:$PATH" RUN_SPY="$spy_dir/calls" \
  FAKE_REMOTE_ROOT="$fixture_remote" NIXHOMESERVER_REMOTE_EVAL_NEED_TARGET=1 \
  HERMES_KANBAN_TASK=t_fixture HERMES_KANBAN_BOARD=fixture HERMES_KANBAN_RUN_ID=r_fixture \
  NIXHOMESERVER_REQUIRE_REMOTE=1 NIXHOMESERVER_EXPECTED_HEAD="$fixture_head" \
  NIXHOMESERVER_EXPECTED_TREE="$fixture_tree" NIXHOMESERVER_EVIDENCE_DIR="$fixture_repo/.tmp/evidence" \
  remote_run 'printf resolved-target')"
[[ "$resolved_output" == resolved-target ]] || fail "configured target resolution lost remote output"
grep -q '^CONFIG nix eval ' "$spy_dir/calls" || fail "strict run did not resolve the configured target"
remote_run_host=fake-server

assert_strict_refusal remote-nonzero remote-42
assert_strict_refusal remote-transport-255 remote-255
assert_strict_refusal remote-empty-payload success 'true'
: >"$spy_dir/calls"
if (cd "$fixture_repo" && PATH="$spy_dir:$PATH" RUN_SPY="$spy_dir/calls" \
    FAKE_STAGE_MODE=fail FAKE_REMOTE_ROOT="$fixture_remote" \
    HERMES_KANBAN_TASK=t_fixture HERMES_KANBAN_BOARD=fixture HERMES_KANBAN_RUN_ID=r_fixture \
    NIXHOMESERVER_REQUIRE_REMOTE=1 NIXHOMESERVER_EXPECTED_HEAD="$fixture_head" \
    NIXHOMESERVER_EXPECTED_TREE="$fixture_tree" NIXHOMESERVER_EVIDENCE_DIR="$fixture_repo/.tmp/evidence" \
    remote_run 'printf local') >/dev/null 2>&1; then
  fail "strict archive transfer failure was accepted"
fi
[[ ! -s "$spy_dir/calls" ]] || fail "archive transfer failure invoked a local heavy command"
: >"$spy_dir/calls"
if (cd "$fixture_repo" && PATH="$spy_dir:$PATH" RUN_SPY="$spy_dir/calls" \
    FAKE_STAGE_MODE=corrupt FAKE_REMOTE_ROOT="$fixture_remote" \
    HERMES_KANBAN_TASK=t_fixture HERMES_KANBAN_BOARD=fixture HERMES_KANBAN_RUN_ID=r_fixture \
    NIXHOMESERVER_REQUIRE_REMOTE=1 NIXHOMESERVER_EXPECTED_HEAD="$fixture_head" \
    NIXHOMESERVER_EXPECTED_TREE="$fixture_tree" NIXHOMESERVER_EVIDENCE_DIR="$fixture_repo/.tmp/evidence" \
    remote_run 'printf local') >/dev/null 2>&1; then
  fail "strict archive digest mismatch was accepted"
fi
[[ ! -s "$spy_dir/calls" ]] || fail "archive digest mismatch invoked a local heavy command"
: >"$spy_dir/calls"
if (cd "$fixture_repo" && PATH="$spy_dir:$PATH" RUN_SPY="$spy_dir/calls" \
    FAKE_TAR_MODE=mutate FAKE_REMOTE_ROOT="$fixture_remote" \
    HERMES_KANBAN_TASK=t_fixture HERMES_KANBAN_BOARD=fixture HERMES_KANBAN_RUN_ID=r_fixture \
    NIXHOMESERVER_REQUIRE_REMOTE=1 NIXHOMESERVER_EXPECTED_HEAD="$fixture_head" \
    NIXHOMESERVER_EXPECTED_TREE="$fixture_tree" NIXHOMESERVER_EVIDENCE_DIR="$fixture_repo/.tmp/evidence" \
    remote_run 'printf local') >/dev/null 2>&1; then
  fail "strict extracted manifest mismatch was accepted"
fi
[[ ! -s "$spy_dir/calls" ]] || fail "manifest mismatch invoked a local heavy command"
: >"$spy_dir/calls"
if (cd "$fixture_repo" && PATH="$spy_dir:$PATH" RUN_SPY="$spy_dir/calls" \
    FIXTURE_REPO="$fixture_repo" FAKE_SSH_MODE=mutate-source \
    FAKE_REMOTE_ROOT="$fixture_remote" HERMES_KANBAN_TASK=t_fixture HERMES_KANBAN_BOARD=fixture \
    HERMES_KANBAN_RUN_ID=r_fixture NIXHOMESERVER_REQUIRE_REMOTE=1 \
    NIXHOMESERVER_EXPECTED_HEAD="$fixture_head" NIXHOMESERVER_EXPECTED_TREE="$fixture_tree" \
    NIXHOMESERVER_EVIDENCE_DIR="$fixture_repo/.tmp/evidence" remote_run 'printf local') \
    >/dev/null 2>&1; then
  fail "source mutation during remote execution was accepted"
fi
git -C "$fixture_repo" checkout -- tracked.txt
[[ ! -s "$spy_dir/calls" ]] || fail "source mutation invoked a local heavy command"
echo "✅ remote-run strict failure matrix refused local fallbacks and mismatches"
echo "✅ remote-run strict success/failure receipts and ordinary opt-out tests passed"
