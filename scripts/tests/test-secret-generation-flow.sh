#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"
cd "$TESTS_REPO_ROOT"
ensure_tools age age-keygen bash jq nix openssl sha256sum

tmpdir="$(mktemp -d)"
cleanup() { rm -rf "$tmpdir"; }
trap cleanup EXIT

test_repo="$tmpdir/repo"
mkdir -p "$test_repo/scripts/helpers" "$test_repo/secrets/unencrypted" "$test_repo/secrets/pubkeys"
cp scripts/generate-all-secrets.sh "$test_repo/scripts/generate-all-secrets.sh"
cp scripts/helpers/secrets-common.sh scripts/helpers/generate-managed-secrets.sh \
  scripts/helpers/encrypt-staged-external-secrets.sh "$test_repo/scripts/helpers/"
cp secrets/manifest.nix "$test_repo/secrets/manifest.nix"
touch "$test_repo/.gitignore"
make_test_executable \
  "$test_repo/scripts/generate-all-secrets.sh" \
  "$test_repo/scripts/helpers/"*.sh

old_identity="$tmpdir/old.age"
new_identity="$tmpdir/new.age"
age-keygen --output "$old_identity" >/dev/null
age-keygen --output "$new_identity" >/dev/null
age-keygen -y "$old_identity" >"$test_repo/secrets/pubkeys/age.pub"

stage_external_secrets() {
  printf '%s' 'abcdefghijklmnopqrstuvwxyz012345' >"$test_repo/secrets/unencrypted/netbirdSetupKey"
  printf '%s' '{"AccountTag":"test-account","TunnelID":"test-tunnel","TunnelSecret":"test-secret"}' >"$test_repo/secrets/unencrypted/cfHomeCreds"
  printf '%s' 'test_cloudflare_api_token_1234567890' >"$test_repo/secrets/unencrypted/cfAPIToken"
}

stage_external_secrets
printf 'legacy-mega-password' >"$tmpdir/legacy-mega-password"
age --encrypt --armor --recipient "$(age-keygen -y "$old_identity")" \
  --output "$test_repo/secrets/rcloneMegaPassword.age" "$tmpdir/legacy-mega-password"
NIXHOMESERVER_REPO_ROOT="$test_repo" bash "$test_repo/scripts/generate-all-secrets.sh" \
  --fresh --identity "$old_identity" >/dev/null

failing_nix_bin="$tmpdir/failing-nix-bin"
mkdir -p "$failing_nix_bin"
printf '#!/usr/bin/env bash\nexit 42\n' >"$failing_nix_bin/nix"
make_test_executable "$failing_nix_bin/nix"
manifest_failure_hashes_before="$(sha256sum "$test_repo"/secrets/*.age | sort -k2)"
if PATH="$failing_nix_bin:$PATH" NIXHOMESERVER_REPO_ROOT="$test_repo" \
  bash "$test_repo/scripts/generate-all-secrets.sh" --identity "$old_identity" \
  >"$tmpdir/manifest-evaluation-failure.log" 2>&1; then
  echo "❌ Secret generation reported success after manifest evaluation failed."
  exit 1
fi
if rg -Fq 'All required and staged secrets generated' "$tmpdir/manifest-evaluation-failure.log"; then
  echo "❌ Manifest evaluation failure printed a false success message."
  exit 1
fi
manifest_failure_hashes_after="$(sha256sum "$test_repo"/secrets/*.age | sort -k2)"
[[ "$manifest_failure_hashes_before" == "$manifest_failure_hashes_after" ]] || {
  echo "❌ Manifest evaluation failure changed encrypted secrets."
  exit 1
}

cp "$test_repo/secrets/cfHomeCreds.age" "$tmpdir/valid-cfHomeCreds.age"
printf '%s' '{"AccountTag":"","TunnelID":"bad","TunnelSecret":"bad"}' >"$tmpdir/invalid-cfHomeCreds"
rm -f "$test_repo/secrets/cfHomeCreds.age"
age --encrypt --armor --recipient "$(age-keygen -y "$old_identity")" \
  --output "$test_repo/secrets/cfHomeCreds.age" "$tmpdir/invalid-cfHomeCreds"
if NIXHOMESERVER_REPO_ROOT="$test_repo" bash "$test_repo/scripts/generate-all-secrets.sh" \
  --identity "$old_identity" >"$tmpdir/invalid-encrypted-external.log" 2>&1; then
  echo "❌ Verification accepted malformed encrypted Cloudflare credentials."
  exit 1
fi
if ! rg -Fq 'fails its manifest validator' "$tmpdir/invalid-encrypted-external.log"; then
  echo "❌ Malformed encrypted external-secret failure was not diagnosed."
  cat "$tmpdir/invalid-encrypted-external.log"
  exit 1
fi
cp -f "$tmpdir/valid-cfHomeCreds.age" "$test_repo/secrets/cfHomeCreds.age"

