#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"

cd "$TESTS_REPO_ROOT"

ensure_tools bash git mktemp nix rg tar

expected_hostname="$(nix_flake_var 'vars.hostname')"
expected_lan_ip="$(nix_flake_var 'vars.serverLanIP')"
expected_local_admin="$(nix_flake_var 'vars.localAdminUser')"
expected_build_mode="$(nix_flake_var 'vars.buildMode')"
expected_local_slots="$(nix_flake_var 'toString vars.buildSlots.local')"
expected_remote_slots="$(nix_flake_var 'toString vars.buildSlots.remote')"
expected_local_cores="$(nix_flake_var 'toString vars.buildCores.local')"
expected_remote_cores="$(nix_flake_var 'toString vars.buildCores.remote')"
expected_local_gc_mode="$(nix_flake_var 'vars.localNixGCMode')"
expected_target="${expected_local_admin}@${expected_lan_ip}"

archive_test_dir="$(mktemp -d '/tmp/nixhomeserver deploy.XXXXXX')"
cleanup() { rm -rf "$archive_test_dir"; }
trap cleanup EXIT
archive_path="$archive_test_dir/repository.tar"
archive_root="$archive_test_dir/extracted repository"
if git -C "$TESTS_REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  mkdir -p "$archive_root"
  create_deploy_repo_archive "$archive_path"
  tar -xf "$archive_path" -C "$archive_root"
else
  # Debug deployment validation runs from the already manifest-filtered
  # archive on the build host. Reuse that extracted tree to exercise path
  # flake evaluation without incorrectly requiring a nested Git checkout.
  archive_root="$TESTS_REPO_ROOT"
fi
(
  cd "$archive_root"
  unset NIXHOMESERVER_REPO_ROOT_FOR_EVAL NIXHOMESERVER_FLAKE_REF_FOR_EVAL
  source scripts/helpers/repo-common.sh
  init_repo_root
  if [[ "$NIXHOMESERVER_FLAKE_REF_FOR_EVAL" != path:* ]]; then
    echo "❌ A manifest-filtered deployment archive must use a path flake without requiring .git." >&2
    exit 1
  fi
  if [[ "$(nix_flake_var 'vars.hostname')" != "$expected_hostname" ]]; then
    echo "❌ Evaluating host settings from an extracted deployment archive failed." >&2
    exit 1
  fi
)

untracked_repo="$archive_test_dir/untracked-policy-repo"
mkdir -p "$untracked_repo"
git -C "$untracked_repo" init -q
printf 'tracked\n' >"$untracked_repo/tracked.txt"
git -C "$untracked_repo" add tracked.txt
printf 'must be reviewed\n' >"$untracked_repo/untracked.txt"
(
  repo_root="$untracked_repo"
  if create_deploy_repo_archive "$archive_test_dir/untracked.tar" 2>"$archive_test_dir/untracked.log"; then
    echo "❌ Deploy archive accepted an untracked, non-ignored file."
    exit 1
  fi
)
if ! rg -Fq 'Refusing to deploy with untracked, non-ignored files' "$archive_test_dir/untracked.log" \
  || ! rg -Fq 'untracked.txt' "$archive_test_dir/untracked.log"; then
  echo "❌ Deploy archive did not clearly diagnose the untracked file."
  cat "$archive_test_dir/untracked.log"
  exit 1
fi

git -C "$untracked_repo" add untracked.txt
(
  repo_root="$untracked_repo"
  create_deploy_repo_archive "$archive_test_dir/staged.tar"
)
if ! tar -tf "$archive_test_dir/staged.tar" | rg -Fxq 'untracked.txt'; then
  echo "❌ Deploy archive omitted a reviewed and staged file."
  exit 1
fi

copied_repo="$archive_test_dir/copied-without-git"
mkdir -p "$copied_repo/secrets" "$copied_repo/custom_apps/node/apps/demo/node_modules/pkg"
printf 'must-not-enter-the-store\n' >"$copied_repo/secrets/local-token"
printf 'cache\n' >"$copied_repo/custom_apps/node/apps/demo/node_modules/pkg/cache.js"
(
  repo_root="$copied_repo"
  if create_deploy_repo_archive "$archive_test_dir/copied.tar" 2>"$archive_test_dir/copied.log"; then
    echo "❌ Deploy archive accepted a copied/non-Git source tree."
    exit 1
  fi
)
if ! rg -Fq 'Refusing to create a deployment archive outside a Git worktree' "$archive_test_dir/copied.log"; then
  echo "❌ Non-Git deploy source was not rejected with a safe recovery path."
  cat "$archive_test_dir/copied.log"
  exit 1
fi

default_output="$(DEPLOY_DRY_RUN=1 bash scripts/deploy.sh --action test)"
if ! rg -Fq "mode=${expected_build_mode}" <<<"$default_output" \
  || ! rg -Fq "build_slots=local:${expected_local_slots},remote:${expected_remote_slots}" <<<"$default_output" \
  || ! rg -Fq "build_cores=local:${expected_local_cores},remote:${expected_remote_cores}" <<<"$default_output"; then
  echo "❌ Deploy default did not use the allocation selected in vars.nix."
  echo "$default_output"
  exit 1
fi
if ! rg -Fq "target_host=${expected_target}" <<<"$default_output"; then
  echo "❌ Deploy default target should use the local admin and LAN IP for first-boot reachability."
  echo "$default_output"
  exit 1
