#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"

cd "$TESTS_REPO_ROOT"

ensure_tools mktemp rg

echo "ℹ️ Checking fast remote rebuild orchestration…"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

fake_bin="${tmpdir}/bin"
mkdir -p "$fake_bin" "${tmpdir}/remote"
bash_path="$(command -v bash)"

ssh_log="${tmpdir}/ssh.log"
scp_log="${tmpdir}/scp.log"
ssh_stdin_log="${tmpdir}/ssh-stdin.log"
nix_log="${tmpdir}/nix.log"
fast_rebuild_script="${TESTS_REPO_ROOT}/scripts/rebuild-remote-fast.sh"

cat >"${fake_bin}/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

host=""
while (($# > 0)); do
  case "$1" in
    -t|-tt|-T)
      shift
      ;;
    -o)
      shift 2
      ;;
    *)
      host="$1"
      shift
      break
      ;;
  esac
done

command="$*"
printf 'ssh host=%s command=%s\n' "$host" "$command" >>"$FAST_REBUILD_TEST_SSH_LOG"

stdin_payload=""
if [[ ! -t 0 ]]; then
  stdin_payload="$(cat)"
fi

if [[ -n "$stdin_payload" ]]; then
  {
    printf -- '--- host=%s command=%s ---\n' "$host" "$command"
    printf '%s\n' "$stdin_payload"
  } >>"$FAST_REBUILD_TEST_SSH_STDIN_LOG"
fi

