#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"

cd "$TESTS_REPO_ROOT"

ensure_tools mktemp rg jq

echo "ℹ️ Checking remote deploy preflight orchestration…"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

fake_bin="${tmpdir}/bin"
fake_tests_dir="${tmpdir}/fake-tests"
mkdir -p "$fake_bin" "${tmpdir}/remote" "$fake_tests_dir"
bash_path="$(command -v bash)"

cat >"${fake_tests_dir}/run-script-tests.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 0
EOF
chmod +x "${fake_tests_dir}/run-script-tests.sh"

nix_log="${tmpdir}/nix.log"
ssh_log="${tmpdir}/ssh.log"
scp_log="${tmpdir}/scp.log"
ssh_stdin_log="${tmpdir}/ssh-stdin.log"
deploy_script="${TESTS_REPO_ROOT}/scripts/deploy-with-validation.sh"
validate_remote_script="${TESTS_REPO_ROOT}/scripts/validate-repo-remote.sh"

cat >"${fake_bin}/nix" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'nix %s\n' "$*" >>"$DEPLOY_WRAPPER_TEST_NIX_LOG"

if [[ "${DEPLOY_WRAPPER_TEST_NIX_MODE:-allow}" == "deny" ]]; then
  echo "unexpected local nix invocation: $*" >&2
  exit 99
fi

if [[ "${1:-}" == "eval" ]]; then
  case "$*" in
    *builtins.currentSystem*)
      printf '%s\n' "${DEPLOY_WRAPPER_TEST_LOCAL_SYSTEM:-x86_64-linux}"
      ;;
    *vars.hostname*)
      printf 'server\n'
      ;;
    *vars.serverLanIP*)
      printf '192.0.2.10\n'
      ;;
    *pkgs.stdenv.hostPlatform.system*)
      printf '%s\n' "${DEPLOY_WRAPPER_TEST_TARGET_SYSTEM:-x86_64-linux}"
      ;;
    *)
      printf 'x86_64-linux\n'
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