fi
case "$expected_local_gc_mode" in
  capacity)
    if ! rg -Fq 'local_gc=would run conservative workstation disk cleanup' <<<"$default_output"; then
      echo "❌ Capacity GC mode must report the planned conservative workstation disk cleanup."
      echo "$default_output"
      exit 1
    fi
    ;;
  always)
    if ! rg -Fq 'local_gc=would run unconditional nix-store --gc on the workstation before staging' <<<"$default_output"; then
      echo "❌ Always GC mode must report the planned unconditional workstation collection."
      echo "$default_output"
      exit 1
    fi
    ;;
  never)
    if rg -Fq 'local_gc=' <<<"$default_output"; then
      echo "❌ Never GC mode must not report a workstation store GC action."
      echo "$default_output"
      exit 1
    fi
    ;;
esac
case "$expected_build_mode" in
  remote)
    if ! rg -Fq "build_host=${expected_target}" <<<"$default_output" \
      || rg -Fq -- "--target-host" <<<"$default_output"; then
      echo "❌ Remote mode should run on the target without a redundant --target-host."
      echo "$default_output"
      exit 1
    fi
    ;;
  local)
    if ! rg -Fq 'build_host=local' <<<"$default_output" \
      || ! rg -Fq -- "--target-host ${expected_target}" <<<"$default_output"; then
      echo "❌ Local mode should build on the workstation and copy to the target."
      echo "$default_output"
      exit 1
    fi
    ;;
  balanced|maximum-effort)
    if ! rg -Fq "build_host=local+${expected_target}" <<<"$default_output" \
      || ! rg -Fq -- "--target-host ${expected_target}" <<<"$default_output"; then
      echo "❌ Combined build mode should coordinate the workstation and target server."
      echo "$default_output"
      exit 1
    fi
    ;;
esac
if ! rg -Fq "rebuild_command=nix run --inputs-from . nixpkgs#nixos-rebuild" <<<"$default_output"; then
  echo "❌ Deploy should resolve nixos-rebuild from the repo flake inputs."
  echo "$default_output"
  exit 1
fi
if ! rg -Fq -- "-- build --flake" <<<"$default_output" \
  || ! rg -Fq 'activation_command=activate the returned closure through the guarded target-side test unit' <<<"$default_output"; then
  echo "❌ Test deploy must split non-mutating build/copy from guarded target activation."
  echo "$default_output"
  exit 1
fi

local_output="$(DEPLOY_DRY_RUN=1 bash scripts/deploy.sh --build-locally --action switch)"
if ! rg -Fq "mode=local" <<<"$local_output"; then
  echo "❌ --build-locally should select local build mode."
  echo "$local_output"
  exit 1
fi
if ! rg -Fq "build_host=local" <<<"$local_output"; then
  echo "❌ --build-locally should report a local build host."
  echo "$local_output"
  exit 1
fi
if ! rg -Fq 'stamp_required=true' <<<"$local_output"; then
  echo "❌ Switch must require a previous passing source/closure stamp."
  echo "$local_output"
  exit 1
fi
if ! rg -Fq 'activation_command=activate exact stamped closure in test mode' <<<"$local_output" \
  || ! rg -Fq 'boot_commit=only after failed-unit route and authenticated-canary gates pass' <<<"$local_output" \
  || ! rg -Fq 'rollback=restore previous live and boot generations on failure' <<<"$local_output"; then
  echo "❌ Switch dry-run must describe exact-closure activation, gated boot commit, and rollback."
  echo "$local_output"
  exit 1
fi
if rg -Fq 'nixos-rebuild -- boot' <<<"$local_output"; then
  echo "❌ Switch must not set the boot profile before post-activation health gates."
  echo "$local_output"
  exit 1
fi

balanced_output="$(DEPLOY_DRY_RUN=1 bash scripts/deploy.sh --build-mode balanced --action test)"
if ! rg -Fq 'mode=balanced' <<<"$balanced_output" \
  || ! rg -Fq 'build_slots=local:2,remote:2' <<<"$balanced_output" \
  || ! rg -Fq 'build_cores=local:1,remote:1' <<<"$balanced_output" \
  || ! rg -Fq "build_host=local+${expected_target}" <<<"$balanced_output" \
  || ! rg -Fq -- "--target-host ${expected_target}" <<<"$balanced_output"; then
  echo "❌ Balanced mode should allocate two slots to the workstation and server."
  echo "$balanced_output"
  exit 1
fi

maximum_output="$(DEPLOY_DRY_RUN=1 bash scripts/deploy.sh --build-mode maximum-effort --action test)"
if ! rg -Fq 'mode=maximum-effort' <<<"$maximum_output" \
  || ! rg -Fq 'build_slots=local:auto,remote:auto' <<<"$maximum_output" \
  || ! rg -Fq 'build_cores=local:0,remote:0' <<<"$maximum_output" \
  || ! rg -Fq "build_host=local+${expected_target}" <<<"$maximum_output"; then
  echo "❌ Maximum-effort mode should allocate all available slots to the workstation and server."
  echo "$maximum_output"
  exit 1
fi

if conflict_output="$(DEPLOY_DRY_RUN=1 bash scripts/deploy.sh --build-locally --build-host "$expected_target" 2>&1)"; then
  echo "❌ Conflicting deploy build modes returned success."
  exit 1
fi
if ! rg -Fq "blocked: --build-locally cannot be combined with --build-host" <<<"$conflict_output"; then
  echo "❌ Deploy should reject --build-locally with --build-host."
  echo "$conflict_output"
  exit 1
fi

if missing_value_output="$(DEPLOY_DRY_RUN=1 bash scripts/deploy.sh --hostname 2>&1)"; then
  echo "❌ Deploy accepted --hostname without a value."
  exit 1
