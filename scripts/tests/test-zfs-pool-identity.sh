#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"
cd "$TESTS_REPO_ROOT"
ensure_tools bash jq mktemp nix rg

guid_validation_json="$(nix eval --impure --json --expr '
let
  f = builtins.getFlake (builtins.getEnv "NIXHOMESERVER_FLAKE_REF_FOR_EVAL");
  validation = import ./lib/storage-validation.nix { lib = f.inputs.nixpkgs.lib; };
in {
  acceptsNull = validation.validZpoolGuid null;
  acceptsQuotedUint64 = validation.validZpoolGuid "18446744073709551615";
  acceptsSmallGuid = validation.validZpoolGuid "1";
  rejectsEmpty = !(validation.validZpoolGuid "");
  rejectsZero = !(validation.validZpoolGuid "0");
  rejectsLeadingZero = !(validation.validZpoolGuid "0123");
  rejectsUint64Overflow = !(validation.validZpoolGuid "18446744073709551616");
  rejectsOverflowWithoutIntegerParsing = !(validation.validZpoolGuid "19999999999999999999");
  rejectsTwentyOneDigits = !(validation.validZpoolGuid "100000000000000000000");
  rejectsLetters = !(validation.validZpoolGuid "123x");
  rejectsInteger = !(validation.validZpoolGuid 123);
  rejectsBoolean = !(validation.validZpoolGuid true);
  rejectsNestedValue = !(validation.validZpoolGuid { value = "123"; });
}
')"
if ! jq -e '[to_entries[] | select(.value != true)] | length == 0' \
  <<<"$guid_validation_json" >/dev/null; then
  echo "ZFS pool GUID configuration validation accepted a malformed value." >&2
  jq . <<<"$guid_validation_json" >&2
  exit 1
fi

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

fake_zpool="$tmpdir/zpool"
fake_realpath="$tmpdir/realpath"
fake_lsblk="$tmpdir/lsblk"
cmdline="$tmpdir/cmdline"
output="$tmpdir/output"
printf 'quiet\n' >"$cmdline"

cat >"$fake_zpool" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$1" in
  get)
    printf '%s\n' "${TEST_POOL_GUID:?}"
    ;;
  status)
    printf '  pool: data\n state: ONLINE\nconfig:\n\n'
    while IFS= read -r path; do
      [[ -n "$path" ]] && printf '\t  %s  ONLINE\n' "$path"
    done <<<"${TEST_POOL_PATHS:-}"
    ;;
  *)
    exit 2
    ;;
esac
EOF

cat >"$fake_realpath" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
path="${@: -1}"
case "$path" in
  /dev/disk/by-id/disk-a) printf '/dev/sda\n' ;;
  /dev/disk/by-id/disk-b) printf '/dev/sdb\n' ;;
  *) printf '%s\n' "$path" ;;
esac
EOF

cat >"$fake_lsblk" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${@: -1}" in
  /dev/sda1) printf 'sda\n' ;;
  /dev/sdb1) printf 'sdb\n' ;;
esac
EOF
chmod +x "$fake_zpool" "$fake_realpath" "$fake_lsblk"

run_verifier() {
  TEST_POOL_GUID="${TEST_POOL_GUID:-123456789}" \
    TEST_POOL_PATHS="${TEST_POOL_PATHS:-/dev/sda1}" \
    ZFS_POOL_IDENTITY_ZPOOL_BIN="$fake_zpool" \
    ZFS_POOL_IDENTITY_REALPATH_BIN="$fake_realpath" \
    ZFS_POOL_IDENTITY_LSBLK_BIN="$fake_lsblk" \
    ZFS_POOL_IDENTITY_CMDLINE_FILE="$cmdline" \
    bash scripts/helpers/verify-zfs-pool-identity.sh "$@"
}

run_verifier --pool data --expected-guid 123456789 \
  --expected-device /dev/disk/by-id/disk-a \
  --expected-device /dev/disk/by-id/disk-b >"$output" 2>&1
rg -q 'Verified ZFS pool data GUID 123456789' "$output"

if TEST_POOL_GUID=987654321 run_verifier --pool data --expected-guid 123456789 \
  --expected-device /dev/disk/by-id/disk-a >"$output" 2>&1; then
  echo "Wrong ZFS GUID unexpectedly passed identity verification." >&2
  exit 1
fi
rg -q 'has GUID 987654321, expected 123456789' "$output"

if TEST_POOL_PATHS=/dev/sdz run_verifier --pool data \
  --expected-device /dev/disk/by-id/disk-a \
  --expected-device /dev/disk/by-id/disk-b >"$output" 2>&1; then
  echo "Foreign same-named ZFS pool unexpectedly passed topology verification." >&2
  exit 1
fi
rg -q 'no member matching the configured by-id topology' "$output"

if TEST_POOL_PATHS=/dev/sdb1 run_verifier --pool data \
  --expected-device /dev/disk/by-id/disk-a \
  --expected-device /dev/disk/by-id/disk-b >"$output" 2>&1; then
  echo "Unpinned ZFS pool with a partial configured topology unexpectedly passed verification." >&2
  exit 1
