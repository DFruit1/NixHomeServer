#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"
cd "$TESTS_REPO_ROOT"
ensure_tools jq nix

host="$(test_default_host)"
cases=(
  groundwater-logger
  mail-archive-ui
  media-automation-all
  prowlarr
  qbittorrent
  radarr
  seerr
  sonarr
)

# Full NixOS configurations are large. Keep evaluation memory bounded so this
# clean-host regression remains safe on the documented 8 GiB minimum system.
batch_size=2
for ((offset = 0; offset < ${#cases[@]}; offset += batch_size)); do
  batch=("${cases[@]:offset:batch_size}")
  batch_csv="$(IFS=,; echo "${batch[*]}")"
  expected_keys="$(jq -cn '$ARGS.positional | sort' --args "${batch[@]}")"
  echo "Evaluating enable=false variants: $batch_csv"
  disabled_json="$(
    NIXHOMESERVER_TEST_HOST="$host" \
      NIXHOMESERVER_DISABLE_CASES="$batch_csv" \
      nix eval --impure --json --file scripts/tests/module-disable-matrix.nix
  )"

  jq -e --argjson expected "$expected_keys" '
    (keys == $expected)
    and all(
      .[];
      .valid
      and .registryPresent
      and (.drvPath | startswith("/nix/store/") and endswith(".drv"))
      and (.presentServices == [])
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
done

echo "✅ All app enable=false switches remove active surfaces while retaining module registration and persisted state."