fi
if ! rg -Fq 'blocked: --hostname requires a flake hostname' <<<"$missing_value_output"; then
  echo "❌ Missing deploy option value was not diagnosed."
  echo "$missing_value_output"
  exit 1
fi

help_output="$(bash scripts/deploy.sh --help)"
if ! rg -Fq -- "--build-locally" <<<"$help_output" \
  || ! rg -Fq 'maximum-effort' <<<"$help_output"; then
  echo "❌ Deploy help should document configured and one-shot build modes."
  echo "$help_output"
  exit 1
fi

require_fixed scripts/helpers/deploy-executor.sh 'homepage_canary_enabled' \
  "Guarded deploy must detect whether the optional Homepage canary exists."
require_fixed scripts/helpers/deploy-executor.sh 'skipping authenticated service-access canary: homepage module is absent' \
  "Guarded deploy must succeed when Homepage is removed."
require_fixed scripts/deploy.sh 'source "$script_dir/helpers/deploy-command.sh"' \
  "Deploy dry-runs and real execution must share command construction."
require_fixed scripts/deploy.sh 'recover_local_attic_tunnel_if_needed' \
  "Real deploys must recover the optional workstation Attic tunnel before staging and building."
require_fixed scripts/deploy.sh 'nix-store --gc' \
  "Always-mode workstation GC must run a real Nix garbage collection before staging the deploy."
require_fixed scripts/deploy.sh 'disk-space-cleanup.sh' \
  "Capacity-mode workstation cleanup must use the conservative disk-space cleanup helper."
require_fixed scripts/deploy.sh 'local_gc=would run conservative workstation disk cleanup' \
  "Deploy dry-runs must report the planned conservative cleanup without running it."
require_fixed scripts/helpers/deploy-executor.sh 'nixpkgs#nodejs' \
  "Remote debug validation must provide its Node runtime from pinned nixpkgs."
require_fixed scripts/helpers/deploy-executor.sh 'date +%s%N' \
  "Detached activation unit names must not collide when deploys start within the same second."
require_fixed scripts/helpers/deploy-executor.sh 'load_test_stamp' \
  "Switch must load the exact closure recorded by the last passing test."
require_fixed scripts/helpers/deploy-executor.sh 'repository contents differ from the last passing test' \
  "Switch must refuse source changes after a passing test."
require_fixed scripts/helpers/deploy-executor.sh 'run_health_gates' \
  "Live activation must pass the shared health gates before boot commit."
require_fixed scripts/helpers/deploy-executor.sh 'commit_boot_generation' \
  "The boot profile must be committed in an explicit final transaction step."
require_fixed scripts/helpers/deploy-executor.sh 'rollback_live_generation' \
  "A failed live activation must roll back automatically."
require_fixed scripts/helpers/deploy-executor.sh 'schedule_rollback' \
  "An interrupted SSH deploy must leave a target-side rollback armed."
require_fixed scripts/helpers/deploy-executor.sh 'check_target_free_space' \
  "Deploy must check target store space independently of build-host space."
require_fixed scripts/helpers/deploy-executor.sh 'switch reuses the exact tested closure' \
  "Switch must not reapply a build-space gate when it performs no build or closure copy."
require_fixed scripts/helpers/deploy-executor.sh 'acquire_deploy_lock' \
  "Concurrent deploys must be serialized on the target host."
require_fixed scripts/helpers/deploy-executor.sh 'previous_boot/bin/switch-to-configuration' \
  "Interrupted deploy recovery must restore the previous boot generation as well as live state."
require_fixed scripts/helpers/deploy-executor.sh 'recovery-complete' \
  "A completed delayed rollback must retain a barrier against a stale executor."
require_fixed scripts/helpers/deploy-executor.sh 'could not prove activation' \
  "Rollback must not race an activation whose quiescence is unknown."
require_fixed scripts/helpers/deploy-executor.sh 'run_detached_activation "$built_toplevel" test tested-build' \
  "Test deploy must activate the built closure through the marker-guarded target unit."
require_fixed scripts/helpers/deploy-executor.sh 'deploy_lock_dir="${deploy_state_dir}/transactions/${HOSTNAME_ARG}"' \
  "Deployment ownership must survive NixOS activation recreating /run/lock."
require_fixed scripts/helpers/deploy-executor.sh 'runtime_unit_dir="/run/systemd/system"' \
  "Guarded activation and rollback units must survive the systemd re-exec performed by NixOS activation."
require_fixed scripts/helpers/deploy-executor.sh 'X-StopOnRemoval=false' \
  "NixOS activation must not stop the external transaction unit that is performing the activation."
forbid_match scripts/helpers/deploy-executor.sh 'exec systemd-run --unit=.*Detached NixOS' \
  "Forward and rollback activations must not use transient units that disappear during systemd re-exec."
require_fixed scripts/deploy.sh 'need git ssh tar' \
  "Deploy source creation must require Git rather than broad-archiving a copied tree."
require_fixed modules/Core_Modules/base-system/default.nix 'if vars.buildSlots.remote == 0 then "auto"' \
  "The deployed server must remain able to accept a build when changing away from local-only mode."
forbid_match scripts/helpers/deploy-executor.sh 'nixos-rebuild boot' \
  "Deploy must not commit a boot generation before the health gates."

