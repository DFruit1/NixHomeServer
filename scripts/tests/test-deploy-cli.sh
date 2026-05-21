#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"

cd "$TESTS_REPO_ROOT"

ensure_tools bash nix rg

expected_hostname="$(nix_flake_var 'vars.hostname')"
expected_local_admin="$(nix_flake_var 'vars.localAdminUser')"
expected_target="${expected_local_admin}@${expected_hostname}"

default_output="$(DEPLOY_DRY_RUN=1 bash scripts/deploy.sh --action test)"
if ! rg -Fq "mode=remote" <<<"$default_output"; then
  echo "❌ Deploy default should build remotely on the target host."
  echo "$default_output"
  exit 1
fi
if ! rg -Fq "target_host=${expected_target}" <<<"$default_output"; then
  echo "❌ Deploy default target should come from vars.localAdminUser and vars.hostname."
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

conflict_output="$(DEPLOY_DRY_RUN=1 bash scripts/deploy.sh --build-locally --build-host "$expected_target" 2>&1 || true)"
if ! rg -Fq "blocked: --build-locally cannot be combined with --build-host" <<<"$conflict_output"; then
  echo "❌ Deploy should reject --build-locally with --build-host."
  echo "$conflict_output"
  exit 1
fi

help_output="$(bash scripts/deploy.sh --help)"
if ! rg -Fq -- "--build-locally" <<<"$help_output"; then
  echo "❌ Deploy help should document --build-locally."
  echo "$help_output"
  exit 1
fi

echo "✅ Deploy CLI tests passed."