if [[ "$command" == mktemp\ /tmp/* ]]; then
  remote_root="${FAST_REBUILD_TEST_REMOTE_ROOT}/$(printf '%s' "$host" | tr '@/:' '_')"
  mkdir -p "$remote_root"
  template="$(basename "${command#mktemp }")"
  mktemp -p "$remote_root" "$template"
  exit 0
fi

if [[ "$command" == *bash\ -s* ]]; then
  exit 0
fi

exit 0
EOF
chmod +x "${fake_bin}/ssh"

cat >"${fake_bin}/scp" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'scp %s\n' "$*" >>"$FAST_REBUILD_TEST_SCP_LOG"
src="${@: -2:1}"
dest="${@: -1}"
cp "$src" "${dest#*:}"
EOF
chmod +x "${fake_bin}/scp"

cat >"${fake_bin}/nix" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'nix %s\n' "$*" >>"$FAST_REBUILD_TEST_NIX_LOG"

if [[ "${1:-}" == "eval" ]]; then
  case "$*" in
    *vars.hostname*)
      printf 'server\n'
      ;;
    *localAdminUser*)
      printf 'dsaw\n'
      ;;
    *)
      printf 'unknown\n'
      ;;
  esac
  exit 0
fi

echo "unexpected nix invocation: $*" >&2
exit 99
EOF
chmod +x "${fake_bin}/nix"

for fake_script in "${fake_bin}"/*; do
  sed -i "1s|.*|#!${bash_path}|" "$fake_script"
done

run_case() {
  local output_file="$1"
  shift
  local status

  : >"$ssh_log"
  : >"$scp_log"
  : >"$ssh_stdin_log"
  : >"$nix_log"

  set +e
  PATH="${fake_bin}:$PATH" \
    FAST_REBUILD_TEST_SSH_LOG="$ssh_log" \
    FAST_REBUILD_TEST_SCP_LOG="$scp_log" \
    FAST_REBUILD_TEST_SSH_STDIN_LOG="$ssh_stdin_log" \
    FAST_REBUILD_TEST_NIX_LOG="$nix_log" \
    FAST_REBUILD_TEST_REMOTE_ROOT="${tmpdir}/remote" \
    "$@" >"$output_file" 2>&1
  status=$?
  set -e
  if (( status != 0 )); then
    cat "$output_file" >&2
    return "$status"
  fi
}

run_failure_case() {
  local output_file="$1"
  shift
  local status

  : >"$ssh_log"
  : >"$scp_log"
  : >"$ssh_stdin_log"
  : >"$nix_log"

  set +e
  PATH="${fake_bin}:$PATH" \
    FAST_REBUILD_TEST_SSH_LOG="$ssh_log" \
    FAST_REBUILD_TEST_SCP_LOG="$scp_log" \
    FAST_REBUILD_TEST_SSH_STDIN_LOG="$ssh_stdin_log" \
    FAST_REBUILD_TEST_NIX_LOG="$nix_log" \
    FAST_REBUILD_TEST_REMOTE_ROOT="${tmpdir}/remote" \
    "$@" >"$output_file" 2>&1
  status=$?
  set -e
  if (( status == 0 )); then
    cat "$output_file" >&2
    return 1
  fi
}

implicit_target_output="${tmpdir}/implicit-target.out"
run_case \
  "$implicit_target_output" \
  bash "$fast_rebuild_script"

require_fixed "$nix_log" 'vars.hostname' \
  "Fast rebuild with no args must evaluate vars.hostname."
require_fixed "$nix_log" 'localAdminUser' \
  "Fast rebuild with no args must evaluate vars.localAdminUser."
require_fixed "$scp_log" 'dsaw@server:' \
  "Fast rebuild with no args must stage to localAdminUser@hostname from vars.nix."
require_fixed "$ssh_log" 'ssh host=dsaw@server' \
  "Fast rebuild with no args must SSH to localAdminUser@hostname from vars.nix."
require_fixed "$ssh_log" 'HOSTNAME_ARG=server' \
  "Fast rebuild with no args must use vars.hostname as the flake hostname."
require_fixed "$ssh_log" 'ACTION=switch' \
  "Fast rebuild with no args must default to nixos-rebuild switch."

default_output="${tmpdir}/default.out"
run_case \
  "$default_output" \
  bash "$fast_rebuild_script" \
  --target "dsaw@192.0.2.10" \
  --hostname server

require_fixed "$scp_log" 'rebuild-remote-fast-repo' \
  "Fast rebuild must stage the repo archive on the build host."
require_fixed "$ssh_log" 'ACTION=switch' \
  "Fast rebuild must default to nixos-rebuild switch."
require_fixed "$ssh_stdin_log" 'cmd=(nix run nixpkgs#nixos-rebuild -- "$ACTION" --flake ".#${HOSTNAME_ARG}" --sudo)' \
  "Fast rebuild must run nixos-rebuild from the staged remote archive."
require_fixed "$ssh_log" 'HOSTNAME_ARG=server' \
  "Fast rebuild must pass the flake hostname to the remote command."
forbid_match "$ssh_stdin_log" 'validate-repo|check-runtime-readiness|systemctl --failed|flake check|remote-ops\.sh deploy' \
  "Fast rebuild must not run guarded deploy or runtime validation commands."

test_output="${tmpdir}/test.out"
run_case \
  "$test_output" \
  bash "$fast_rebuild_script" \
  --target "dsaw@192.0.2.10" \
  --hostname server \
  --action test

require_fixed "$ssh_log" 'ACTION=test' \
  "Fast rebuild --action test must pass test as the rebuild action."
forbid_match "$ssh_log" 'ACTION=switch' \
  "Fast rebuild --action test must not pass switch as the rebuild action."

split_host_output="${tmpdir}/split-host.out"
run_case \
  "$split_host_output" \
  bash "$fast_rebuild_script" \
  --target "dsaw@target.example" \
  --build-host "dsaw@builder.example" \
  --hostname server

require_fixed "$scp_log" 'dsaw@builder.example:' \
  "Fast rebuild must stage the archive on the explicit build host."
require_fixed "$ssh_log" 'ssh host=dsaw@builder.example' \
  "Fast rebuild must execute the remote command on the build host."
require_fixed "$ssh_stdin_log" 'cmd+=(--target-host "$TARGET_HOST")' \
  "Fast rebuild must target the activation host when build host and target differ."

invalid_action_output="${tmpdir}/invalid-action.out"
run_failure_case \
  "$invalid_action_output" \
  bash "$fast_rebuild_script" \
  --target "dsaw@192.0.2.10" \
  --hostname server \
  --action boot

require_fixed "$invalid_action_output" "--action must be 'test' or 'switch'" \
  "Fast rebuild must reject invalid rebuild actions."

echo "✅ Fast remote rebuild tests passed."
