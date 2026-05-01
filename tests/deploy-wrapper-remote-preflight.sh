#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

cd "$TESTS_REPO_ROOT"

ensure_tools mktemp rg

echo "ℹ️ Checking remote deploy preflight orchestration…"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

fake_bin="${tmpdir}/bin"
mkdir -p "$fake_bin" "${tmpdir}/remote"

nix_log="${tmpdir}/nix.log"
ssh_log="${tmpdir}/ssh.log"
scp_log="${tmpdir}/scp.log"
ssh_stdin_log="${tmpdir}/ssh-stdin.log"

cat >"${fake_bin}/nix" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'nix %s\n' "$*" >>"$DEPLOY_WRAPPER_TEST_NIX_LOG"
if [[ "${1:-}" == "eval" ]]; then
  case "$*" in
    *vars.hostname*)
      printf 'server\n'
      ;;
    *vars.serverLanIP*)
      printf '192.0.2.10\n'
      ;;
    *)
      exit 1
      ;;
  esac
fi
EOF
chmod +x "${fake_bin}/nix"

cat >"${fake_bin}/scp" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'scp %s\n' "$*" >>"$DEPLOY_WRAPPER_TEST_SCP_LOG"
src="${@: -2:1}"
dest="${@: -1}"
cp "$src" "${dest#*:}"
EOF
chmod +x "${fake_bin}/scp"

cat >"${fake_bin}/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