# The Attic preflight is optional and allocation-aware, so it must now sit
# after the allocation is resolved - it may only run when the resolved
# allocation builds on the workstation - and still before any staging or
# build work so a recovered cache still serves the build.
attic_preflight_line="$(rg -n '^recover_local_attic_tunnel_if_needed' scripts/deploy.sh | cut -d: -f1)"
allocation_line="$(rg -n '^local_build_slots="\$\(jq' scripts/deploy.sh | cut -d: -f1)"
staging_line="$(rg -n '^repo_archive="\$\(mktemp' scripts/deploy.sh | cut -d: -f1)"
if [[ ! "$attic_preflight_line" =~ ^[0-9]+$ || ! "$allocation_line" =~ ^[0-9]+$ || ! "$staging_line" =~ ^[0-9]+$ ]] \
  || ((allocation_line >= attic_preflight_line || attic_preflight_line >= staging_line)); then
  echo "❌ Deploy must resolve the allocation, then recover the optional local Attic tunnel, before staging."
  exit 1
fi
require_fixed scripts/deploy.sh 'recover_local_attic_tunnel_if_needed \' \
  "Real deploys must recover the optional workstation Attic tunnel once the allocation is known."
require_fixed scripts/helpers/repo-common.sh 'local_attic_cache_recovery_needed' \
  "Attic tunnel recovery must be decided from actual workstation participation."
require_fixed scripts/helpers/repo-common.sh 'continuing without the local Attic cache' \
  "An unavailable optional Attic cache must warn and continue with the public caches."
require_fixed scripts/helpers/repo-common.sh 'required' \
  "Callers such as repository validation must keep the fail-closed tunnel contract."

acquire_line="$(rg -n '^acquire_deploy_lock$' scripts/helpers/deploy-executor.sh | cut -d: -f1)"
capture_line="$(rg -n '^capture_previous_state$' scripts/helpers/deploy-executor.sh | cut -d: -f1)"
if [[ ! "$acquire_line" =~ ^[0-9]+$ || ! "$capture_line" =~ ^[0-9]+$ ]] \
  || ((acquire_line >= capture_line)); then
  echo "❌ Deploy must acquire the target transaction lock before capturing live and boot rollback state."
  exit 1
fi

build_line="$(rg -n 'built_toplevel="\$\("\$\{cmd\[@\]\}"\)"' scripts/helpers/deploy-executor.sh | cut -d: -f1)"
test_timer_line="$(rg -n 'schedule_rollback "24h"' scripts/helpers/deploy-executor.sh | cut -d: -f1)"
test_activation_line="$(rg -n 'run_detached_activation "\$built_toplevel" test tested-build' scripts/helpers/deploy-executor.sh | cut -d: -f1)"
if [[ ! "$build_line" =~ ^[0-9]+$ || ! "$test_timer_line" =~ ^[0-9]+$ || ! "$test_activation_line" =~ ^[0-9]+$ ]] \
  || ((build_line >= test_timer_line || test_timer_line >= test_activation_line)); then
  echo "❌ Test deploy must finish build/copy before arming rollback and starting guarded activation."
  exit 1
fi

source scripts/helpers/deploy-transaction.sh
valid_hash='sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA='
valid_toplevel='/nix/store/00000000000000000000000000000000-nixos-system-test-1'
stamp_path="$archive_test_dir/tested.stamp"
deploy_render_test_stamp "$valid_hash" "$valid_toplevel" >"$stamp_path"
parsed_hash=""
parsed_toplevel=""
deploy_read_test_stamp "$stamp_path" parsed_hash parsed_toplevel
if [[ "$parsed_hash" != "$valid_hash" || "$parsed_toplevel" != "$valid_toplevel" ]]; then
  echo "❌ Tested deployment stamp did not round-trip exactly."
  exit 1
fi

if deploy_render_test_stamp 'not-a-hash' "$valid_toplevel" >/dev/null 2>&1 \
  || deploy_render_test_stamp "$valid_hash" '/tmp/not-a-store-path' >/dev/null 2>&1; then
  echo "❌ Deployment stamp accepted an unsafe hash or closure path."
  exit 1
fi

printf 'version=1\nsource_hash=%s\ntoplevel=%s\nunknown=value\n' \
  "$valid_hash" "$valid_toplevel" >"$archive_test_dir/unknown.stamp"
if deploy_read_test_stamp "$archive_test_dir/unknown.stamp" parsed_hash parsed_toplevel >/dev/null 2>&1; then
  echo "❌ Deployment stamp accepted an unknown field."
  exit 1
fi

ln -s "$stamp_path" "$archive_test_dir/symlink.stamp"
if deploy_read_test_stamp "$archive_test_dir/symlink.stamp" parsed_hash parsed_toplevel >/dev/null 2>&1; then
  echo "❌ Deployment stamp parser followed a symlink."
  exit 1
fi

attic_test_dir="$archive_test_dir/attic-tunnel"
attic_mock_bin="$attic_test_dir/bin"
attic_ready_marker="$attic_test_dir/ready"
attic_started_marker="$attic_test_dir/started"
attic_log="$attic_test_dir/tunnel.log"
mkdir -p "$attic_mock_bin"

cat >"$attic_mock_bin/curl" <<'EOF'
#!/usr/bin/env bash
[[ -f "$ATTIC_TEST_READY_MARKER" ]]
EOF
chmod +x "$attic_mock_bin/curl"

cat >"$attic_test_dir/tunnel" <<'EOF'
#!/usr/bin/env bash
touch "$ATTIC_TEST_STARTED_MARKER" "$ATTIC_TEST_READY_MARKER"
EOF
chmod +x "$attic_test_dir/tunnel"
make_test_executable "$attic_mock_bin/curl" "$attic_test_dir/tunnel"

export ATTIC_TEST_READY_MARKER="$attic_ready_marker"
export ATTIC_TEST_STARTED_MARKER="$attic_started_marker"
export NIXHOMESERVER_ATTIC_WAIT_ATTEMPTS=5
export NIXHOMESERVER_ATTIC_WAIT_DELAY=0.01

touch "$attic_ready_marker"
PATH="$attic_mock_bin:$PATH" ensure_local_attic_tunnel \
  'http://127.0.0.1:8080/nixhomeserver/nix-cache-info' \
  "$attic_test_dir/tunnel" \
  "$attic_log"
if [[ -e "$attic_started_marker" ]]; then
  echo "❌ Deploy preflight relaunched an already healthy Attic tunnel."
  exit 1
fi

rm -f "$attic_ready_marker"
PATH="$attic_mock_bin:$PATH" ensure_local_attic_tunnel \
  'http://127.0.0.1:8080/nixhomeserver/nix-cache-info' \
  "$attic_test_dir/tunnel" \
  "$attic_log"
if [[ ! -e "$attic_started_marker" || ! -e "$attic_ready_marker" ]]; then
  echo "❌ Deploy preflight did not recover the unavailable Attic tunnel."
  exit 1
fi

# The required contract must stay fail-closed for callers such as repository
# validation: a permanently unreachable tunnel is an error, not a warning.
cat >"$attic_mock_bin/curl" <<'EOF'
#!/usr/bin/env bash
[[ -f "$ATTIC_TEST_NEVER_READY_MARKER" ]]
EOF
cat >"$attic_test_dir/never-ready-tunnel" <<'EOF'
#!/usr/bin/env bash
touch "$ATTIC_TEST_STARTED_MARKER"
EOF
make_test_executable "$attic_mock_bin/curl" "$attic_test_dir/never-ready-tunnel"
export ATTIC_TEST_NEVER_READY_MARKER="$attic_test_dir/never-ready"
rm -f "$attic_started_marker"
touch "$attic_test_dir/never-ready-tunnel.log"
if required_output="$(PATH="$attic_mock_bin:$PATH" ensure_local_attic_tunnel \
  'http://127.0.0.1:8080/nixhomeserver/nix-cache-info' \
  "$attic_test_dir/never-ready-tunnel" \
  "$attic_test_dir/never-ready-tunnel.log" 2>&1)"; then
  echo "❌ A required Attic tunnel accepted a permanently unreachable cache."
  exit 1
fi
if ! rg -Fq 'blocked: local Attic cache tunnel did not become ready' <<<"$required_output"; then
  echo "❌ A required Attic tunnel must still fail closed with its blocked diagnosis."
  echo "$required_output"
  exit 1
fi
if rg -Fq 'warning:' <<<"$required_output"; then
  echo "❌ A required Attic tunnel must not downgrade its diagnosis to a warning."
  echo "$required_output"
  exit 1
fi

# The optional contract downgrades the same diagnosis but still reports it.
if optional_output="$(PATH="$attic_mock_bin:$PATH" ensure_local_attic_tunnel \
  'http://127.0.0.1:8080/nixhomeserver/nix-cache-info' \
  "$attic_test_dir/never-ready-tunnel" \
  "$attic_test_dir/never-ready-tunnel.log" optional 2>&1)"; then
  echo "❌ An optional Attic tunnel reported success for an unreachable cache."
  exit 1
fi
if ! rg -Fq 'warning: local Attic cache tunnel did not become ready' <<<"$optional_output"; then
  echo "❌ An optional Attic tunnel must warn instead of blocking."
  echo "$optional_output"
  exit 1
fi

if ensure_local_attic_tunnel \
  'http://127.0.0.1:8080/nixhomeserver/nix-cache-info' \
  "$attic_test_dir/tunnel" \
  "$attic_log" maybe >/dev/null 2>&1; then
  echo "❌ An unknown Attic tunnel requirement was accepted."
  exit 1
fi

# Allocation awareness: recovery is decided from actual workstation
# participation, never from a mode name. `nix` is mocked to report whether the
# loopback Attic cache is a configured substituter so no real Nix state, cache
# or network is touched.
attic_nix_dir="$attic_test_dir/nix-bin"
mkdir -p "$attic_nix_dir"
cat >"$attic_nix_dir/nix" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "config" ]]; then
  if [[ -f "$ATTIC_TEST_SUBSTITUTER_MARKER" ]]; then
    printf 'substituters = https://cache.nixos.org http://127.0.0.1:8080/nixhomeserver\n'
  else
    printf 'substituters = https://cache.nixos.org\n'
  fi
  exit 0
