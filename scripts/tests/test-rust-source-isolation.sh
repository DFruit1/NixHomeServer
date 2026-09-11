#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"
ensure_tools nix jq

test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT
export ISOLATION_FIXTURE="$test_root"
for variant in baseline sibling shared selected; do
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
done
printf '// sibling edit\n' >>"$test_root/sibling/rust/apps/second/src/main.rs"
printf '// shared edit\n' >>"$test_root/shared/rust/lib-rs/src/lib.rs"
printf '// selected edit\n' >>"$test_root/selected/rust/apps/first/src/main.rs"

result="$(flake_eval_json '
  pkgs = f.inputs.nixpkgs.legacyPackages.x86_64-linux;
  craneLib = f.inputs.crane.mkLib pkgs;
  mkSource = import ./custom_apps/rust/lib/mk-workspace-source.nix { inherit lib pkgs craneLib; };
  source = variant:
    let root = /. + (builtins.getEnv "ISOLATION_FIXTURE" + "/" + variant);
    in (mkSource {
      name = "first";
      workspaceRoot = root;
      cargoLock = root + "/Cargo.lock";
      workspaceManifests = lib.fileset.toSource {
        inherit root;
        fileset = craneLib.fileset.cargoTomlAndLock root;
      };
    }).drvPath;
in lib.genAttrs [ "baseline" "sibling" "shared" "selected" ] source
')"
jq -e '.baseline == .sibling and .baseline != .shared and .baseline != .selected' <<<"$result" >/dev/null
echo '✅ Rust package sources ignore sibling implementation edits and track owned/shared edits.'