host=""
while (($# > 0)); do
  case "$1" in
    -t|-tt)
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
printf 'ssh host=%s command=%s\n' "$host" "$command" >>"$DEPLOY_WRAPPER_TEST_SSH_LOG"

stdin_payload=""
if [[ ! -t 0 ]]; then
  stdin_payload="$(cat)"
fi

if [[ -n "$stdin_payload" ]]; then
  {
    printf -- '--- host=%s command=%s ---\n' "$host" "$command"
    printf '%s\n' "$stdin_payload"
  } >>"$DEPLOY_WRAPPER_TEST_SSH_STDIN_LOG"
fi

if [[ "$command" == mktemp\ /tmp/* ]]; then
  remote_root="${DEPLOY_WRAPPER_TEST_REMOTE_ROOT}/$(printf '%s' "$host" | tr '@/:' '_')"
  mkdir -p "$remote_root"
  template="$(basename "${command#mktemp }")"
  mktemp -p "$remote_root" "$template"
  exit 0
fi

if [[ "$command" == *MIN_BUILD_FREE_BYTES=*bash\ -s* ]]; then
  if [[ "${DEPLOY_WRAPPER_TEST_LOW_SPACE:-0}" == "1" ]]; then
    cat <<'MSG'
❌ Insufficient free space on build host
   sandbox-build-dir: /build
   backing path: /
   available: 536870912 bytes (0.50 GiB)
   required: 10737418240 bytes (10.00 GiB)
MSG
    exit 1
  fi

  cat <<'MSG'
ℹ️ Build host storage summary: sandbox-build-dir=/build, backing-path=/, available=20.00 GiB, /tmp=2.00 GiB
MSG
  exit 0
fi

if [[ "$command" == *bash\ -s* ]]; then
  if [[ "$stdin_payload" == *'nix shell nixpkgs#ripgrep nixpkgs#python3 -c ./scripts/check-repo.sh --full --skip-flake-check'* ]]; then
    if [[ "${DEPLOY_WRAPPER_TEST_FAIL_REMOTE_CHECK:-0}" == "1" ]]; then
      exit 1
    fi
    exit 0
  fi

  if [[ "$stdin_payload" == *'runtime-readiness.sh --profile deploy'* ]]; then
    exit 0
  fi
fi

if [[ "$command" == "sudo systemctl --failed --no-pager" ]]; then
  exit 0
fi

exit 0
EOF
chmod +x "${fake_bin}/ssh"

run_case() {
  local label="$1"
  local output_file="$2"
  shift 2

  : >"$nix_log"
  : >"$ssh_log"
  : >"$scp_log"
  : >"$ssh_stdin_log"

  PATH="${fake_bin}:$PATH" \
    DEPLOY_WRAPPER_TEST_NIX_LOG="$nix_log" \
    DEPLOY_WRAPPER_TEST_SSH_LOG="$ssh_log" \
    DEPLOY_WRAPPER_TEST_SCP_LOG="$scp_log" \
    DEPLOY_WRAPPER_TEST_SSH_STDIN_LOG="$ssh_stdin_log" \
    DEPLOY_WRAPPER_TEST_REMOTE_ROOT="${tmpdir}/remote" \
    "$@" >"$output_file" 2>&1
}

success_output="${tmpdir}/success.out"
run_case \
  "success" \
  "$success_output" \
  scripts/deploy-validated.sh \
  --target "dsaw@192.0.2.10" \
  --build-host "dsaw@192.0.2.10" \
  --action test \
  --hostname server

require_fixed "$scp_log" 'deploy-validated-repo' \
  "Deploy wrapper must stage the repo archive on the build host."
require_fixed "$ssh_stdin_log" 'nix shell nixpkgs#ripgrep nixpkgs#python3 -c ./scripts/check-repo.sh --full --skip-flake-check' \
  "Deploy wrapper must bootstrap ripgrep and python3 while running the full repository gate on the remote build host."
require_fixed "$ssh_stdin_log" 'trap '\''rm -rf "$tmpdir" "$REMOTE_ARCHIVE"'\'' EXIT' \
  "Remote preflight staging must clean up the temp directory and uploaded archive."
require_fixed "$nix_log" 'nix run nixpkgs#nixos-rebuild -- test' \
  "Deploy wrapper must continue into remote nixos-rebuild test after remote preflight passes."
require_fixed "$ssh_stdin_log" 'runtime-readiness.sh --profile deploy' \
  "Deploy wrapper must stage runtime readiness from the shared repo archive."

low_space_output="${tmpdir}/low-space.out"
if run_case \
  "low-space" \
  "$low_space_output" \
  env DEPLOY_WRAPPER_TEST_LOW_SPACE=1 \
  scripts/deploy-validated.sh \
  --target "dsaw@192.0.2.10" \
  --build-host "dsaw@192.0.2.10" \
  --action test \
  --hostname server
then
  echo "❌ Low-space case must fail before remote preflight starts."
  exit 1
fi

require_fixed "$low_space_output" 'Insufficient free space on build host' \
  "Low-space failures must clearly identify the build host storage issue."
require_fixed "$low_space_output" 'sandbox-build-dir: /build' \
  "Low-space failures must report the sandbox build directory."
forbid_match "$scp_log" 'deploy-validated-repo' \
  "Low-space failures must not upload the repo archive."
forbid_match "$nix_log" 'nix run nixpkgs#nixos-rebuild -- test' \
  "Low-space failures must stop before remote nixos-rebuild starts."

remote_failure_output="${tmpdir}/remote-failure.out"
if run_case \
  "remote-check-failure" \
  "$remote_failure_output" \
  env DEPLOY_WRAPPER_TEST_FAIL_REMOTE_CHECK=1 \
  scripts/deploy-validated.sh \
  --target "dsaw@192.0.2.10" \
  --build-host "dsaw@192.0.2.10" \
  --action test \
  --hostname server
then
  echo "❌ Remote repository-check failures must stop the deploy wrapper."
  exit 1
fi

require_fixed "$ssh_stdin_log" 'nix shell nixpkgs#ripgrep nixpkgs#python3 -c ./scripts/check-repo.sh --full --skip-flake-check' \
  "Remote repository-check failures must still occur inside the staged build-host workspace with ripgrep and python3 bootstrapped."
require_fixed "$ssh_stdin_log" 'trap '\''rm -rf "$tmpdir" "$REMOTE_ARCHIVE"'\'' EXIT' \
  "Remote repository-check failures must retain staged-archive cleanup."
forbid_match "$nix_log" 'nix run nixpkgs#nixos-rebuild -- test' \
  "Remote repository-check failures must stop before remote nixos-rebuild starts."

echo "✅ Remote deploy preflight tests passed."