fi
exit 0
EOF
make_test_executable "$attic_nix_dir/nix"
export ATTIC_TEST_SUBSTITUTER_MARKER="$attic_test_dir/substituter-configured"

for build_locally in true false; do
  for marker_state in configured absent; do
    if [[ "$marker_state" == "configured" ]]; then
      touch "$ATTIC_TEST_SUBSTITUTER_MARKER"
    else
      rm -f "$ATTIC_TEST_SUBSTITUTER_MARKER"
    fi
    if PATH="$attic_nix_dir:$PATH" local_attic_cache_recovery_needed \
      "$build_locally" 'http://127.0.0.1:8080/nixhomeserver'; then
      need_recovery=true
    else
      need_recovery=false
    fi
    if [[ "$build_locally" == "true" && "$marker_state" == "configured" ]]; then
      expected_recovery=true
    else
      expected_recovery=false
    fi
    if [[ "$need_recovery" != "$expected_recovery" ]]; then
      echo "❌ Attic recovery decision ignored workstation participation or cache configuration."
      echo "   build_locally=${build_locally} substituter=${marker_state} -> ${need_recovery}"
      exit 1
    fi
  done
done

# A remote-only deployment must not invoke the tunnel helper at all.
tunnel_invocation_marker="$attic_test_dir/tunnel-invoked"
cat >"$attic_test_dir/invoked-tunnel" <<EOF
#!/usr/bin/env bash
touch "$tunnel_invocation_marker"
EOF
make_test_executable "$attic_test_dir/invoked-tunnel"
touch "$ATTIC_TEST_SUBSTITUTER_MARKER"
rm -f "$tunnel_invocation_marker"
PATH="$attic_nix_dir:$attic_mock_bin:$PATH" recover_local_attic_tunnel_if_needed \
  false \
  'http://127.0.0.1:8080/nixhomeserver' \
  "$attic_test_dir/invoked-tunnel" \
  "$attic_log"
