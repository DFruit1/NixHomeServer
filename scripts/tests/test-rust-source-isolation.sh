#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"
ensure_tools nix jq

test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT
export ISOLATION_FIXTURE="$test_root"
for variant in baseline sibling shared selected tests frontend embedded; do
  root="$test_root/$variant"
  mkdir -p "$root/rust/apps/first/src" "$root/rust/apps/second/src" "$root/rust/lib-rs/src"
  cat >"$root/Cargo.toml" <<'EOF'
[workspace]
resolver = "2"
members = ["rust/apps/first", "rust/apps/second", "rust/lib-rs"]
EOF
  printf 'version = 4\n' >"$root/Cargo.lock"
  for member in first second; do
    printf '[package]\nname = "%s"\nversion = "0.1.0"\nedition = "2021"\n' "$member" >"$root/rust/apps/$member/Cargo.toml"
    printf 'fn main() {}\n' >"$root/rust/apps/$member/src/main.rs"
  done
  printf '[package]\nname = "common"\nversion = "0.1.0"\nedition = "2021"\n' >"$root/rust/lib-rs/Cargo.toml"
  printf 'pub fn common() {}\n' >"$root/rust/lib-rs/src/lib.rs"
  mkdir -p "$root/rust/apps/first/tests" "$root/rust/apps/first/frontend"
  printf '#[test] fn sample() {}\n' >"$root/rust/apps/first/tests/sample.rs"
  printf '<html>Frontend entry</html>\n' >"$root/rust/apps/first/frontend/index.html"
  printf '<html>Embedded backend UI</html>\n' >"$root/rust/apps/first/src/ui.html"
done
printf '// sibling edit\n' >>"$test_root/sibling/rust/apps/second/src/main.rs"
printf '// shared edit\n' >>"$test_root/shared/rust/lib-rs/src/lib.rs"
printf '// selected edit\n' >>"$test_root/selected/rust/apps/first/src/main.rs"

printf '// test-only edit\n' >>"$test_root/tests/rust/apps/first/tests/sample.rs"
printf '<!-- frontend-only edit -->\n' >>"$test_root/frontend/rust/apps/first/frontend/index.html"
printf '<!-- backend UI edit -->\n' >>"$test_root/embedded/rust/apps/first/src/ui.html"

result="$(flake_eval_json '
  pkgs = f.inputs.nixpkgs.legacyPackages.x86_64-linux;
  craneLib = f.inputs.crane.mkLib pkgs;
  mkSource = import ./custom_apps/rust/lib/mk-workspace-source.nix { inherit lib pkgs craneLib; };
  source = variant:
    let root = /. + (builtins.getEnv "ISOLATION_FIXTURE" + "/" + variant);
    in (mkSource {
      name = "first";
      extraSourcePrefixes = [ "src/ui.html" ];
      workspaceRoot = root;
      cargoLock = root + "/Cargo.lock";
      workspaceManifests = lib.fileset.toSource {
        inherit root;
        fileset = craneLib.fileset.cargoTomlAndLock root;
      };
    }).drvPath;
in lib.genAttrs [ "baseline" "sibling" "shared" "selected" "tests" "frontend" "embedded" ] source
')"
jq -e '.baseline == .sibling and .baseline == .tests and .baseline == .frontend and .baseline != .shared and .baseline != .selected and .baseline != .embedded' <<<"$result" >/dev/null
echo '✅ Rust production sources ignore tests/frontend/siblings and track owned/shared/embedded UI edits.'

checks="$(flake_eval_json '
  pkgs = f.inputs.nixpkgs.legacyPackages.x86_64-linux;
  craneLib = f.inputs.crane.mkLib pkgs;
  mkSource = import ./custom_apps/rust/lib/mk-workspace-source.nix { inherit lib pkgs craneLib; };
  source = variant:
    let root = /. + (builtins.getEnv "ISOLATION_FIXTURE" + "/" + variant);
    in (mkSource {
      name = "first";
      excludePrefixes = [ ];
      extraSourcePrefixes = [ "src/ui.html" ];
      workspaceRoot = root;
      cargoLock = root + "/Cargo.lock";
      workspaceManifests = lib.fileset.toSource {
        inherit root;
        fileset = craneLib.fileset.cargoTomlAndLock root;
      };
    }).drvPath;
in lib.genAttrs [ "baseline" "tests" "frontend" ] source
')"
jq -e '.baseline != .tests and .baseline == .frontend' <<<"$checks" >/dev/null
echo '✅ Rust check sources retain integration tests without frontend invalidation.'

# The app constructor must forward distinct production/check workspace sources
# to consumers; otherwise source filtering alone cannot prevent invalidation.
routing="$(flake_eval_json '
  mkApp = import ./custom_apps/rust/lib/mk-rust-app.nix {
    inherit lib;
    craneLib = { buildPackage = args: { src = toString args.src; }; };
    mkRustChecks = args: { source = toString args.checkSrc; };
    mkRustShell = args: { };
  };
  app = mkApp {
    name = "fixture";
    srcDir = ./custom_apps/rust/apps/media-manager;
    modulePath = ./modules/Core_Modules/media-manager;
    workspaceSrc = "/fixture/production";
    workspaceCheckSrc = "/fixture/validation";
    sharedCargoArtifacts = "/fixture/dependencies";
  };
in { production = app.package.src; validation = app.checks.source; }
')"
jq -e '.production == "/fixture/production" and .validation == "/fixture/validation"' <<<"$routing" >/dev/null
echo '✅ Rust app assembly routes production and validation to their respective sources.'