fi
rg -q 'does not expose every configured member' "$output"

TEST_POOL_PATHS=$'/dev/sda1\n/dev/sdb1' run_verifier --pool data \
  --expected-device /dev/disk/by-id/disk-a \
  --expected-device /dev/disk/by-id/disk-b >"$output" 2>&1
rg -q 'from its configured by-id topology' "$output"

printf 'quiet zfs_recovery_import=1\n' >"$cmdline"
TEST_POOL_GUID=987654321 TEST_POOL_PATHS=/dev/sdz run_verifier \
  --pool data --expected-guid 123456789 \
  --expected-device /dev/disk/by-id/disk-a >"$output" 2>&1
rg -q 'continuing only because zfs_recovery_import=1' "$output"

printf 'quiet\n' >"$cmdline"
if run_verifier --pool data >"$output" 2>&1; then
  echo "Unidentified ZFS pool unexpectedly passed verification." >&2
  exit 1
fi
rg -q 'neither an expected GUID nor configured member devices' "$output"

if run_verifier --pool data --expected-guid not-a-guid \
  --expected-device /dev/disk/by-id/disk-a >"$output" 2>&1; then
  echo "Non-numeric expected ZFS GUID unexpectedly passed validation." >&2
  exit 1
fi
rg -q -- '--expected-guid must be a numeric ZFS pool GUID' "$output"

invalid_guid_expr='
let
  f = builtins.getFlake (builtins.getEnv "NIXHOMESERVER_FLAKE_REF_FOR_EVAL");
  lib = f.inputs.nixpkgs.lib;
  base = import ./vars.nix { inherit lib; };
  vars = base // {
    storage = base.storage // {
      dataPool = base.storage.dataPool // { expectedGuid = true; };
    };
    zfsDataPool = base.zfsDataPool // { expectedGuid = true; };
  };
  pkgs = f.inputs.nixpkgs.legacyPackages.${base.hostPlatform};
  packages = import ./flake/packages.nix { inherit lib pkgs; crane = f.inputs.crane; };
  synthetic = import ./flake/system.nix {
    inputs = f.inputs;
    inherit lib vars pkgs;
    system = base.hostPlatform;
    appPackages = packages.appPackages;
  };
in synthetic.nixosConfigurations.${base.hostname}.config.system.build.toplevel.drvPath
'
if nix eval --impure --raw --expr "$invalid_guid_expr" >"$output" 2>&1; then
  echo "Boolean ZFS expectedGuid unexpectedly passed host evaluation." >&2
  exit 1
fi
if ! rg -Fq 'expectedGuid must be null or a non-empty decimal string' "$output"; then
  echo "Malformed ZFS expectedGuid failed without the actionable assertion." >&2
  cat "$output" >&2
  exit 1
fi

rendered_imports="$(nix eval --impure --json --expr '
let
  f = builtins.getFlake (builtins.getEnv "NIXHOMESERVER_FLAKE_REF_FOR_EVAL");
  lib = f.inputs.nixpkgs.lib;
  base = import ./vars.nix { inherit lib; };
  expectedGuid = "12345678901234567890";
  vars = base // {
    storage = base.storage // {
      dataPool = base.storage.dataPool // { inherit expectedGuid; };
    };
    zfsDataPool = base.zfsDataPool // { inherit expectedGuid; };
  };
  pkgs = f.inputs.nixpkgs.legacyPackages.${base.hostPlatform};
  packages = import ./flake/packages.nix { inherit lib pkgs; crane = f.inputs.crane; };
  synthetic = import ./flake/system.nix {
    inputs = f.inputs;
    inherit lib vars pkgs;
    system = base.hostPlatform;
    appPackages = packages.appPackages;
  };
  pinned = synthetic.nixosConfigurations.${base.hostname}.config.systemd.services;
  normal = f.nixosConfigurations.${base.hostname}.config.systemd.services;
in {
  pinnedImport = pinned.zfs-import-data.script;
  pinnedLayout = pinned.data-pool-layout.script;
  normalImport = normal.zfs-import-data.script;
  normalLayout = normal.data-pool-layout.script;
}
')"

jq -e '
  (.pinnedImport | contains("import -d /dev/disk/by-id -N $ZFS_FORCE 12345678901234567890"))
  and (.pinnedLayout | contains("import -d /dev/disk/by-id -N $ZFS_FORCE 12345678901234567890"))
  and (.pinnedImport | contains("--expected-guid 12345678901234567890"))
  and (.pinnedLayout | contains("--expected-guid 12345678901234567890"))
  and (.normalImport | contains("import -d /dev/disk/by-id -N $ZFS_FORCE data"))
  and (.normalLayout | contains("import -d /dev/disk/by-id -N $ZFS_FORCE data"))
' <<<"$rendered_imports" >/dev/null || {
  echo "Rendered ZFS import scripts do not select a pinned GUID with a name fallback." >&2
  jq . <<<"$rendered_imports"
  exit 1
}

echo "✅ ZFS pool identity regression tests passed."
