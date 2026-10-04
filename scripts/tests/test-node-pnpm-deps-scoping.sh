#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"
ensure_tools nix jq

# Node apps must key pnpmDeps on dependency manifests only, so editing
# application source does not invalidate the dependency fetch while a
# package.json or pnpm-lock.yaml edit still does. Proven against scratch copies
# of the real app trees; user source is never modified.
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT
export NODE_PNPM_DEPS_FIXTURE="$test_root"

apps=(groundwater-logger homepage youtube-downloader)
mkdir -p "$test_root/custom_apps/node/apps" "$test_root/custom_apps/rust"
cp -a "$TESTS_REPO_ROOT/custom_apps/rust/lib" "$test_root/custom_apps/rust/lib"
# The app derivations interpolate ../../shared into postPatch, so the scratch
# tree needs the same sibling layout as the real one.
cp -a "$TESTS_REPO_ROOT/custom_apps/node/shared" "$test_root/custom_apps/node/shared"
cp "$TESTS_REPO_ROOT/custom_apps/node/apps/default.nix" \
  "$test_root/custom_apps/node/apps/default.nix"
for app in "${apps[@]}"; do
  cp -a "$TESTS_REPO_ROOT/custom_apps/node/apps/$app" \
    "$test_root/custom_apps/node/apps/$app"
done

# The shared eval cache keys on the expression text, so each stage carries a
# distinct label or later stages would read the first stage's cached result.
deps_id() {
  local stage="$1"
  # The shared eval cache keys on the expression text, so the stage label is a
  # comment: later stages must not read the first stage's cached result. A
  # comment avoids the quoting that survives eval-cache round-trips.
  flake_eval_json "
    # stage: ${stage}
    pkgs = f.inputs.nixpkgs.legacyPackages.x86_64-linux;
    # builtins.path copies the scratch tree into the store so the app
    # derivations' relative imports (./<app>, ../../shared, ../../../rust/lib)
    # resolve inside the fixture.
    apps = import ((builtins.path {
      path = (builtins.getEnv \"NODE_PNPM_DEPS_FIXTURE\") + \"/custom_apps\";
      name = \"node-pnpm-deps-fixture\";
    }) + \"/node/apps\") { inherit pkgs lib; };
    in builtins.listToAttrs (map (name: {
      name = name;
      value = {
        drv = apps.\${name}.pnpmDeps.drvPath;
        src = toString apps.\${name}.pnpmDeps.src;
      };
    }) [ \"groundwater-logger\" \"homepage\" \"youtube-downloader\" ])
  "
}

baseline="$(deps_id baseline)"
printf '// application-only edit\n' >>"$test_root/custom_apps/node/apps/homepage/src/probe.ts"
app_edit="$(deps_id app-edit)"
for app in "${apps[@]}"; do
  manifest="$test_root/custom_apps/node/apps/$app/package.json"
  jq '.scripts.probe = "probe"' "$manifest" >"$manifest.probe"
  mv "$manifest.probe" "$manifest"
done
manifest_edit="$(deps_id manifest-edit)"
printf '\n# lockfile edit\n' >>"$test_root/custom_apps/node/apps/homepage/pnpm-lock.yaml"
lock_edit="$(deps_id lock-edit)"

for app in "${apps[@]}"; do
  jq -e --arg app "$app" \
    --argjson baseline "$baseline" --argjson edited "$app_edit" \
    '.[$app] == $baseline[$app]' <<<"$app_edit" >/dev/null \
    || {
      echo "❌ ${app}: an application-only edit changed the pnpm dependency inputs."
      exit 1
    }
  jq -e --arg app "$app" \
    --argjson baseline "$baseline" --argjson edited "$manifest_edit" \
    '.[$app] != $baseline[$app]' <<<"$manifest_edit" >/dev/null \
    || {
      echo "❌ ${app}: a package.json edit did not change the pnpm dependency inputs."
      exit 1
    }
done

jq -e \
  --argjson baseline "$baseline" --argjson edited "$lock_edit" \
  '.homepage != $baseline.homepage' <<<"$lock_edit" >/dev/null \
  || {
    echo "❌ homepage: a pnpm-lock.yaml edit did not change the pnpm dependency inputs."
    exit 1
  }

echo '✅ Node app pnpmDeps are keyed on dependency manifests only.'
