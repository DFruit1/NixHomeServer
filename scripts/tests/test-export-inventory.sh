#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"

cd "$TESTS_REPO_ROOT"

ensure_tools bash jq nix rg

inventory_json="$(bash scripts/admin/export-inventory.sh --format json)"

require_json_equal "$(jq -r '.schemaVersion' <<<"$inventory_json")" "2" "Inventory schema version should be stable."
require_json_equal "$(jq -r '.host' <<<"$inventory_json")" "$(jq -r '.settings.hostname' <<<"$inventory_json")" "Inventory host should match settings.hostname."

jq -e '
  (.network.caddyHosts | type == "array" and length > 0)
  and (.storage.profile == "zfs-mirror" or .storage.profile == "single-disk-ext4")
  and (if .storage.profile == "zfs-mirror" then
    (.storage.rootFsType == "btrfs")
    and (.storage.requiresZfs == true)
    and (.storage.dataRootIsMountPoint == true)
  else
    (.storage.rootFsType == "ext4")
    and (.storage.requiresZfs == false)
    and (.storage.dataRootIsMountPoint == false)
  end)
  and (.identity.oauthClients | type == "array" and length > 0)
  and (.backups.appStateEntries | type == "array" and length > 0)
  and (.backups.sqliteDumps | type == "array" and length > 0)
  and (.backups.postgresqlDumps | type == "array" and length > 0)
  and (.backups.appStateEntries[] | select(.app == "offline-media" and .component == "syncthing-enrollment").stateRoot == "/persist/appdata/offline-media")
  and (.backups | has("phoneBackup") | not)
  and (.backups.successfulCurrentPath == "/persist/appdata/backup-metadata/current")
  and (.backups.retainedSuccessfulGenerations >= 2)
  and (.impermanence.directories | type == "array" and length > 0)
  and (all(.impermanence.directories[]; (type == "string") and (. | startswith("/persist") | not)))
  and (.secrets.ageSecretNames | type == "array" and length > 0)
  and (.secrets.externalSecretNames | type == "array" and length > 0)
  and (.secrets.requiredExternalSecretNames | type == "array" and length > 0)
  and (.secrets.optionalExternalSecretNames == ["rcloneMegaPassword"])
  and (.secrets.requiredExternalSecretNames | index("rcloneMegaPassword") == null)
  and ((.secrets.requiredExternalSecretNames + .secrets.optionalExternalSecretNames | sort) == (.secrets.externalSecretNames | sort))
' <<<"$inventory_json" >/dev/null || {
  echo "❌ Inventory JSON is missing expected populated sections."
  jq . <<<"$inventory_json"
  exit 1
}

if rg -q 'BEGIN AGE ENCRYPTED FILE|secrets/unencrypted|secretValue' <<<"$inventory_json"; then
  echo "❌ Inventory JSON must expose secret names only, not secret values or cleartext paths."
  exit 1
fi

text_output="$(NIXHOMESERVER_INVENTORY_JSON="$inventory_json" bash scripts/admin/export-inventory.sh --format text)"
for section in Network Identity Storage Backups Impermanence Secrets Systemd; do
  if ! rg -Fq "$section" <<<"$text_output"; then
    echo "❌ Inventory text output should include section: $section"
    echo "$text_output"
    exit 1
  fi
done

if invalid_output="$(bash scripts/admin/export-inventory.sh --format yaml 2>&1)"; then
  echo "❌ Inventory returned success for an invalid output format."
  exit 1
fi
if ! rg -Fq "blocked: --format must be json or text" <<<"$invalid_output"; then
  echo "❌ Inventory should reject invalid output formats."
  echo "$invalid_output"
  exit 1
fi

echo "✅ Export inventory tests passed."
