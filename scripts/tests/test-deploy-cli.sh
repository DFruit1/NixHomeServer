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
if ! rg -Fq -- "--target-host ${expected_target}" <<<"$local_output"; then
  echo "❌ --build-locally should activate the evaluated target over SSH."
  echo "$local_output"
  exit 1
fi
if ! rg -Fq 'nixos-rebuild -- boot' <<<"$local_output" \
  || ! rg -Fq 'activation_command=detached switch-to-configuration switch' <<<"$local_output"; then
  echo "❌ Switch dry-run must describe the real boot build followed by detached activation."
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

echo "✅ Deploy CLI tests passed."