if [[ -e "$tunnel_invocation_marker" ]]; then
  echo "❌ Deploy started the workstation Attic tunnel for a non-workstation allocation."
  exit 1
fi

# A dry-run resolves the allocation and reports it without touching the cache.
rm -f "$tunnel_invocation_marker"
DEPLOY_DRY_RUN=1 PATH="$attic_nix_dir:$attic_mock_bin:$PATH" recover_local_attic_tunnel_if_needed \
  true \
  'http://127.0.0.1:8080/nixhomeserver' \
  "$attic_test_dir/invoked-tunnel" \
  "$attic_log"
if [[ -e "$tunnel_invocation_marker" ]]; then
  echo "❌ A deploy dry-run started the workstation Attic tunnel."
  exit 1
fi

# A workstation build with an unavailable optional tunnel warns and continues.
rm -f "$tunnel_invocation_marker"
if unavailable_output="$(PATH="$attic_nix_dir:$attic_mock_bin:$PATH" recover_local_attic_tunnel_if_needed \
  true \
  'http://127.0.0.1:8080/nixhomeserver' \
  "$attic_test_dir/missing-tunnel-helper" \
  "$attic_log" 2>&1)"; then
  :
else
  echo "❌ An unavailable optional Attic tunnel aborted the deploy."
  echo "$unavailable_output"
  exit 1
fi
if ! rg -Fq 'warning: local Attic cache is configured but its tunnel is unavailable' <<<"$unavailable_output" \
  || ! rg -Fq 'warning: continuing without the local Attic cache' <<<"$unavailable_output"; then
  echo "❌ An unavailable optional Attic tunnel must warn and continue with the public caches."
  echo "$unavailable_output"
  exit 1
fi

# End-to-end through deploy.sh for all four allocation modes, with `nix`,
# `curl`, `nix-store` and the tunnel helper all mocked: nothing touches the real
# Nix configuration, cache, network, or server. `nix eval` returns a fixture so
# the allocation resolves deterministically, and the mocked `nix-store --gc`
# aborts the run immediately after the optional preflight, before any staging,
# SSH, or build work.
attic_e2e_dir="$attic_test_dir/e2e"
mkdir -p "$attic_e2e_dir/bin"
cat >"$attic_e2e_dir/bin/nix" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "config" && "${2:-}" == "show" && "${3:-}" == "substituters" ]]; then
  if [[ -f "$ATTIC_E2E_SUBSTITUTER_MARKER" ]]; then
    printf 'substituters = https://cache.nixos.org http://127.0.0.1:8080/nixhomeserver\n'
  else
    printf 'substituters = https://cache.nixos.org\n'
  fi
  exit 0
fi
if [[ "${1:-}" == "eval" ]]; then
  cat <<'JSON'
{
  "localNixGCMode": "always",
  "nixGcRetentionDays": 30,
  "localDiskCleanup": { "triggerPercent": 80, "monitorPaths": [ "/var" ], "journalVacuumTime": "1day" },
  "buildMode": "remote",
  "buildSlots": { "local": 0, "remote": "auto" },
  "buildCores": { "local": 0, "remote": 0 },
  "hostPlatform": "x86_64-linux",
  "serverSSHPubKey": "ssh-ed25519 AAAA",
  "hostname": "fixture-host",
  "localAdminUser": "admin",
  "serverLanIP": "127.0.0.1"
}
JSON
  exit 0
fi
exit 0
EOF
cat >"$attic_e2e_dir/bin/nix-store" <<'EOF'
#!/usr/bin/env bash
# Stops the fixture deploy at the first post-preflight step so the suite never
# stages an archive, contacts SSH, or builds anything.
echo 'mock nix-store --gc: stopping the fixture deploy' >&2
exit 1
EOF
cat >"$attic_e2e_dir/bin/curl" <<'EOF'
#!/usr/bin/env bash
[[ -f "$ATTIC_E2E_READY_MARKER" ]]
EOF
cat >"$attic_e2e_dir/bin/tunnel" <<'EOF'
#!/usr/bin/env bash
touch "$ATTIC_E2E_TUNNEL_MARKER" "$ATTIC_E2E_READY_MARKER"
EOF
make_test_executable "$attic_e2e_dir/bin/nix" "$attic_e2e_dir/bin/nix-store" \
  "$attic_e2e_dir/bin/curl" "$attic_e2e_dir/bin/tunnel"
