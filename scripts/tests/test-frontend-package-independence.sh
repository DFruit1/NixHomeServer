#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"
ensure_tools nix jq

test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT

# Evaluate the real package assembly against distinct frontend manifests.
# Stub build constructors so this tests ownership without fetching or building.
fixture="$test_root/custom_apps"
mkdir -p "$fixture/rust/apps"
cp "$TESTS_REPO_ROOT/custom_apps/Cargo.toml" "$fixture/Cargo.toml"
cp "$TESTS_REPO_ROOT/custom_apps/rust/apps/default.nix" "$fixture/rust/apps/default.nix"
for app in mail-archive-ui media-manager; do
  app_source="$TESTS_REPO_ROOT/custom_apps/rust/apps/$app"
  app_fixture="$fixture/rust/apps/$app"
  mkdir -p "$app_fixture/frontend"
  cp "$app_source/default.nix" "$app_fixture/default.nix"
  cp "$app_source/frontend/pnpm-lock.yaml" "$app_fixture/frontend/pnpm-lock.yaml"
  printf '\n# Independent lockfile for %s\n' "$app" >>"$app_fixture/frontend/pnpm-lock.yaml"
  jq --arg app "$app" '.scripts["ownership-test"] = $app' \
    "$app_source/frontend/package.json" >"$app_fixture/frontend/package.json"
done

cat >"$test_root/check.nix" <<'EOF'
let
  apps = import ./custom_apps/rust/apps {
    lib = { };
    pkgs = { };
    rustLib = {
      mkPnpmDeps = args: {
        inherit (args) hash;
        manifest = builtins.fromJSON (builtins.readFile (args.srcDir + "/package.json"));
      };
      mkPnpmFrontend = args: args;
      mkFrontendRuntime = args: args.frontendDist;
    };
  };
in
map (name: {
  inherit name;
  owner = apps.${name}.pnpmDeps.manifest.scripts.ownership-test;
  hash = apps.${name}.pnpmDeps.hash;
}) [ "mail-archive-ui" "media-manager" ]
EOF

result="$(nix eval --json --file "$test_root/check.nix")"
jq -e 'length == 2 and all(.[]; .owner == .name and (.hash | startswith("sha256-")))' \
  <<<"$result" >/dev/null
echo '✅ Frontend packages accept independent manifests and use their own dependency inputs.'
