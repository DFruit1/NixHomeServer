#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"
cd "$TESTS_REPO_ROOT"
ensure_tools jq nix sed

host="$(test_default_host)"

# Lightweight check: verify a representative subset of apps cleanly disable.
# Deep removal/disable validation is covered by test-module-removal-evaluation.sh.
# This test just ensures the enable=false mechanism doesn't regress for common apps.
cases=(calibre-web chaptarr forgejo freshrss ipfs langfuse prowlarr search sonarr)

# Evaluate all at once on the configured evaluation host.
cases_csv="$(IFS=,; echo "${cases[*]}")"
echo "Evaluating enable=false variants: $cases_csv"

host_literal="$(jq -cn --arg value "$host" '$value' | sed 's/${/\\${/g')"
cases_literal="$(jq -cn --arg value "$cases_csv" '$value')"
disabled_json="$(remote_eval_batch_json "disabled=
  import ./scripts/tests/module-disable-matrix.nix {
    flake = f;
    hostName = $host_literal;
    requestedCaseNames = lib.splitString \",\" $cases_literal;
  }
" | jq -e '.disabled')"

expected_keys="$(jq -cn '$ARGS.positional | sort' --args "${cases[@]}")"

jq -e --argjson expected "$expected_keys" '
  (keys == $expected)
  and all(
    .[];
    .valid
    and .registryPresent
    and (.drvPath | startswith("/nix/store/") and endswith(".drv"))
    and (.presentServices == [])
    and (.presentContainers == [])
    and (.presentTimers == [])
    and (.presentCaddyHosts == [])
    and (.presentPrivateHosts == [])
    and (.presentGatewayApps == [])
    and (.presentOauthClients == [])
    and (.presentKanidmGroups == [])
    and (.presentUsers == [])
    and (.presentGroups == [])
    and (.presentSecrets == [])
    and (.presentBackupApps == [])
    and (.presentGuardedServices == [])
    and (.missingPersistence == [])
  )
' <<<"$disabled_json" >/dev/null || {
  echo "❌ An enable=false app retained an active runtime, route, identity, secret, backup, integration, or lost persisted state."
  jq . <<<"$disabled_json"
  exit 1
}

echo "✅ App enable=false switches remove active surfaces while retaining module registration and persisted state."