mapfile -t manifest_names < <(
  nix eval --json --file "$test_repo/secrets/manifest.nix" \
    | jq -r '(.generatedSecrets + (.externalSecrets | with_entries(select(.value.required != false)))) | keys[]'
)
for name in "${manifest_names[@]}"; do
  age --decrypt --identity "$old_identity" "$test_repo/secrets/${name}.age" >/dev/null
done
[[ -s "$test_repo/secrets/serverBootstrapSudoPassword.age" ]] || {
  echo "❌ Fresh generation omitted serverBootstrapSudoPassword."
  exit 1
}
[[ ! -e "$test_repo/secrets/rcloneMegaPassword.age" ]] || {
  echo "❌ Fresh generation created a disabled optional MEGA credential."
  exit 1
}

rm -rf "$test_repo/secrets/unencrypted"
before_rekey="$tmpdir/before-rekey"
mkdir -p "$before_rekey"
for name in "${manifest_names[@]}"; do
  age --decrypt --identity "$old_identity" --output "$before_rekey/$name" "$test_repo/secrets/${name}.age"
done

NIXHOMESERVER_REPO_ROOT="$test_repo" bash "$test_repo/scripts/generate-all-secrets.sh" \
  --identity "$old_identity" >/dev/null

age-keygen -y "$new_identity" >"$test_repo/secrets/pubkeys/age.pub"
if NIXHOMESERVER_REPO_ROOT="$test_repo" bash "$test_repo/scripts/generate-all-secrets.sh" \
  --identity "$new_identity" >"$tmpdir/wrong-recipient.log" 2>&1; then
  echo "❌ Verification accepted ciphertext encrypted to a different recipient."
  exit 1
fi
if ! rg -Fq 'cannot be decrypted' "$tmpdir/wrong-recipient.log"; then
  echo "❌ Wrong-recipient failure did not explain how to recover."
  cat "$tmpdir/wrong-recipient.log"
  exit 1
fi

symlink_secret="serverBootstrapSudoPassword"
mv "$test_repo/secrets/${symlink_secret}.age" "$tmpdir/${symlink_secret}.age"
printf '%s' 'outside-ciphertext-target' >"$tmpdir/outside-ciphertext-target"
ln -s "$tmpdir/outside-ciphertext-target" "$test_repo/secrets/${symlink_secret}.age"
if NIXHOMESERVER_REPO_ROOT="$test_repo" bash "$test_repo/scripts/generate-all-secrets.sh" \
  --rekey --source-identity "$old_identity" --identity "$new_identity" \
  >"$tmpdir/symlinked-rekey.log" 2>&1; then
  echo "❌ Rekey accepted a symlinked ciphertext target."
  exit 1
fi
[[ "$(<"$tmpdir/outside-ciphertext-target")" == 'outside-ciphertext-target' ]] || {
  echo "❌ Rekey followed a ciphertext symlink and modified an outside file."
  exit 1
}
rm -f "$test_repo/secrets/${symlink_secret}.age"
mv "$tmpdir/${symlink_secret}.age" "$test_repo/secrets/${symlink_secret}.age"

ciphertext_hashes_before_failure="$(sha256sum "$test_repo"/secrets/*.age | sort -k2)"
if NIXHOMESERVER_TEST_FAIL_REKEY_AFTER=2 \
  NIXHOMESERVER_REPO_ROOT="$test_repo" bash "$test_repo/scripts/generate-all-secrets.sh" \
  --rekey --source-identity "$old_identity" --identity "$new_identity" \
  >"$tmpdir/injected-rekey-failure.log" 2>&1; then
  echo "❌ Injected mid-publication rekey failure unexpectedly succeeded."
  exit 1
fi
ciphertext_hashes_after_failure="$(sha256sum "$test_repo"/secrets/*.age | sort -k2)"
[[ "$ciphertext_hashes_before_failure" == "$ciphertext_hashes_after_failure" ]] || {
  echo "❌ Failed rekey did not restore the original ciphertext set."
  exit 1
}
for name in "${manifest_names[@]}"; do
  age --decrypt --identity "$old_identity" "$test_repo/secrets/${name}.age" >/dev/null || {
    echo "❌ Failed rekey left $name unavailable to the original identity."
    exit 1
  }
done

NIXHOMESERVER_REPO_ROOT="$test_repo" bash "$test_repo/scripts/generate-all-secrets.sh" \
  --rekey --source-identity "$old_identity" --identity "$new_identity" >/dev/null

for name in "${manifest_names[@]}"; do
  after_file="$tmpdir/after-$name"
  age --decrypt --identity "$new_identity" --output "$after_file" "$test_repo/secrets/${name}.age"
  cmp "$before_rekey/$name" "$after_file" || {
    echo "❌ Rekey changed the cleartext value of $name."
    exit 1
  }
  if age --decrypt --identity "$old_identity" "$test_repo/secrets/${name}.age" >/dev/null 2>&1; then
    echo "❌ Rekeyed $name still decrypts with only the old identity."
    exit 1
  fi
done

