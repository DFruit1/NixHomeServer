#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"

cd "$TESTS_REPO_ROOT"

ensure_tools bash jq nix rg

inventory_json="$(bash scripts/admin/export-inventory.sh --format json)"

require_json_equal "$(jq -r '.schemaVersion' <<<"$inventory_json")" "1" "Inventory schema version should be stable."
require_json_equal "$(jq -r '.host' <<<"$inventory_json")" "$(jq -r '.settings.hostname' <<<"$inventory_json")" "Inventory host should match settings.hostname."

jq -e '
  (.network.caddyHosts | type == "array" and length > 0)
  and (.identity.oauthClients | type == "array" and length > 0)
  and (.backups.appStateEntries | type == "array" and length > 0)
  and (.impermanence.directories | type == "array" and length > 0)
  and (.secrets.ageSecretNames | type == "array" and length > 0)
  and (.secrets.externalSecretNames | type == "array" and length > 0)
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

invalid_output="$(bash scripts/admin/export-inventory.sh --format yaml 2>&1 || true)"
if ! rg -Fq "blocked: --format must be json or text" <<<"$invalid_output"; then
  echo "❌ Inventory should reject invalid output formats."
  echo "$invalid_output"
  exit 1
fi

echo "✅ Export inventory tests passed."
