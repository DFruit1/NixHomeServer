#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"
cd "$TESTS_REPO_ROOT"
ensure_tools age age-keygen cmp git jq mktemp nix openssl rg sed rm

helper="$TESTS_REPO_ROOT/scripts/admin/sync-upstream.sh"
tmpdir="$(mktemp -d)"
cleanup() { rm -rf "$tmpdir"; }
trap cleanup EXIT

upstream_repo="$tmpdir/upstream"
friend_repo="$tmpdir/friend"

# A minimal manifest matching the repository schema so the real generation
# helper runs inside the fixture repositories.
cat >"$tmpdir/manifest-base.nix" <<'EOF'
{
  generatedSecrets = {
    testSecret = {
      description = "Fixture generated secret.";
      bytes = 32;
    };
  };
  externalSecrets = {
    testExternal = {
      description = "Fixture required external secret.";
      format = "plain value";
      validator = "nonempty";
    };
  };
}
EOF

printf '%s\n' \
  '/secrets/*' \
  '!/secrets/*.age' \
  '!/secrets/manifest.nix' \
  '!/secrets/pubkeys/' \
  '!/secrets/pubkeys/age.pub' \
  '/secrets/unencrypted/' \
  '/SensitivePrivateSecrets' \
  >"$tmpdir/gitignore-base"

# Copy the helper scripts a synced repository needs so generation runs inside
# the fixture checkout exactly as it would in a real installation.
fixture_scripts=(
  scripts/admin/sync-upstream.sh
  scripts/generate-all-secrets.sh
  scripts/helpers/secrets-common.sh
  scripts/helpers/generate-managed-secrets.sh
  scripts/helpers/encrypt-staged-external-secrets.sh
)

mkdir -p "$upstream_repo/secrets/pubkeys"
git -C "$upstream_repo" init -q
git -C "$upstream_repo" config user.email upstream@example.test
git -C "$upstream_repo" config user.name "Upstream Fixture"

upstream_key="$tmpdir/upstream.age.key"
age-keygen -o "$upstream_key" >/dev/null 2>&1
age-keygen -y "$upstream_key" >"$tmpdir/upstream.pub"

cp "$tmpdir/gitignore-base" "$upstream_repo/.gitignore"
printf 'upstream vars v1\n' >"$upstream_repo/vars.nix"
printf 'upstream hw v1\n' >"$upstream_repo/hardware-configuration.nix"
printf '{"lock": "v1"}\n' >"$upstream_repo/flake.lock"
printf 'v1\n' >"$upstream_repo/code.txt"
cp "$tmpdir/manifest-base.nix" "$upstream_repo/secrets/manifest.nix"
cp "$tmpdir/upstream.pub" "$upstream_repo/secrets/pubkeys/age.pub"
printf 'generated-v1\n' >"$tmpdir/testSecret.clear"
age --encrypt --armor -r "$(<"$tmpdir/upstream.pub")" -o "$upstream_repo/secrets/testSecret.age" "$tmpdir/testSecret.clear"
printf 'external-value\n' >"$tmpdir/testExternal.clear"
age --encrypt --armor -r "$(<"$tmpdir/upstream.pub")" -o "$upstream_repo/secrets/testExternal.age" "$tmpdir/testExternal.clear"
git -C "$upstream_repo" add -A
git -C "$upstream_repo" commit -qm 'upstream base'

# The friend checkout personalizes every instance-owned file on top of the
# upstream base, exactly as the quickstart install flow produces.
git clone -q "$upstream_repo" "$friend_repo"
git -C "$friend_repo" config user.email friend@example.test
git -C "$friend_repo" config user.name "Friend Fixture"

friend_key="$tmpdir/friend.age.key"
age-keygen -o "$friend_key" >/dev/null 2>&1
age-keygen -y "$friend_key" >"$tmpdir/friend.pub"

printf 'friend vars v1\n' >"$friend_repo/vars.nix"
cp "$tmpdir/friend.pub" "$friend_repo/secrets/pubkeys/age.pub"
age --encrypt --armor -r "$(<"$tmpdir/friend.pub")" -o "$friend_repo/secrets/testSecret.age" "$tmpdir/testSecret.clear"
age --encrypt --armor -r "$(<"$tmpdir/friend.pub")" -o "$friend_repo/secrets/testExternal.age" "$tmpdir/testExternal.clear"
for fixture_script in "${fixture_scripts[@]}"; do
  mkdir -p "$friend_repo/$(dirname "$fixture_script")"
  cp "$TESTS_REPO_ROOT/$fixture_script" "$friend_repo/$fixture_script"
