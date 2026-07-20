#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"

cd "$TESTS_REPO_ROOT"

ensure_tools bash git mktemp nix rg tar

expected_hostname="$(nix_flake_var 'vars.hostname')"
expected_lan_ip="$(nix_flake_var 'vars.serverLanIP')"
expected_local_admin="$(nix_flake_var 'vars.localAdminUser')"
expected_target="${expected_local_admin}@${expected_lan_ip}"

archive_test_dir="$(mktemp -d '/tmp/nixhomeserver deploy.XXXXXX')"
cleanup() { rm -rf "$archive_test_dir"; }
trap cleanup EXIT
archive_path="$archive_test_dir/repository.tar"
archive_root="$archive_test_dir/extracted repository"
mkdir -p "$archive_root"
create_deploy_repo_archive "$archive_path"
tar -xf "$archive_path" -C "$archive_root"
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
if ! rg -Fq "mode=remote" <<<"$default_output"; then
  echo "❌ Deploy default should build remotely on the target host."
  echo "$default_output"
  exit 1
fi
if ! rg -Fq "target_host=${expected_target}" <<<"$default_output"; then
  echo "❌ Deploy default target should use the local admin and LAN IP for first-boot reachability."
  echo "$default_output"
  exit 1
fi
if ! rg -Fq "build_host=${expected_target}" <<<"$default_output"; then
  echo "❌ Deploy default build host should be the target host."
  echo "$default_output"
  exit 1
fi
if rg -Fq -- "--target-host" <<<"$default_output"; then
  echo "❌ Default same-host rebuild should not pass --target-host from inside the target shell."
  echo "$default_output"
  exit 1
fi
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
if ! rg -Fq -- "--build-locally" <<<"$help_output"; then
  echo "❌ Deploy help should document --build-locally."
  echo "$help_output"
  exit 1
fi

require_fixed scripts/helpers/deploy-executor.sh 'homepage_canary_enabled' \
  "Guarded deploy must detect whether the optional Homepage canary exists."
require_fixed scripts/helpers/deploy-executor.sh 'skipping authenticated service-access canary: homepage module is absent' \
  "Guarded deploy must succeed when Homepage is removed."
require_fixed scripts/deploy.sh 'source "$script_dir/helpers/deploy-command.sh"' \
  "Deploy dry-runs and real execution must share command construction."
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
require_fixed scripts/deploy.sh 'need git ssh tar' \
  "Deploy source creation must require Git rather than broad-archiving a copied tree."
forbid_match scripts/helpers/deploy-executor.sh 'nixos-rebuild boot' \
  "Deploy must not commit a boot generation before the health gates."

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

echo "✅ Deploy CLI tests passed."
