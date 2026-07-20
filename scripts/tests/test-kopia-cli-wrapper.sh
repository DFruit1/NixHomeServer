#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"
cd "$TESTS_REPO_ROOT"
ensure_tools jq nix rg

source scripts/helpers/kopia-managed-common.sh
recovery_test_root="$(mktemp -d)"
cleanup() { rm -rf "$recovery_test_root"; }
trap cleanup EXIT
chmod 0700 "$recovery_test_root"
test_owner="$(id -u)"
valid_config="$recovery_test_root/repository.config"
if ! kopia_managed_validate_recovery_config_path "$valid_config" "$recovery_test_root" "$test_owner"; then
  echo "Kopia recovery path validator rejected a secure direct config path." >&2
  exit 1
fi
mkdir "$recovery_test_root/nested"
ln -s /etc/passwd "$recovery_test_root/symlink.config"
for invalid_config in \
  "$recovery_test_root/../../persist/appdata/kopia/repository.config" \
  "$recovery_test_root/nested/repository.config" \
  "$recovery_test_root/symlink.config" \
  "$recovery_test_root/.config"; do
  if kopia_managed_validate_recovery_config_path "$invalid_config" "$recovery_test_root" "$test_owner"; then
    echo "Kopia recovery path validator accepted an unsafe path: $invalid_config" >&2
    exit 1
  fi
done
printf '{}\n' >"$valid_config"
chmod 0600 "$valid_config"
if ! kopia_managed_validate_recovery_config_path "$valid_config" "$recovery_test_root" "$test_owner"; then
  echo "Kopia recovery path validator rejected a private existing config." >&2
  exit 1
fi
chmod 0644 "$valid_config"
if kopia_managed_validate_recovery_config_path "$valid_config" "$recovery_test_root" "$test_owner"; then
  echo "Kopia recovery path validator accepted a group/world-readable config." >&2
  exit 1
fi
chmod 0600 "$valid_config"
chmod 0755 "$recovery_test_root"
if kopia_managed_validate_recovery_config_path "$valid_config" "$recovery_test_root" "$test_owner"; then
  echo "Kopia recovery path validator accepted a non-private recovery directory." >&2
  exit 1
fi
chmod 0700 "$recovery_test_root"

wrapper_json="$(nix eval --json '.#nixosConfigurations.server.config.security.wrappers.nixhomeserver-kopia' \
  --apply 'wrapper: {
    source = toString wrapper.source;
    inherit (wrapper) owner group permissions;
    setuid = wrapper.setuid or false;
  }')"

jq -e '
  .owner == "root"
  and .group == "root"
  and .permissions == "0500"
  and (.setuid | not)
  and (.source | contains("nixhomeserver-kopia"))
' <<<"$wrapper_json" >/dev/null || {
  echo "Managed Kopia CLI is not installed as a non-setuid root-only wrapper." >&2
  jq . <<<"$wrapper_json"
  exit 1
}

wrapper_path="$(nix build --impure --no-link --print-out-paths --expr '
let
  f = builtins.getFlake (builtins.getEnv "NIXHOMESERVER_FLAKE_REF_FOR_EVAL");
  host = builtins.head (builtins.attrNames f.nixosConfigurations);
in (builtins.getAttr host f.nixosConfigurations).config.security.wrappers.nixhomeserver-kopia.source
')"

rg -q 'EUID != 0' "$wrapper_path"
rg -Fq 'KOPIA_PASSWORD="$(tr -d '\''\r\n'\'' < "$secret_file")"' "$wrapper_path"
rg -Fq 'KOPIA_CONFIG_PATH="$config_file"' "$wrapper_path"
rg -Fq 'KOPIA_CACHE_DIRECTORY="$cache_dir"' "$wrapper_path"
if rg -q -- '--password=' "$wrapper_path"; then
  echo "Managed Kopia CLI exposes its repository password in argv." >&2
  exit 1
fi

health_json="$(nix eval --json '.#nixosConfigurations.server.config' --apply 'cfg: {
  bootstrapScript = cfg.systemd.services.kopia-repository-bootstrap.script;
  service = {
    requires = cfg.systemd.services.kopia-snapshot-health.requires;
    after = cfg.systemd.services.kopia-snapshot-health.after;
    condition = cfg.systemd.services.kopia-snapshot-health.unitConfig.ConditionPathIsMountPoint or null;
    script = cfg.systemd.services.kopia-snapshot-health.script;
  };
  timer = cfg.systemd.timers.kopia-snapshot-health.timerConfig;
  snapshotScript = cfg.systemd.services.kopia-persist-snapshot.script;
}')"

jq -e '
  (.bootstrapScript | contains("export KOPIA_PASSWORD=\"$password\""))
  and (.bootstrapScript | contains("--password=") | not)
  and (.service.requires | index("data-pool-layout.service") != null)
  and (.service.requires | index("kopia-repository-bootstrap.service") != null)
  and (.service.after | index("kopia-persist-snapshot.service") != null)
  and (.service.condition == "/mnt/data")
  and (.service.script | contains("state=initializing"))
  and (.service.script | contains("check-freshness-marker"))
  and (.service.script | contains("invalid, stale, or future-dated"))
  and (.snapshotScript | contains("mktemp /mnt/data/backups/.kopia-last-snapshot-success.json.XXXXXX"))
  and (.snapshotScript | contains("mv -f \"$snapshot_marker_tmp\" /mnt/data/backups/.kopia-last-snapshot-success.json"))
  and (.timer.OnUnitActiveSec == "1h")
  and (.timer.Persistent == true)
' <<<"$health_json" >/dev/null || {
  echo "Kopia snapshot freshness monitoring regressed." >&2
  jq . <<<"$health_json"
  exit 1
}

echo "✅ Root-only managed Kopia CLI wrapper regression tests passed."