done
git -C "$friend_repo" add -A
git -C "$friend_repo" commit -qm 'personalize instance files'

run_sync() {
  local log="$1"
  shift
  NIXHOMESERVER_REPO_ROOT="$friend_repo" \
    NIXHOMESERVER_SYNC_SKIP_EVAL=1 \
    bash "$helper" --upstream "$upstream_repo" "$@" >"$log" 2>&1
}

# --- Scenario 1: upstream advances with instance-file changes and deletions,
# a new foreign generated secret, a lockfile update, and the first
# .gitattributes arrival. This checkout has no attributes yet, so the helper's
# own enforcement must restore the deleted instance file.
printf 'upstream vars v2\n' >"$upstream_repo/vars.nix"
printf '{"lock": "v2"}\n' >"$upstream_repo/flake.lock"
printf 'v2\n' >"$upstream_repo/code.txt"
git -C "$upstream_repo" rm -q hardware-configuration.nix
cat >"$upstream_repo/.gitattributes" <<'EOF'
vars.nix                    merge=ours -diff
hardware-configuration.nix  merge=ours -diff
secrets/*.age               merge=ours -diff
secrets/pubkeys/age.pub     merge=ours -diff
EOF
sed 's/testSecret = {/secondSecret = {\n      description = "Second fixture generated secret.";\n      bytes = 32;\n    };\n    testSecret = {/' \
  "$tmpdir/manifest-base.nix" >"$upstream_repo/secrets/manifest.nix"
printf 'second-generated-v1\n' >"$tmpdir/secondSecret.clear"
age --encrypt --armor -r "$(<"$tmpdir/upstream.pub")" -o "$upstream_repo/secrets/secondSecret.age" "$tmpdir/secondSecret.clear"
git -C "$upstream_repo" add -A
git -C "$upstream_repo" commit -qm 'upstream advance 1'
upstream_second_cipher="$(git -C "$upstream_repo" show HEAD:secrets/secondSecret.age)"
cp "$friend_repo/secrets/testSecret.age" "$tmpdir/testSecret.friend-before"

if ! run_sync "$tmpdir/sync1.log" --identity "$friend_key"; then
  echo "❌ First upstream sync failed."
  cat "$tmpdir/sync1.log"
  exit 1
fi

parent_count="$(git -C "$friend_repo" log --format=%P -n1 HEAD | wc -w)"
[[ "$parent_count" == "2" ]] || {
  echo "❌ Sync did not create a merge commit."
  exit 1
}
[[ "$(cat "$friend_repo/vars.nix")" == "friend vars v1" ]] || {
  echo "❌ Upstream overwrote the friend's vars.nix."
  exit 1
}
[[ "$(cat "$friend_repo/hardware-configuration.nix")" == "upstream hw v1" ]] || {
  echo "❌ The helper did not restore the silently deleted instance file."
  exit 1
}
cmp -s "$tmpdir/friend.pub" "$friend_repo/secrets/pubkeys/age.pub" || {
  echo "❌ Upstream overwrote the friend's age recipient key."
  exit 1
}
cmp -s "$tmpdir/testSecret.friend-before" "$friend_repo/secrets/testSecret.age" || {
  echo "❌ The friend's existing ciphertext was modified."
  exit 1
}
age --decrypt -i "$friend_key" -o "$tmpdir/secondSecret.roundtrip" "$friend_repo/secrets/secondSecret.age"
[[ "$(cat "$tmpdir/secondSecret.roundtrip")" != "second-generated-v1" ]] || {
  echo "❌ The regenerated secret reused the upstream plaintext instead of a new value."
  exit 1
}
friend_committed_cipher="$(git -C "$friend_repo" show HEAD:secrets/secondSecret.age)"
[[ "$friend_committed_cipher" != "$upstream_second_cipher" ]] || {
  echo "❌ The merge committed the upstream's undecryptable ciphertext."
  exit 1
}
[[ "$(cat "$friend_repo/flake.lock")" == '{"lock": "v2"}' ]] || {
  echo "❌ flake.lock did not follow upstream."
  exit 1
}
[[ "$(cat "$friend_repo/code.txt")" == "v2" ]] || {
  echo "❌ Ordinary repository code did not follow upstream."
  exit 1
}
[[ -z "$(git -C "$friend_repo" status --porcelain)" ]] || {
  echo "❌ Sync left a dirty worktree."
  git -C "$friend_repo" status --short
  exit 1
}
[[ "$(git -C "$friend_repo" check-attr merge -- vars.nix)" == "vars.nix: merge: ours" ]] || {
  echo "❌ The merged checkout did not activate the merge=ours attribute."
  exit 1
}
rg -Fq 'preserved instance file: vars.nix kept (upstream changed instance-owned contents)' "$tmpdir/sync1.log" || {
  echo "❌ The sync report did not flag the upstream vars.nix change."
  cat "$tmpdir/sync1.log"
  exit 1
}
rg -Fq 'preserved instance file: hardware-configuration.nix restored (upstream deleted or moved it)' "$tmpdir/sync1.log" || {
  echo "❌ The sync report did not flag the restored upstream deletion."
  cat "$tmpdir/sync1.log"
  exit 1
}
rg -Fq 'age key: secondSecret' "$tmpdir/sync1.log" || {
  echo "❌ The sync report did not flag the regenerated foreign secret."
  cat "$tmpdir/sync1.log"
  exit 1
}

# --- Scenario 2: rerunning with no upstream changes is a no-op.
head_before="$(git -C "$friend_repo" rev-parse HEAD)"
if ! run_sync "$tmpdir/sync2.log" --identity "$friend_key"; then
  echo "❌ Up-to-date sync rerun failed."
  cat "$tmpdir/sync2.log"
  exit 1
fi
rg -Fq 'Already up to date' "$tmpdir/sync2.log" || {
  echo "❌ Up-to-date rerun was not reported."
  cat "$tmpdir/sync2.log"
  exit 1
}
[[ "$(git -C "$friend_repo" rev-parse HEAD)" == "$head_before" ]] || {
  echo "❌ Up-to-date rerun created a commit."
  exit 1
}

# --- Scenario 3: a dirty worktree is refused.
printf 'dirt\n' >>"$friend_repo/code.txt"
head_before="$(git -C "$friend_repo" rev-parse HEAD)"
if run_sync "$tmpdir/sync3.log" --identity "$friend_key"; then
  echo "❌ Sync accepted a dirty worktree."
  exit 1
fi
rg -Fq 'worktree is not clean' "$tmpdir/sync3.log" || {
  echo "❌ Dirty-worktree refusal was not reported."
  cat "$tmpdir/sync3.log"
  exit 1
}
[[ "$(git -C "$friend_repo" rev-parse HEAD)" == "$head_before" ]] || {
  echo "❌ Refused sync changed HEAD."
  exit 1
}
git -C "$friend_repo" checkout -q -- code.txt

# --- Scenario 4: untracked files are refused with the file listed.
printf 'stray\n' >"$friend_repo/untracked.txt"
if run_sync "$tmpdir/sync4.log" --identity "$friend_key"; then
  echo "❌ Sync accepted an untracked file."
  exit 1
fi
rg -Fq 'worktree is not clean' "$tmpdir/sync4.log" || {
  echo "❌ Untracked-file refusal was not reported."
  cat "$tmpdir/sync4.log"
  exit 1
}
rg -Fq 'untracked.txt' "$tmpdir/sync4.log" || {
  echo "❌ Untracked-file refusal did not list the offending file."
  cat "$tmpdir/sync4.log"
  exit 1
}
rm "$friend_repo/untracked.txt"

# --- Scenario 5: with the merge=ours attributes now active, an upstream
# deletion of an instance file becomes a modify/delete conflict that the
# helper resolves to the local contents.
git -C "$upstream_repo" rm -q vars.nix
git -C "$upstream_repo" commit -qm 'upstream removes vars.nix'
if ! run_sync "$tmpdir/sync5.log"; then
  echo "❌ Deletion-restoring sync failed."
  cat "$tmpdir/sync5.log"
  exit 1
fi
[[ "$(cat "$friend_repo/vars.nix")" == "friend vars v1" ]] || {
  echo "❌ Upstream deletion removed the friend's vars.nix."
  exit 1
}
rg -Fq 'preserved instance file: vars.nix kept (upstream changed instance-owned contents)' "$tmpdir/sync5.log" || {
  echo "❌ The sync report did not flag the refused deletion."
  cat "$tmpdir/sync5.log"
  exit 1
}

# --- Scenario 6: upstream rotates its age key and adds another generated
# secret. Without an identity the sync refuses before touching anything; with
# the friend identity it succeeds and restores the recipient key.
age-keygen -o "$tmpdir/rotated.age.key" >/dev/null 2>&1
age-keygen -y "$tmpdir/rotated.age.key" >"$upstream_repo/secrets/pubkeys/age.pub"
sed 's/testSecret = {/thirdSecret = {\n      description = "Third fixture generated secret.";\n      bytes = 32;\n    };\n    testSecret = {/' \
  "$upstream_repo/secrets/manifest.nix" >"$upstream_repo/secrets/manifest.new"
mv "$upstream_repo/secrets/manifest.new" "$upstream_repo/secrets/manifest.nix"
printf 'third-generated-v1\n' >"$tmpdir/thirdSecret.clear"
age --encrypt --armor -r "$(age-keygen -y "$tmpdir/rotated.age.key")" \
  -o "$upstream_repo/secrets/thirdSecret.age" "$tmpdir/thirdSecret.clear"
git -C "$upstream_repo" add -A
git -C "$upstream_repo" commit -qm 'upstream rotates key and adds thirdSecret'

head_before="$(git -C "$friend_repo" rev-parse HEAD)"
if run_sync "$tmpdir/sync6a.log"; then
  echo "❌ Sync accepted a secrets-touching merge without an age identity."
  exit 1
fi
rg -q 'private age identity' "$tmpdir/sync6a.log" || {
  echo "❌ Missing-identity refusal was not reported."
  cat "$tmpdir/sync6a.log"
  exit 1
}
[[ "$(git -C "$friend_repo" rev-parse HEAD)" == "$head_before" ]] || {
  echo "❌ Refused sync changed HEAD."
  exit 1
}
[[ ! -e "$friend_repo/.git/MERGE_HEAD" ]] || {
  echo "❌ Refused sync left a merge in progress."
  exit 1
}

if ! run_sync "$tmpdir/sync6b.log" --identity "$friend_key"; then
  echo "❌ Identity-supplied sync failed."
  cat "$tmpdir/sync6b.log"
  exit 1
fi
cmp -s "$tmpdir/friend.pub" "$friend_repo/secrets/pubkeys/age.pub" || {
  echo "❌ Upstream key rotation replaced the friend's recipient key."
  exit 1
}
age --decrypt -i "$friend_key" -o "$tmpdir/thirdSecret.roundtrip" "$friend_repo/secrets/thirdSecret.age"
[[ "$(cat "$tmpdir/thirdSecret.roundtrip")" != "third-generated-v1" ]] || {
  echo "❌ thirdSecret reused the upstream plaintext."
  exit 1
}
rg -Fq 'age key: thirdSecret' "$tmpdir/sync6b.log" || {
  echo "❌ The report did not flag the regenerated thirdSecret."
  cat "$tmpdir/sync6b.log"
  exit 1
}
rg -Fq 'preserved instance file: secrets/pubkeys/age.pub kept (upstream changed instance-owned contents)' "$tmpdir/sync6b.log" || {
  echo "❌ The report did not flag the upstream key rotation."
  cat "$tmpdir/sync6b.log"
  exit 1
}

# --- Scenario 7: a new required external secret blocks until its value is
# staged, then the staged plaintext is encrypted and removed.
sed 's/externalSecrets = {/externalSecrets = {\n    stagedThing = {\n      description = "Fixture newly required external secret.";\n      format = "plain value";\n      validator = "nonempty";\n    };/' \
  "$upstream_repo/secrets/manifest.nix" >"$upstream_repo/secrets/manifest.new"
mv "$upstream_repo/secrets/manifest.new" "$upstream_repo/secrets/manifest.nix"
printf 'staged-foreign\n' >"$tmpdir/stagedThing.clear"
age --encrypt --armor -r "$(age-keygen -y "$tmpdir/rotated.age.key")" \
  -o "$upstream_repo/secrets/stagedThing.age" "$tmpdir/stagedThing.clear"
git -C "$upstream_repo" add -A
git -C "$upstream_repo" commit -qm 'upstream adds required external secret'

head_before="$(git -C "$friend_repo" rev-parse HEAD)"
if run_sync "$tmpdir/sync7a.log" --identity "$friend_key"; then
  echo "❌ Sync merged a new external secret without a staged value."
  exit 1
fi
rg -q 'without a staged value' "$tmpdir/sync7a.log" || {
  echo "❌ Missing-staged-value refusal was not reported."
  cat "$tmpdir/sync7a.log"
  exit 1
}
rg -q 'stagedThing' "$tmpdir/sync7a.log" || {
  echo "❌ Missing-staged-value refusal did not name the secret."
  cat "$tmpdir/sync7a.log"
  exit 1
}
[[ "$(git -C "$friend_repo" rev-parse HEAD)" == "$head_before" ]] || {
  echo "❌ Refused sync changed HEAD."
  exit 1
}
[[ -z "$(git -C "$friend_repo" status --porcelain)" ]] || {
  echo "❌ Refused sync left a dirty worktree."
  exit 1
}

install -d -m 0700 "$friend_repo/secrets/unencrypted"
printf 'staged-value\n' >"$friend_repo/secrets/unencrypted/stagedThing"
if ! run_sync "$tmpdir/sync7b.log" --identity "$friend_key"; then
  echo "❌ Staged-value sync failed."
  cat "$tmpdir/sync7b.log"
  exit 1
fi
age --decrypt -i "$friend_key" -o "$tmpdir/stagedThing.roundtrip" "$friend_repo/secrets/stagedThing.age"
[[ "$(cat "$tmpdir/stagedThing.roundtrip")" == "staged-value" ]] || {
  echo "❌ The staged external value was not encrypted faithfully."
  exit 1
}
[[ ! -e "$friend_repo/secrets/unencrypted/stagedThing" ]] || {
  echo "❌ The sync left staged plaintext behind, which would fail deploy readiness."
  exit 1
}

# --- Scenario 8: a conflict in ordinary repository code is refused instead of
# silently resolved, and proceeds once the change is ported manually.
printf 'friend code\n' >"$friend_repo/code.txt"
git -C "$friend_repo" commit -qam 'friend edits code'
printf 'v3\n' >"$upstream_repo/code.txt"
git -C "$upstream_repo" commit -qam 'upstream edits code'

head_before="$(git -C "$friend_repo" rev-parse HEAD)"
if run_sync "$tmpdir/sync8a.log"; then
  echo "❌ Sync silently resolved an unexpected code conflict."
  exit 1
fi
rg -q 'does not resolve' "$tmpdir/sync8a.log" || {
  echo "❌ Unexpected-conflict refusal was not reported."
  cat "$tmpdir/sync8a.log"
  exit 1
}
rg -Fq 'code.txt' "$tmpdir/sync8a.log" || {
  echo "❌ Unexpected-conflict refusal did not name the path."
  cat "$tmpdir/sync8a.log"
  exit 1
}
[[ "$(git -C "$friend_repo" rev-parse HEAD)" == "$head_before" ]] || {
  echo "❌ Refused sync changed HEAD."
  exit 1
}
[[ ! -e "$friend_repo/.git/MERGE_HEAD" ]] || {
  echo "❌ Refused sync left a merge in progress."
  exit 1
}

git -C "$upstream_repo" show HEAD:code.txt >"$friend_repo/code.txt"
git -C "$friend_repo" commit -qam 'accept upstream code change'
if ! run_sync "$tmpdir/sync8b.log"; then
  echo "❌ Post-port sync failed."
  cat "$tmpdir/sync8b.log"
  exit 1
fi
[[ "$(cat "$friend_repo/code.txt")" == "v3" ]] || {
  echo "❌ Manually ported code change was not preserved through the merge."
  exit 1
}
[[ -z "$(git -C "$friend_repo" status --porcelain)" ]] || {
  echo "❌ Final worktree is not clean."
  git -C "$friend_repo" status --short
  exit 1
}

# --- Scenario 9: upstream additions that look like instance-file renames or
# structural root-level changes are refused before anything is merged.
printf 'structural\n' >"$upstream_repo/newtop.nix"
git -C "$upstream_repo" add newtop.nix
git -C "$upstream_repo" commit -qm 'upstream adds root nix file'

head_before="$(git -C "$friend_repo" rev-parse HEAD)"
if run_sync "$tmpdir/sync9a.log"; then
  echo "❌ Sync merged an upstream instance-file topology change."
  exit 1
fi
rg -q 'cannot be merged automatically' "$tmpdir/sync9a.log" || {
  echo "❌ Topology-guard refusal was not reported."
  cat "$tmpdir/sync9a.log"
  exit 1
}
rg -Fq 'newtop.nix' "$tmpdir/sync9a.log" || {
  echo "❌ Topology-guard refusal did not name the path."
  cat "$tmpdir/sync9a.log"
  exit 1
}
[[ "$(git -C "$friend_repo" rev-parse HEAD)" == "$head_before" ]] || {
  echo "❌ Topology-guard refusal changed HEAD."
  exit 1
}
[[ ! -e "$friend_repo/.git/MERGE_HEAD" ]] || {
  echo "❌ Topology-guard refusal left a merge in progress."
  exit 1
}

git -C "$upstream_repo" rm -q newtop.nix
git -C "$upstream_repo" commit -qm 'upstream removes experimental root file'
if ! run_sync "$tmpdir/sync9b.log"; then
  echo "❌ Sync after upstream reverted the structural file failed."
  cat "$tmpdir/sync9b.log"
  exit 1
fi
[[ ! -e "$friend_repo/newtop.nix" ]] || {
  echo "❌ The experimental root file leaked into the friend checkout."
  exit 1
}

# --- Scenario 10: --push backs up the merged branch to the private fork, and
# is refused when origin is the upstream repository itself.
head_before="$(git -C "$friend_repo" rev-parse HEAD)"
if run_sync "$tmpdir/sync10a.log" --push; then
  echo "❌ Sync pushed to origin while origin was the upstream repository."
  exit 1
fi
rg -q 'would publish this installation.s private files to the upstream' "$tmpdir/sync10a.log" || {
  echo "❌ The origin-is-upstream push refusal was not reported."
  cat "$tmpdir/sync10a.log"
  exit 1
}
[[ "$(git -C "$friend_repo" rev-parse HEAD)" == "$head_before" ]] || {
  echo "❌ Push-refusal sync changed HEAD."
  exit 1
}

git init -q --bare "$tmpdir/origin.git"
git -C "$friend_repo" remote set-url origin "$tmpdir/origin.git"
printf 'v4\n' >"$upstream_repo/code.txt"
git -C "$upstream_repo" commit -qam 'upstream edits code again'
friend_branch="$(git -C "$friend_repo" symbolic-ref --short HEAD)"
if ! run_sync "$tmpdir/sync10b.log" --push; then
  echo "❌ Sync with --push against a private origin failed."
  cat "$tmpdir/sync10b.log"
  exit 1
fi
rg -Fq "pushed $friend_branch to origin" "$tmpdir/sync10b.log" || {
  echo "❌ The sync report did not confirm the push."
  cat "$tmpdir/sync10b.log"
  exit 1
}
[[ "$(git -C "$tmpdir/origin.git" rev-parse "$friend_branch")" == "$(git -C "$friend_repo" rev-parse HEAD)" ]] || {
  echo "❌ The merged branch was not pushed to the private fork."
  exit 1
}

# The helper must keep advertising its policy surface so the documented
# workflow cannot silently drift from the implemented behavior.
require_fixed scripts/admin/sync-upstream.sh 'secrets/*.age' \
  'the sync helper protects instance ciphertext'
require_fixed scripts/admin/sync-upstream.sh 'generate-all-secrets.sh" --identity' \
  'the sync helper repairs foreign ciphertext with the real generation helper'
require_fixed scripts/admin/sync-upstream.sh 'deploy.sh --action test' \
  'the sync helper routes the operator to the guarded deploy path'
require_fixed scripts/admin/sync-upstream.sh 'cannot be merged automatically' \
  'the sync helper refuses upstream instance-file renames and structural root additions'
require_fixed scripts/admin/sync-upstream.sh "--push would publish this installation's private files" \
  'the sync helper refuses pushing private files to the upstream repository'
rg -Fq 'scripts/admin/sync-upstream.sh' documentation/operations.md || {
  echo "❌ operations.md does not document the upstream sync helper."
  exit 1
}

echo "✅ Upstream sync preservation and refusal tests passed."
