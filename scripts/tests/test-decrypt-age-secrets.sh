#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"
cd "$TESTS_REPO_ROOT"
ensure_tools age age-keygen bash chmod mkdir mktemp stat

tmpdir="$(mktemp -d)"
cleanup() { rm -rf "$tmpdir"; }
trap cleanup EXIT

test_repo="$tmpdir/repository"
mkdir -p "$test_repo/scripts/admin" "$test_repo/secrets/pubkeys"
cp scripts/admin/decrypt-age-secrets.sh "$test_repo/scripts/admin/"
identity="$tmpdir/identity.age"
age-keygen --output "$identity" >/dev/null
recipient="$(age-keygen -y "$identity")"
printf '%s\n' "$recipient" >"$test_repo/secrets/pubkeys/age.pub"
printf 'first-secret' >"$tmpdir/first"
printf 'second-secret' >"$tmpdir/second"
age --encrypt --armor --recipient "$recipient" --output "$test_repo/secrets/first.age" "$tmpdir/first"
age --encrypt --armor --recipient "$recipient" --output "$test_repo/secrets/second.age" "$tmpdir/second"

repo_mode_before="$(stat -c %a "$test_repo")"
if (cd "$test_repo" && bash scripts/admin/decrypt-age-secrets.sh "$identity" .) \
  >"$tmpdir/inside-repo.log" 2>&1; then
  echo "❌ Decryption accepted an output directory inside the repository."
  exit 1
fi
[[ "$(stat -c %a "$test_repo")" == "$repo_mode_before" ]] || {
  echo "❌ Refused inside-repository output changed repository permissions."
  exit 1
}

output_dir="$tmpdir/output"
mkdir -m 0755 "$output_dir"
if bash "$test_repo/scripts/admin/decrypt-age-secrets.sh" "$identity" "$output_dir" \
  >"$tmpdir/open-output.log" 2>&1; then
  echo "❌ Decryption accepted an existing output directory readable by other users."
  exit 1
fi
[[ "$(stat -c %a "$output_dir")" == 755 ]] || {
  echo "❌ Refused existing output directory was silently chmodded."
  exit 1
}
chmod 0700 "$output_dir"

mkdir "$output_dir/first"
if bash "$test_repo/scripts/admin/decrypt-age-secrets.sh" --force "$identity" "$output_dir" \
  >"$tmpdir/directory-target.log" 2>&1; then
  echo "❌ --force accepted a directory as an exact plaintext target."
  exit 1
fi
[[ ! -e "$output_dir/first/first" ]] || {
  echo "❌ Plaintext was moved inside a pre-existing target directory."
  exit 1
}
rmdir "$output_dir/first"

bash "$test_repo/scripts/admin/decrypt-age-secrets.sh" "$identity" "$output_dir" >/dev/null
[[ "$(<"$output_dir/first")" == first-secret ]]
[[ "$(<"$output_dir/second")" == second-secret ]]
[[ "$(stat -c %a "$output_dir/first")" == 400 ]]

chmod 0600 "$output_dir/first" "$output_dir/second"
printf 'original-first' >"$output_dir/first"
printf 'original-second' >"$output_dir/second"
chmod 0400 "$output_dir/first" "$output_dir/second"
if NIXHOMESERVER_TEST_FAIL_DECRYPT_AFTER=1 \
  bash "$test_repo/scripts/admin/decrypt-age-secrets.sh" --force "$identity" "$output_dir" \
  >"$tmpdir/injected-publication.log" 2>&1; then
  echo "❌ Injected partial decryption publication unexpectedly succeeded."
  exit 1
fi
[[ "$(<"$output_dir/first")" == original-first ]]
[[ "$(<"$output_dir/second")" == original-second ]]
if find "$output_dir" -maxdepth 1 -type d -name '.decrypt-stage.*' -print -quit | grep -q .; then
  echo "❌ Failed decryption leaked a plaintext transaction directory."
  exit 1
fi

echo "✅ Age decryption path, permission, exact-target, and atomic rollback tests passed."