export ATTIC_E2E_SUBSTITUTER_MARKER="$attic_e2e_dir/substituter-configured"
export ATTIC_E2E_TUNNEL_MARKER="$attic_e2e_dir/tunnel-invoked"
export ATTIC_E2E_READY_MARKER="$attic_e2e_dir/tunnel-ready"
touch "$ATTIC_E2E_SUBSTITUTER_MARKER"
export NIXHOMESERVER_ATTIC_TUNNEL_SCRIPT="$attic_e2e_dir/bin/tunnel"
export XDG_CACHE_HOME="$attic_e2e_dir/cache"

run_attic_e2e_deploy() {
  local e2e_log="$1"
  shift
  PATH="$attic_e2e_dir/bin:$PATH" \
    bash scripts/deploy.sh "$@" --action test >"$e2e_log" 2>&1 || true
}

# Only allocations that actually build on the workstation may recover the
# cache, and an unavailable cache must never abort such a deploy.
for mode in local balanced maximum-effort; do
  rm -f "$ATTIC_E2E_TUNNEL_MARKER" "$ATTIC_E2E_READY_MARKER"
  run_attic_e2e_deploy "$attic_e2e_dir/${mode}.log" --build-mode "$mode"
  if [[ ! -e "$ATTIC_E2E_TUNNEL_MARKER" ]]; then
    echo "❌ A ${mode} allocation builds on the workstation but never recovered its Attic cache."
    cat "$attic_e2e_dir/${mode}.log"
    exit 1
  fi
  if ! rg -Fq 'mock nix-store --gc: stopping the fixture deploy' "$attic_e2e_dir/${mode}.log"; then
    echo "❌ The ${mode} fixture deploy never reached its post-preflight stage."
    cat "$attic_e2e_dir/${mode}.log"
    exit 1
  fi
done

rm -f "$ATTIC_E2E_TUNNEL_MARKER" "$ATTIC_E2E_READY_MARKER"
run_attic_e2e_deploy "$attic_e2e_dir/remote.log" --build-mode remote
if ! rg -Fq 'mock nix-store --gc: stopping the fixture deploy' "$attic_e2e_dir/remote.log"; then
  echo "❌ The remote fixture deploy never reached its post-preflight stage."
  cat "$attic_e2e_dir/remote.log"
  exit 1
fi
if [[ -e "$ATTIC_E2E_TUNNEL_MARKER" ]]; then
  echo "❌ A remote-only allocation recovered a workstation-only Attic cache."
  cat "$attic_e2e_dir/remote.log"
  exit 1
fi

# Explicit overrides must reach the same decision: --build-locally is a
# workstation allocation, --build-host a remote one.
rm -f "$ATTIC_E2E_TUNNEL_MARKER" "$ATTIC_E2E_READY_MARKER"
run_attic_e2e_deploy "$attic_e2e_dir/build-locally.log" --build-locally
if ! rg -Fq 'mock nix-store --gc: stopping the fixture deploy' "$attic_e2e_dir/build-locally.log"; then
  echo "❌ The --build-locally fixture deploy never reached its post-preflight stage."
  cat "$attic_e2e_dir/build-locally.log"
  exit 1
fi
if [[ ! -e "$ATTIC_E2E_TUNNEL_MARKER" ]]; then
  echo "❌ --build-locally must recover the workstation Attic cache."
  cat "$attic_e2e_dir/build-locally.log"
  exit 1
fi

rm -f "$ATTIC_E2E_TUNNEL_MARKER" "$ATTIC_E2E_READY_MARKER"
run_attic_e2e_deploy "$attic_e2e_dir/build-host.log" --build-host admin@127.0.0.1
if ! rg -Fq 'mock nix-store --gc: stopping the fixture deploy' "$attic_e2e_dir/build-host.log"; then
  echo "❌ The --build-host fixture deploy never reached its post-preflight stage."
  cat "$attic_e2e_dir/build-host.log"
  exit 1
fi
if [[ -e "$ATTIC_E2E_TUNNEL_MARKER" ]]; then
  echo "❌ --build-host must not recover a workstation-only Attic cache."
  cat "$attic_e2e_dir/build-host.log"
  exit 1
fi

# A workstation deploy whose cache stays unreachable warns and keeps going.
rm -f "$ATTIC_E2E_TUNNEL_MARKER" "$ATTIC_E2E_READY_MARKER"
unreachable_log="$attic_e2e_dir/unreachable.log"
ATTIC_E2E_READY_MARKER="$attic_e2e_dir/never-ready" \
  PATH="$attic_e2e_dir/bin:$PATH" \
  NIXHOMESERVER_ATTIC_TUNNEL_SCRIPT="$attic_e2e_dir/bin/curl" \
  NIXHOMESERVER_ATTIC_WAIT_ATTEMPTS=2 \
  NIXHOMESERVER_ATTIC_WAIT_DELAY=0.01 \
  bash scripts/deploy.sh --build-mode local --action test >"$unreachable_log" 2>&1 || true
if ! rg -Fq 'warning: local Attic cache tunnel did not become ready' "$unreachable_log" \
  || ! rg -Fq 'warning: continuing without the local Attic cache' "$unreachable_log"; then
  echo "❌ An unreachable optional Attic cache must warn and continue the workstation deploy."
  cat "$unreachable_log"
  exit 1
fi
if ! rg -Fq 'mock nix-store --gc: stopping the fixture deploy' "$unreachable_log"; then
  echo "❌ An unavailable optional Attic cache aborted a workstation deploy."
  cat "$unreachable_log"
  exit 1
fi