managed_ciphertext_before="$(sha256sum "$test_repo/secrets/serverBootstrapSudoPassword.age")"
mkdir -p "$test_repo/secrets/unencrypted"
printf '%s' 'replacement_cloudflare_api_token_1234567890' >"$test_repo/secrets/unencrypted/cfAPIToken"
NIXHOMESERVER_REPO_ROOT="$test_repo" bash "$test_repo/scripts/generate-all-secrets.sh" \
  --replace-external cfAPIToken --identity "$new_identity" >/dev/null
replaced_cf_token="$(age --decrypt --identity "$new_identity" "$test_repo/secrets/cfAPIToken.age")"
[[ "$replaced_cf_token" == 'replacement_cloudflare_api_token_1234567890' ]] || {
  echo "❌ Targeted external-secret replacement did not publish the staged value."
  exit 1
}
managed_ciphertext_after="$(sha256sum "$test_repo/secrets/serverBootstrapSudoPassword.age")"
[[ "$managed_ciphertext_before" == "$managed_ciphertext_after" ]] || {
  echo "❌ Targeted external-secret replacement rotated an unrelated generated secret."
  exit 1
}

printf '%s' 'test-mega-password' >"$test_repo/secrets/unencrypted/rcloneMegaPassword"
NIXHOMESERVER_REPO_ROOT="$test_repo" bash "$test_repo/scripts/generate-all-secrets.sh" \
  --replace-external rcloneMegaPassword --identity "$new_identity" >/dev/null
replaced_mega_password="$(age --decrypt --identity "$new_identity" "$test_repo/secrets/rcloneMegaPassword.age")"
[[ "$replaced_mega_password" == 'test-mega-password' ]] || {
  echo "❌ Explicit optional MEGA-secret activation did not publish its staged value."
  exit 1
}

before_failed_fresh="$(sha256sum "$test_repo/secrets/serverBootstrapSudoPassword.age")"
if NIXHOMESERVER_REPO_ROOT="$test_repo" bash "$test_repo/scripts/generate-all-secrets.sh" \
  --fresh --identity "$new_identity" >"$tmpdir/missing-stage.log" 2>&1; then
  echo "❌ --fresh accepted missing staged external values."
  exit 1
fi
after_failed_fresh="$(sha256sum "$test_repo/secrets/serverBootstrapSudoPassword.age")"
[[ "$before_failed_fresh" == "$after_failed_fresh" ]] || {
  echo "❌ Failed --fresh preflight partially replaced generated secrets."
  exit 1
}

stage_external_secrets
all_hashes_before_injected_fresh="$(sha256sum "$test_repo"/secrets/*.age | sort -k2)"
if NIXHOMESERVER_TEST_FAIL_GENERATED_AFTER=2 \
  NIXHOMESERVER_REPO_ROOT="$test_repo" bash "$test_repo/scripts/generate-all-secrets.sh" \
  --fresh --identity "$new_identity" >"$tmpdir/injected-fresh-failure.log" 2>&1; then
  echo "❌ Injected mid-generation --fresh failure unexpectedly succeeded."
  exit 1
fi
all_hashes_after_injected_fresh="$(sha256sum "$test_repo"/secrets/*.age | sort -k2)"
[[ "$all_hashes_before_injected_fresh" == "$all_hashes_after_injected_fresh" ]] || {
  echo "❌ Failed --fresh did not restore the complete original ciphertext set."
  exit 1
}
[[ ! -e "$test_repo/secrets/unencrypted/serverBootstrapSudoPassword" ]] || {
  echo "❌ Failed --fresh left newly generated plaintext behind."
  exit 1
}

cf_temp_dir="$tmpdir/cloudflare-normalization-temp"
failing_age_bin="$tmpdir/failing-age-bin"
mkdir -p "$cf_temp_dir" "$failing_age_bin"
printf '#!/usr/bin/env bash\nexit 43\n' >"$failing_age_bin/age"
make_test_executable "$failing_age_bin/age"
if PATH="$failing_age_bin:$PATH" TMPDIR="$cf_temp_dir" \
  NIXHOMESERVER_REPO_ROOT="$test_repo" \
  NIXHOMESERVER_AGE_IDENTITY_FILE="$new_identity" \
  NIXHOMESERVER_SECRET_MODE=verify \
  NIXHOMESERVER_REPLACE_EXTERNAL_NAMES=cfAPIToken \
  bash "$test_repo/scripts/helpers/encrypt-staged-external-secrets.sh" \
  >"$tmpdir/injected-age-failure.log" 2>&1; then
  echo "❌ Injected age encryption failure unexpectedly succeeded."
  exit 1
fi
if find "$cf_temp_dir" -mindepth 1 -print -quit | rg -q .; then
  echo "❌ Failed Cloudflare token encryption leaked normalized plaintext in TMPDIR."
  exit 1
fi

echo "✅ Fresh generation, manifest failure propagation, atomic rollback, temp cleanup, recipient verification, and value-preserving rekey tests passed."
