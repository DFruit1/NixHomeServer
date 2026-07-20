#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"
cd "$TESTS_REPO_ROOT"
ensure_tools age age-keygen bash cp jq mkdir mktemp nix rg

tmpdir="$(mktemp -d)"
cleanup() { rm -rf -- "$tmpdir"; }
trap cleanup EXIT

fixture="$tmpdir/pinned-source"
mkdir -p "$fixture/scripts/helpers" "$fixture/secrets/pubkeys"
cp scripts/helpers/secrets-common.sh "$fixture/scripts/helpers/secrets-common.sh"

cat >"$fixture/secrets/manifest.nix" <<'EOF'
{
  generatedSecrets.generatedOne.bytes = 16;
  externalSecrets.externalOne = {
    validator = "nonempty";
    required = true;
  };
}
EOF

identity="$tmpdir/identity.age"
age-keygen -o "$identity" >/dev/null 2>&1
recipient="$(age-keygen -y "$identity")"
printf '%s\n' "$recipient" >"$fixture/secrets/pubkeys/age.pub"

generated_clear="$tmpdir/generated.clear"
external_clear="$tmpdir/external.clear"
printf '%s\n' 'generated-value-that-must-stay-private' >"$generated_clear"
printf '%s\n' 'external-value-that-must-stay-private' >"$external_clear"
age --encrypt -r "$recipient" --output "$fixture/secrets/generatedOne.age" \
  "$generated_clear"
age --encrypt -r "$recipient" --output "$fixture/secrets/externalOne.age" \
  "$external_clear"

active_names='["generatedOne","externalOne"]'
output="$tmpdir/output"
bash scripts/helpers/verify-bootstrap-secrets.sh \
  --repo-root "$fixture" \
  --identity "$identity" \
  --active-secret-names-json "$active_names" >"$output" 2>&1
rg -Fq 'Verified 2 active encrypted bootstrap secrets' "$output"
if rg -Fq 'must-stay-private' "$output"; then
  echo "❌ Bootstrap secret preflight exposed decrypted plaintext."
  exit 1
fi

printf '%s\n' 'REPLACE_ME-invalid-external-value' >"$external_clear"
age --encrypt -r "$recipient" --output "$tmpdir/invalid-external.age" \
  "$external_clear"
mv -f "$tmpdir/invalid-external.age" "$fixture/secrets/externalOne.age"
if bash scripts/helpers/verify-bootstrap-secrets.sh \
  --repo-root "$fixture" \
  --identity "$identity" \
  --active-secret-names-json "$active_names" >"$output" 2>&1; then
  echo "❌ Bootstrap secret preflight accepted an external value rejected by its manifest validator."
  exit 1
fi
rg -Fq 'fails its pinned manifest validator' "$output"
if rg -Fq 'REPLACE_ME-invalid' "$output"; then
  echo "❌ Bootstrap secret validator failure exposed decrypted plaintext."
  exit 1
fi

printf '%s\n' 'not-an-age-ciphertext' >"$fixture/secrets/generatedOne.age"
if bash scripts/helpers/verify-bootstrap-secrets.sh \
  --repo-root "$fixture" \
  --identity "$identity" \
  --active-secret-names-json '["generatedOne"]' >"$output" 2>&1; then
  echo "❌ Bootstrap secret preflight accepted a corrupt active ciphertext."
  exit 1
fi
rg -Fq 'does not decrypt with the verified identity' "$output"

if bash scripts/helpers/verify-bootstrap-secrets.sh \
  --repo-root "$fixture" \
  --identity "$identity" \
  --active-secret-names-json '["missingOne"]' >"$output" 2>&1; then
  echo "❌ Bootstrap secret preflight accepted a missing active ciphertext."
  exit 1
fi
rg -Fq 'ciphertext is missing, empty, non-regular, or symlinked' "$output"

if bash scripts/helpers/verify-bootstrap-secrets.sh \
  --repo-root "$fixture" \
  --identity "$identity" \
  --active-secret-names-json '["generatedOne","generatedOne"]' >"$output" 2>&1; then
  echo "❌ Bootstrap secret preflight accepted a duplicated active-secret inventory."
  exit 1
fi
rg -Fq 'inventory is malformed or duplicated' "$output"

require_fixed bootstrap/apply-disko.sh \
  'active_secret_names_json="$(nix_json_for_host "$host" "builtins.attrNames cfg.age.secrets")"' \
  "Destructive bootstrap must derive its active secret inventory from the pinned host configuration."
require_fixed bootstrap/apply-disko.sh \
  'bash "$pinned_source_path/scripts/helpers/verify-bootstrap-secrets.sh"' \
  "Destructive bootstrap must validate ciphertexts using the immutable source before Disko."

echo "✅ Pinned bootstrap secret decryption and manifest-validation tests passed."
