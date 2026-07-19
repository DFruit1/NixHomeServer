#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"
cd "$TESTS_REPO_ROOT"
ensure_tools bash cmp git mkdir mktemp rg rm

tmpdir="$(mktemp -d)"
cleanup() { rm -rf "$tmpdir"; }
trap cleanup EXIT

source_repo="$tmpdir/source"
target_parent="$tmpdir/targets"
helper="$TESTS_REPO_ROOT/scripts/admin/seed-install-repository.sh"
mkdir -p "$source_repo/secrets/unencrypted" "$target_parent"

git -C "$source_repo" init -q
git -C "$source_repo" config user.email test@example.test
git -C "$source_repo" config user.name "Install Seed Test"
git -C "$source_repo" remote add origin ssh://git@example.test/example/nixhomeserver.git

printf '%s\n' \
  '/.cache/' \
  '/secrets/unencrypted/' \
  '/SensitivePrivateSecrets' \
  >"$source_repo/.gitignore"
printf '{ description = "seed fixture"; }\n' >"$source_repo/flake.nix"
printf 'committed\n' >"$source_repo/config.txt"
printf 'remove me\n' >"$source_repo/deleted.txt"
git -C "$source_repo" add .gitignore flake.nix config.txt deleted.txt
git -C "$source_repo" commit -qm 'seed fixture'

# Preserve all forms of controlled tracked worktree state: unstaged edits,
# staged additions, and tracked deletions.
printf 'current tracked contents\n' >"$source_repo/config.txt"
printf 'staged tracked contents\n' >"$source_repo/staged.txt"
git -C "$source_repo" add staged.txt
rm "$source_repo/deleted.txt"

untracked_target="$target_parent/untracked-refusal"
printf 'not controlled\n' >"$source_repo/untracked.txt"
if NIXHOMESERVER_REPO_ROOT="$source_repo" \
  bash "$helper" --target "$untracked_target" >"$tmpdir/untracked.log" 2>&1; then
  echo "❌ Install repository seeding accepted an untracked, non-ignored file."
  exit 1
fi
if [[ -e "$untracked_target" ]] \
  || ! rg -Fq 'untracked, non-ignored files' "$tmpdir/untracked.log"; then
  echo "❌ Untracked-file refusal was not atomic or clearly diagnosed."
  cat "$tmpdir/untracked.log"
  exit 1
fi
rm "$source_repo/untracked.txt"

plaintext_target="$target_parent/plaintext-refusal"
printf 'do not copy\n' >"$source_repo/secrets/unencrypted/external-secret"
if NIXHOMESERVER_REPO_ROOT="$source_repo" \
  bash "$helper" --target "$plaintext_target" >"$tmpdir/plaintext.log" 2>&1; then
  echo "❌ Install repository seeding accepted ignored plaintext staging."
  exit 1
fi
if [[ -e "$plaintext_target" ]] \
  || ! rg -Fq 'remove all plaintext staging content' "$tmpdir/plaintext.log"; then
  echo "❌ Plaintext-staging refusal was not atomic or clearly diagnosed."
  cat "$tmpdir/plaintext.log"
  exit 1
fi
rm -f "$source_repo/secrets/unencrypted/external-secret"

legacy_target="$target_parent/legacy-plaintext-refusal"
mkdir "$source_repo/SensitivePrivateSecrets"
printf 'legacy plaintext\n' >"$source_repo/SensitivePrivateSecrets/secret"
if NIXHOMESERVER_REPO_ROOT="$source_repo" \
  bash "$helper" --target "$legacy_target" >"$tmpdir/legacy.log" 2>&1; then
  echo "❌ Install repository seeding accepted legacy ignored plaintext."
  exit 1
fi
if [[ -e "$legacy_target" ]] \
  || ! rg -Fq 'SensitivePrivateSecrets' "$tmpdir/legacy.log"; then
  echo "❌ Legacy-plaintext refusal was not atomic or clearly diagnosed."
  cat "$tmpdir/legacy.log"
  exit 1
fi
rm -rf "$source_repo/SensitivePrivateSecrets"

# Ignored non-secret caches are safe to leave in the source because the helper
# proves they cannot enter the controlled target.
mkdir -p "$source_repo/.cache"
printf 'ignored cache\n' >"$source_repo/.cache/cache-file"

success_target="$target_parent/installed-checkout"
NIXHOMESERVER_REPO_ROOT="$source_repo" \
  bash "$helper" --target "$success_target" >"$tmpdir/success.log"

[[ -d "$success_target/.git" ]] || {
  echo "❌ Seeded installation is not a Git checkout."
  exit 1
}
[[ "$(<"$success_target/config.txt")" == "current tracked contents" ]] || {
  echo "❌ Current tracked modifications were not preserved."
  exit 1
}
[[ "$(<"$success_target/staged.txt")" == "staged tracked contents" ]] || {
  echo "❌ Staged tracked additions were not preserved."
  exit 1
}
[[ ! -e "$success_target/deleted.txt" ]] || {
  echo "❌ A deleted tracked file reappeared in the seeded checkout."
  exit 1
}
[[ ! -e "$success_target/.cache" \
  && ! -e "$success_target/secrets/unencrypted" \
  && ! -e "$success_target/SensitivePrivateSecrets" ]] || {
  echo "❌ Ignored source content leaked into the seeded checkout."
  exit 1
}
[[ "$(git -C "$source_repo" rev-parse HEAD)" == "$(git -C "$success_target" rev-parse HEAD)" ]] || {
  echo "❌ Seeded checkout changed the source revision."
  exit 1
}
[[ "$(git -C "$success_target" remote get-url origin)" == 'ssh://git@example.test/example/nixhomeserver.git' ]] || {
  echo "❌ Seeded checkout did not preserve its configured Git remote."
  exit 1
}
git -C "$source_repo" status --porcelain=v1 -z --untracked-files=no >"$tmpdir/source-status"
git -C "$success_target" status --porcelain=v1 -z --untracked-files=no >"$tmpdir/target-status"
cmp -s "$tmpdir/source-status" "$tmpdir/target-status" || {
  echo "❌ Seeded checkout did not preserve tracked/index state."
  exit 1
}
if [[ -n "$(git -C "$success_target" ls-files --others --exclude-standard)" ]]; then
  echo "❌ Seeded checkout contains an unexpected untracked file."
  exit 1
fi

existing_target="$target_parent/existing"
mkdir "$existing_target"
printf 'keep me\n' >"$existing_target/marker"
if NIXHOMESERVER_REPO_ROOT="$source_repo" \
  bash "$helper" --target "$existing_target" >"$tmpdir/existing.log" 2>&1; then
  echo "❌ Install repository seeding merged into an existing target."
  exit 1
fi
[[ "$(<"$existing_target/marker")" == "keep me" ]] || {
  echo "❌ Existing-target refusal modified target contents."
  exit 1
}

for guide in README.md documentation/quickstart.md; do
  rg -Fq 'sudo -i' "$guide" || {
    echo "❌ $guide does not establish the installer root-shell boundary."
    exit 1
  }
  rg -Fq 'scripts/admin/seed-install-repository.sh --target /mnt/persist/etc/nixos' "$guide" || {
    echo "❌ $guide does not use the controlled installation seeding helper."
    exit 1
  }
  if rg -Fq 'cp -a /tmp/nixhomeserver/. /mnt/etc/nixos/' "$guide"; then
    echo "❌ $guide still documents an unrestricted repository copy."
    exit 1
  fi
done

echo "✅ Controlled installation repository seeding and refusal tests passed."