# A dashboard-selected default that is remote-only must still skip the
# workstation cache; a dashboard-selected local allocation must recover it.
# `ssh` is mocked so the dashboard read succeeds without a server.
dashboard_remote_dir="$attic_e2e_dir/dash-remote"
mkdir -p "$dashboard_remote_dir"
cat >"$dashboard_remote_dir/ssh" <<'EOF'
#!/usr/bin/env bash
printf '{"schemaVersion":1,"buildMode":"remote","updatedAt":"2026-09-08T20:00:00Z"}\n'
EOF
cat >"$dashboard_remote_dir/ssh-local" <<'EOF'
#!/usr/bin/env bash
printf '{"schemaVersion":1,"buildMode":"local","updatedAt":"2026-09-08T20:00:00Z"}\n'
EOF
make_test_executable "$dashboard_remote_dir/ssh" "$dashboard_remote_dir/ssh-local"

mkdir -p "$dashboard_remote_dir/local"
cp "$dashboard_remote_dir/ssh-local" "$dashboard_remote_dir/local/ssh"

rm -f "$ATTIC_E2E_TUNNEL_MARKER" "$ATTIC_E2E_READY_MARKER"
PATH="$dashboard_remote_dir:$attic_e2e_dir/bin:$PATH" \
  bash scripts/deploy.sh --action test >"$attic_e2e_dir/dash-remote.log" 2>&1 || true
if ! rg -Fq "build mode: using dashboard-selected 'remote'" "$attic_e2e_dir/dash-remote.log"; then
  echo "❌ Deploy stopped adopting the dashboard-selected default allocation."
  cat "$attic_e2e_dir/dash-remote.log"
  exit 1
fi
if ! rg -Fq 'mock nix-store --gc: stopping the fixture deploy' "$attic_e2e_dir/dash-remote.log"; then
  echo "❌ The dashboard-selected remote fixture deploy never reached its post-preflight stage."
  cat "$attic_e2e_dir/dash-remote.log"
  exit 1
fi
if [[ -e "$ATTIC_E2E_TUNNEL_MARKER" ]]; then
  echo "❌ A dashboard-selected remote allocation recovered a workstation-only Attic cache."
  cat "$attic_e2e_dir/dash-remote.log"
  exit 1
fi

rm -f "$ATTIC_E2E_TUNNEL_MARKER" "$ATTIC_E2E_READY_MARKER"
PATH="$dashboard_remote_dir/local:$attic_e2e_dir/bin:$PATH" \
  bash scripts/deploy.sh --action test >"$attic_e2e_dir/dash-local.log" 2>&1 || true
if ! rg -Fq "build mode: using dashboard-selected 'local'" "$attic_e2e_dir/dash-local.log"; then
  echo "❌ Deploy stopped adopting a dashboard-selected workstation allocation."
  cat "$attic_e2e_dir/dash-local.log"
  exit 1
fi
if [[ ! -e "$ATTIC_E2E_TUNNEL_MARKER" ]]; then
  echo "❌ A dashboard-selected workstation allocation must recover its Attic cache."
  cat "$attic_e2e_dir/dash-local.log"
  exit 1
fi

build_mode_dir="$archive_test_dir/build-mode"
mkdir -p "$build_mode_dir"
source scripts/helpers/dashboard-build-mode.sh

mock_ssh() {
  local behaviour="$1"
  mkdir -p "$build_mode_dir/bin-$behaviour"
  cat >"$build_mode_dir/bin-$behaviour/ssh" <<EOF
#!/usr/bin/env bash
case "$behaviour" in
  dashboard-mode) printf '{"schemaVersion":1,"buildMode":"balanced","updatedAt":"2026-09-08T20:00:00Z"}\n' ;;
  dashboard-invalid) printf '{"schemaVersion":1,"buildMode":"turbo"}\n' ;;
  dashboard-garbage) printf 'not json at all\n' ;;
  *) exit 255 ;;
esac
EOF
  make_test_executable "$build_mode_dir/bin-$behaviour/ssh"
  printf '%s' "$build_mode_dir/bin-$behaviour"
}

if [[ "$(PATH="$(mock_ssh dashboard-mode):$PATH" read_dashboard_build_mode admin@target.test)" != "balanced" ]]; then
  echo "❌ Deploy did not adopt a valid dashboard-selected build mode."
  exit 1
fi
for behaviour in dashboard-unreachable dashboard-invalid dashboard-garbage; do
  if PATH="$(mock_ssh "$behaviour"):$PATH" read_dashboard_build_mode admin@target.test >/dev/null 2>&1; then
    echo "❌ Dashboard build mode fallback failed for $behaviour."
    exit 1
  fi
done

require_fixed scripts/deploy.sh 'dashboard_build_mode="$(read_dashboard_build_mode "$target_host")"' \
  "Real deploys must adopt the dashboard-selected build mode from the resolved target host."
require_fixed scripts/deploy.sh 'source "$script_dir/helpers/dashboard-build-mode.sh"' \
  "Real deploys must consult the dashboard-selected build mode."
require_fixed scripts/helpers/dashboard-build-mode.sh 'local|remote|balanced|maximum-effort' \
  "Dashboard build mode reads must only accept the four known allocation modes."
require_fixed scripts/helpers/dashboard-build-mode.sh '/var/lib/deploy-settings/build-mode.json' \
  "Dashboard build mode reads must target the persisted deploy-settings state file."
require_fixed modules/Core_Modules/homepage/services.nix 'homepage-nix-build-mode-apply' \
  "The dashboard build mode must be written through a narrowly-scoped root helper."

echo "✅ Deploy CLI tests passed."

require_fixed scripts/helpers/deploy-executor.sh 'nixpkgs#cargo' \
  "Remote debug validation must provide Cargo for workspace dependency checks."