cat >"${fake_bin}/sudo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'sudo %s\n' "$*" >>"$DEPLOY_WRAPPER_TEST_SSH_LOG"
if [[ "${1:-}" == "env" ]]; then
  shift
  while (($# > 0)) && [[ "$1" == *=* ]]; do
    export "$1"
    shift
  done
fi
if (($# == 0)); then
  exit 0
fi
exec "$@"
EOF
chmod +x "${fake_bin}/sudo"

cat >"${fake_bin}/systemctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 0
EOF
chmod +x "${fake_bin}/systemctl"

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

if [[ "$command" == *bash\ -s* ]]; then
  env_prefix="${command%%bash -s*}"
  if [[ -n "$env_prefix" ]]; then
    eval "export ${env_prefix}"
  fi

  cache_dir="${DEPLOY_VALIDATION_CACHE_DIR:-}"
  stamp_file=""
  if [[ -n "${cache_dir:-}" && -n "${ARCHIVE_SHA:-}" ]]; then
    stamp_file="${cache_dir}/${ARCHIVE_SHA}.json"
  fi

  if [[ "$stdin_payload" == *'./scripts/remote-ops.sh deploy'* ]]; then
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

    echo "ℹ️ Checking build host free space on ${BUILD_HOST}…"
    echo "ℹ️ Build host storage summary: sandbox-build-dir=/build, backing-path=/, available=20.00 GiB, /tmp=2.00 GiB"

    if [[ -n "$stamp_file" && -f "$stamp_file" ]]; then
      echo "ℹ️ Reusing remote validation stamp for archive ${ARCHIVE_SHA}; skipping remote repository checks."
    else
      echo "ℹ️ Running repository checks on ${BUILD_HOST}…"
      if [[ "${DEPLOY_WRAPPER_TEST_FAIL_REMOTE_CHECK:-0}" == "1" ]]; then
        exit 1
      fi
      if [[ -n "$stamp_file" ]]; then
        mkdir -p "$cache_dir"
        cat >"$stamp_file" <<STAMP
{
  "archiveSha256": "${ARCHIVE_SHA}",
  "createdEpoch": $(date +%s),
  "flakeCheckSucceeded": false,
  "checkRepoSucceeded": true
}
STAMP
      fi
    fi

    echo "ℹ️ Running remote nixos-rebuild test…"
    if [[ "${ACTION:-test}" == "switch" ]]; then
      echo "ℹ️ Running remote nixos-rebuild switch…"
    fi
    exit 0
  fi

  if [[ "$stdin_payload" == *'./scripts/remote-ops.sh validate'* ]]; then
    if [[ -n "$stamp_file" ]]; then
      mkdir -p "$cache_dir"
      cat >"$stamp_file" <<STAMP
{
  "archiveSha256": "${ARCHIVE_SHA}",
  "createdEpoch": $(date +%s),
  "flakeCheckSucceeded": true,
  "checkRepoSucceeded": true
}
STAMP
    fi
    echo "✅ Repository checks passed."
    exit 0
  fi

  if [[ "$stdin_payload" == *'check-runtime-readiness.sh --profile deploy'* ]]; then
    exit 0
  fi
fi

if [[ "$command" == "sudo systemctl --failed --no-pager" ]]; then
  exit 0
fi

exit 0
EOF
chmod +x "${fake_bin}/ssh"

for fake_script in "${fake_bin}"/* "${fake_tests_dir}/run-script-tests.sh"; do
  sed -i "1s|.*|#!${bash_path}|" "$fake_script"
done

run_case() {
  local output_file="$1"
  shift
  local status

  : >"$nix_log"
  : >"$ssh_log"
  : >"$scp_log"
  : >"$ssh_stdin_log"

  set +e
  PATH="${fake_bin}:$PATH" \
    VALIDATE_REPO_TESTS_DIR="$fake_tests_dir" \
    DEPLOY_WRAPPER_TEST_NIX_LOG="$nix_log" \
    DEPLOY_WRAPPER_TEST_SSH_LOG="$ssh_log" \
    DEPLOY_WRAPPER_TEST_SCP_LOG="$scp_log" \
    DEPLOY_WRAPPER_TEST_SSH_STDIN_LOG="$ssh_stdin_log" \
    DEPLOY_WRAPPER_TEST_REMOTE_ROOT="${tmpdir}/remote" \
    "$@" >"$output_file" 2>&1
  status=$?
  set -e
  if (( status != 0 )); then
    cat "$output_file" >&2
    return "$status"
  fi
}

success_output="${tmpdir}/success.out"
run_case \
  "$success_output" \
  env DEPLOY_WRAPPER_TEST_NIX_MODE=deny \
  bash "$deploy_script" \
  --target "dsaw@192.0.2.10" \
  --build-host "dsaw@192.0.2.10" \
  --action test \
  --hostname server

require_fixed "$scp_log" 'deploy-with-validation-repo' \
  "Deploy wrapper must stage the repo archive on the build host."
require_fixed "$ssh_stdin_log" './scripts/remote-ops.sh deploy' \
  "Deploy wrapper must invoke the remote deploy dispatcher from the staged archive."
require_fixed "$ssh_log" 'FULL_CHECK=false' \
  "Default deploy wrapper runs must keep the deep runtime flag disabled."
require_fixed "$success_output" 'Running repository checks on dsaw@192.0.2.10' \
  "Remote deploys must run repository checks on the build host."
require_fixed "$success_output" 'Running remote nixos-rebuild test' \
  "Remote deploys must continue into remote nixos-rebuild test after remote preflight passes."
forbid_match "$nix_log" '^nix ' \
  "Thin remote deploys must not invoke local nix."

remote_validation_output="${tmpdir}/remote-validate.out"
run_case \
  "$remote_validation_output" \
  env DEPLOY_WRAPPER_TEST_NIX_MODE=deny DEPLOY_VALIDATION_CACHE_DIR="${tmpdir}/remote-cache" \
  bash "$validate_remote_script" \
  --host "dsaw@192.0.2.10" \
  --full

require_fixed "$scp_log" 'validate-repo-remote' \
  "Remote validation wrapper must stage the repo archive on the chosen host."
require_fixed "$ssh_stdin_log" './scripts/remote-ops.sh validate' \
  "Remote validation wrapper must invoke the remote validation dispatcher."
require_fixed "$remote_validation_output" 'Repository checks passed' \
  "Remote validation wrapper must stream the remote validation result."
forbid_match "$nix_log" '^nix ' \
  "Remote validation wrapper must not invoke local nix."

stamped_output="${tmpdir}/stamped.out"
run_case \
  "$stamped_output" \
  env DEPLOY_WRAPPER_TEST_NIX_MODE=deny DEPLOY_VALIDATION_CACHE_DIR="${tmpdir}/remote-cache" \
  bash "$deploy_script" \
  --target "dsaw@192.0.2.10" \
  --build-host "dsaw@192.0.2.10" \
  --action test \
  --hostname server

require_fixed "$stamped_output" 'skipping remote repository checks' \
  "Fresh remote validation stamps must skip repeated remote repository checks."
forbid_match "$nix_log" '^nix ' \
  "Stamp reuse must still avoid local nix invocations."

low_space_output="${tmpdir}/low-space.out"
if run_case \
  "$low_space_output" \
  env DEPLOY_WRAPPER_TEST_NIX_MODE=deny DEPLOY_WRAPPER_TEST_LOW_SPACE=1 \
  bash "$deploy_script" \
  --target "dsaw@192.0.2.10" \
  --build-host "dsaw@192.0.2.10" \
  --action test \
  --hostname server
then
  echo "❌ Low-space case must fail before remote nixos-rebuild starts."
  exit 1
fi

require_fixed "$low_space_output" 'Insufficient free space on build host' \
  "Low-space failures must clearly identify the build host storage issue."
require_fixed "$scp_log" 'deploy-with-validation-repo' \
  "Thin deploys must still upload the repo archive before remote-side storage checks."
forbid_match "$nix_log" '^nix ' \
  "Low-space failures in remote mode must not invoke local nix."

remote_failure_output="${tmpdir}/remote-failure.out"
if run_case \
  "$remote_failure_output" \
  env DEPLOY_WRAPPER_TEST_NIX_MODE=deny DEPLOY_WRAPPER_TEST_FAIL_REMOTE_CHECK=1 \
  bash "$deploy_script" \
  --target "dsaw@192.0.2.10" \
  --build-host "dsaw@192.0.2.10" \
  --action test \
  --hostname server
then
  echo "❌ Remote repository-check failures must stop the deploy wrapper."
  exit 1
fi

require_fixed "$ssh_stdin_log" './scripts/remote-ops.sh deploy' \
  "Remote repository-check failures must still occur through the staged remote dispatcher."
forbid_match "$remote_failure_output" 'Running remote nixos-rebuild test' \
  "Remote repository-check failures must stop before remote nixos-rebuild starts."
forbid_match "$nix_log" '^nix ' \
  "Remote repository-check failures must not invoke local nix."

local_build_output="${tmpdir}/local-build.out"
run_case \
  "$local_build_output" \
  env DEPLOY_WRAPPER_TEST_NIX_MODE=allow \
  bash "$deploy_script" \
  --target "dsaw@192.0.2.10" \
  --local-build \
  --action test \
  --hostname server

forbid_match "$ssh_stdin_log" './scripts/remote-ops.sh deploy' \
  "Local builds must not invoke the remote deploy dispatcher."
require_fixed "$nix_log" 'nix run nixpkgs#nixos-rebuild -- test' \
  "Local builds must still run nixos-rebuild test locally."

remote_full_check_output="${tmpdir}/remote-full-check.out"
run_case \
  "$remote_full_check_output" \
  env DEPLOY_WRAPPER_TEST_NIX_MODE=deny \
  bash "$deploy_script" \
  --target "dsaw@192.0.2.10" \
  --build-host "dsaw@192.0.2.10" \
  --action test \
  --hostname server \
  --full-check

require_fixed "$ssh_stdin_log" '--full-check' \
  "Deploy wrapper --full-check runs must preserve the flag into the remote deploy dispatcher."
require_fixed "$ssh_log" 'FULL_CHECK=true' \
  "Deploy wrapper --full-check runs must enable the deep runtime flag in the remote environment."

local_full_check_output="${tmpdir}/local-full-check.out"
run_case \
  "$local_full_check_output" \
  env DEPLOY_WRAPPER_TEST_NIX_MODE=allow \
  bash "$deploy_script" \
  --target "dsaw@192.0.2.10" \
  --local-build \
  --action test \
  --hostname server \
  --full-check

require_fixed "$ssh_log" 'FULL_CHECK=true' \
  "Local-build --full-check runs must pass the deep runtime flag into the staged readiness invocation."
require_fixed "$ssh_stdin_log" 'readiness_args+=(--deep)' \
  "Local-build --full-check runs must prepare the deep runtime readiness arguments."

local_build_mismatch_output="${tmpdir}/local-build-mismatch.out"
if run_case \
  "$local_build_mismatch_output" \
  env DEPLOY_WRAPPER_TEST_NIX_MODE=allow DEPLOY_WRAPPER_TEST_LOCAL_SYSTEM=aarch64-linux DEPLOY_WRAPPER_TEST_TARGET_SYSTEM=x86_64-linux \
  bash "$deploy_script" \
  --target "dsaw@192.0.2.10" \
  --local-build \
  --action test \
  --hostname server
then
  echo "❌ Local-build system mismatches must fail before nixos-rebuild starts."
  exit 1
fi

require_fixed "$local_build_mismatch_output" 'requires the current workstation system to match the target host configuration' \
  "Local-build mismatches must explain the system mismatch clearly."
forbid_match "$nix_log" 'nix run nixpkgs#nixos-rebuild -- test' \
  "Local-build system mismatches must stop before nixos-rebuild starts."

echo "✅ Remote deploy preflight tests passed."
