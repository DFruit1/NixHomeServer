#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"
cd "$TESTS_REPO_ROOT"
ensure_tools bash jq nix rg

runtime_json="$(nix eval --json '.#nixosConfigurations.server.config.systemd.services' \
  --apply 'services: {
    shortScript = services.storage-smart-short.script;
    longScript = services.storage-smart-long.script;
    shortPath = map toString services.storage-smart-short.path;
    longPath = map toString services.storage-smart-long.path;
  }')"

jq -e '
  (.shortScript | contains("--config-json-file /nix/store/"))
  and (.longScript | contains("--config-json-file /nix/store/"))
  and (.shortPath | all(contains("-nix-") | not))
  and (.longPath | all(contains("-nix-") | not))
' <<<"$runtime_json" >/dev/null || {
  echo "SMART sweeps regained a runtime Nix/repository dependency." >&2
  jq . <<<"$runtime_json"
  exit 1
}

inventory_program="$(nix build --impure --no-link --print-out-paths --expr '
  let
    f = builtins.getFlake (builtins.getEnv "NIXHOMESERVER_FLAKE_REF_FOR_EVAL");
    host = builtins.head (builtins.attrNames f.nixosConfigurations);
    packages = (builtins.getAttr host f.nixosConfigurations).config.environment.systemPackages;
    matches = builtins.filter (package: (package.name or "") == "nixhomeserver-storage-inventory") packages;
  in assert builtins.length matches == 1; builtins.head matches
')"
if [[ "$inventory_program" != /nix/store/*-nixhomeserver-storage-inventory ]]; then
  echo "The evaluated server does not install exactly one storage inventory command." >&2
  exit 1
fi
rg -Fq -- '--config-json-file /nix/store/' "$inventory_program/bin/nixhomeserver-storage-inventory"
if rg -Fq 'scripts/helpers/repo-common.sh' "$inventory_program/bin/nixhomeserver-storage-inventory"; then
  echo "Installed storage inventory command regained a live repository dependency." >&2
  exit 1
fi

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
config="$tmpdir/storage.json"
args_log="$tmpdir/discovery.args"
output="$tmpdir/output"
printf '{}\n' >"$config"

cat >"$tmpdir/discover" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >"${TEST_DISCOVERY_ARGS_LOG:?}"
if [[ "${TEST_EMPTY_INVENTORY:-false}" == true ]]; then
  printf '%s\n' '{"allSmartDisks":[]}'
  exit 0
fi
cat <<'JSON'
{"allSmartDisks":[
  {"label":"system","device":"/dev/fake-system","smartctlArgs":[]},
  {"label":"data1","device":"/dev/fake-data","smartctlArgs":["-d","sat"]}
]}
JSON
EOF

cat >"$tmpdir/smartctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$*" == *"/dev/fake-data"* && "${TEST_FAIL_DATA_DISK:-false}" == true ]]; then
  exit 4
fi
printf 'started %s\n' "$*"
EOF
chmod +x "$tmpdir/discover" "$tmpdir/smartctl"

if PATH="$tmpdir:$PATH" \
  TEST_DISCOVERY_ARGS_LOG="$args_log" \
  TEST_FAIL_DATA_DISK=true \
  STORAGE_SMART_SWEEP_DISCOVERY_BIN="$tmpdir/discover" \
  bash scripts/run-storage-smart-sweep.sh --kind short --config-json-file "$config" \
  >"$output" 2>&1; then
  echo "SMART sweep returned success despite a failed disk self-test request." >&2
  exit 1
fi
rg -q 'attempted=2 failed=1' "$output"
rg -Fq -- "--format json --config-json-file $config" "$args_log"

PATH="$tmpdir:$PATH" \
  TEST_DISCOVERY_ARGS_LOG="$args_log" \
  STORAGE_SMART_SWEEP_DISCOVERY_BIN="$tmpdir/discover" \
  bash scripts/run-storage-smart-sweep.sh --kind long --config-json-file "$config" \
  >"$output" 2>&1
rg -q 'attempted=2 failed=0' "$output"

if PATH="$tmpdir:$PATH" \
  TEST_DISCOVERY_ARGS_LOG="$args_log" \
  TEST_EMPTY_INVENTORY=true \
  STORAGE_SMART_SWEEP_DISCOVERY_BIN="$tmpdir/discover" \
  bash scripts/run-storage-smart-sweep.sh --kind short --config-json-file "$config" \
  >"$output" 2>&1; then
  echo "SMART sweep returned success for an empty eligible-disk inventory." >&2
  exit 1
fi
rg -q 'attempted=0 failed=0' "$output"
rg -q 'discovered no eligible disks' "$output"

echo "✅ SMART sweep runtime regression tests passed."
