#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"
ensure_tools nix jq

# The shared Cargo dependency build must track only the manifests Cargo reads to
# resolve workspace dependencies. Editing an unrelated project's Cargo.toml or
# Cargo.lock (the Tauri apps carry their own lockfiles) or any .rs file must not
# change the dependency source; editing a workspace member manifest, the root
# lockfile, or the build config must.

test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT
export MANIFEST_FIXTURE="$test_root"

build_fixture() {
  local variant="$1" root="$test_root/$variant"
  mkdir -p "$root/crates/one/src" "$root/crates/two/src" "$root/libs/shared/src" "$root/vendor/other/src-tauri/plugins/plugin"
  cat >"$root/Cargo.toml" <<'EOF'
[workspace]
resolver = "2"
members = ["crates/*", "libs/shared", "vendor/other"]

[workspace.package]
version = "0.1.0"
edition = "2021"
EOF
  printf 'version = 4\n' >"$root/Cargo.lock"
  printf 'edition = "2021"\n' >"$root/rustfmt.toml"
  for member in one two; do
    printf '[package]\nname = "%s"\nversion = "0.1.0"\nedition = "2021"\n' "$member" >"$root/crates/$member/Cargo.toml"
  done
  printf '[package]\nname = "shared"\nversion = "0.1.0"\nedition = "2021"\n' >"$root/libs/shared/Cargo.toml"
  printf 'fn main() {}\n' >"$root/crates/one/src/main.rs"
  printf 'fn main() {}\n' >"$root/crates/two/src/main.rs"
  printf 'pub fn shared() {}\n' >"$root/libs/shared/src/lib.rs"
  printf '[package]\nname = "other"\nversion = "0.1.0"\nedition = "2021"\n' >"$root/vendor/other/Cargo.toml"
  # A project outside the workspace with its own manifest and lockfile.
  cat >"$root/vendor/other/src-tauri/Cargo.toml" <<'EOF'
[package]
name = "other-tauri"
version = "0.1.0"
edition = "2021"

[dependencies]
serde = "1"
EOF
  printf 'version = 4\n' >"$root/vendor/other/src-tauri/Cargo.lock"
  cat >"$root/vendor/other/src-tauri/plugins/plugin/Cargo.toml" <<'EOF'
[package]
name = "plugin"
version = "0.1.0"
edition = "2021"
EOF
}

for variant in baseline unrelated-manifest unrelated-lock rust-only rustfmt member-manifest root-lock workspace-manifest; do
  build_fixture "$variant"
done

# Member discovery must see every glob-resolved member plus the local `path`
# dependency closure, and must not pull in the out-of-workspace manifests.
members="$(flake_eval_json '
  mk = import ./custom_apps/rust/lib/workspace-manifests.nix { inherit lib; };
  root = /. + (builtins.getEnv "MANIFEST_FIXTURE" + "/baseline");
in (mk { workspaceRoot = root; }).trackedPaths
')"
jq -e '
  (index("crates/one/Cargo.toml") != null)
  and (index("crates/two/Cargo.toml") != null)
  and (index("libs/shared/Cargo.toml") != null)
  and (index("vendor/other/Cargo.toml") != null)
  and (index("vendor/other/src-tauri/plugins/plugin/Cargo.toml") == null)
  and (index("Cargo.toml") != null)
  and (index("Cargo.lock") != null)
  and (index("rustfmt.toml") != null)
' <<<"$members" >/dev/null
echo '✅ Dependency manifests follow globbed members and exclude nested out-of-workspace manifests.'

# An out-of-workspace manifest/lockfile edit must not change the derivation, while
# a member manifest, the root lockfile and the workspace config must.
printf '# unrelated manifest edit\n' >>"$test_root/unrelated-manifest/vendor/other/src-tauri/Cargo.toml"
printf '# unrelated nested manifest edit\n' >>"$test_root/unrelated-manifest/vendor/other/src-tauri/plugins/plugin/Cargo.toml"
printf '# unrelated lock edit\n' >>"$test_root/unrelated-lock/vendor/other/src-tauri/Cargo.lock"
printf '// rust-only edit\n' >>"$test_root/rust-only/crates/one/src/main.rs"
printf 'style_edition = "2021"\n' >>"$test_root/rustfmt/rustfmt.toml"
printf '# member manifest edit\n' >>"$test_root/member-manifest/crates/one/Cargo.toml"
printf '# root lock edit\n' >>"$test_root/root-lock/Cargo.lock"
printf '# workspace manifest edit\n' >>"$test_root/workspace-manifest/Cargo.toml"

identity="$(flake_eval_json '
  mk = import ./custom_apps/rust/lib/workspace-manifests.nix { inherit lib; };
  source = variant:
    let root = /. + (builtins.getEnv "MANIFEST_FIXTURE" + "/" + variant);
    in toString (mk { workspaceRoot = root; }).source;
in lib.genAttrs [
  "baseline"
  "unrelated-manifest"
  "unrelated-lock"
  "rust-only"
  "rustfmt"
  "member-manifest"
  "root-lock"
  "workspace-manifest"
] source
')"

jq -e '
  .baseline == ."unrelated-manifest"
  and .baseline == ."unrelated-lock"
  and .baseline == ."rust-only"
  and .baseline != .rustfmt
  and .baseline != ."member-manifest"
  and .baseline != ."root-lock"
  and .baseline != ."workspace-manifest"
' <<<"$identity" >/dev/null
echo '✅ Shared dependency identity ignores unrelated manifests, locks and .rs edits but tracks member manifest, root lock and config edits.'

# The real workspace: membership must match Cargo.toml exactly, including
# groundwater-server, and must not reach the Tauri manifests.
real="$(flake_eval_json '
  mk = import ./custom_apps/rust/lib/workspace-manifests.nix { inherit lib; };
  result = mk { workspaceRoot = ./custom_apps; };
  files = builtins.filter (path: lib.hasInfix "node/" path) result.trackedPaths;
in {
  members = result.activeMembers;
  declared = (builtins.fromTOML (builtins.readFile ./custom_apps/Cargo.toml)).workspace.members;
  outsideWorkspace = files;
}
')"
jq -e '
  (.declared | sort) == (.members | sort)
  and (.members | index("rust/apps/groundwater-server") != null)
  and (.members | index("mkvmaker") != null)
  and .outsideWorkspace == []
' <<<"$real" >/dev/null
echo '✅ Real workspace dependency manifests match the declared workspace members exactly.'

# The assembled shared dependency derivation must take its source from that
# helper, i.e. the wiring in custom_apps/rust/apps/default.nix. Checking the
# derivation's own src input proves the helper is actually the source of truth
# rather than being dead code.
deps_source="$(flake_eval_json '
  pkgs = f.inputs.nixpkgs.legacyPackages.x86_64-linux;
  crane = f.inputs.crane;
  pd = import ./flake/packages.nix { inherit lib pkgs crane; };
  mk = import ./custom_apps/rust/lib/workspace-manifests.nix { inherit lib; };
  app = builtins.head (builtins.attrValues pd.rustApps);
in {
  manifests = (mk { workspaceRoot = ./custom_apps; }).source;
  appDrv = app.package.drvPath;
}
')"
deps_manifests="$(jq -r '.manifests' <<<"$deps_source")"
app_drv="$(jq -r '.appDrv' <<<"$deps_source")"
if [[ "$app_drv" != *.drv || -z "$deps_manifests" ]]; then
  echo "❌ Could not evaluate the shared Rust app derivations." >&2
  exit 1
fi

tracked="$(find "$deps_manifests" -type f | sed "s|$deps_manifests/||" | sort)"
if grep -q '^node/' <<<"$tracked"; then
  echo "❌ Shared dependency source still tracks out-of-workspace Tauri manifests:" >&2
  grep '^node/' <<<"$tracked" >&2
  exit 1
fi
for required in Cargo.toml Cargo.lock rustfmt.toml mkvmaker/Cargo.toml rust/apps/groundwater-server/Cargo.toml rust/lib-rs/Cargo.toml; do
  if ! grep -qx "$required" <<<"$tracked"; then
    echo "❌ Shared dependency source is missing ${required}." >&2
    exit 1
  fi
done

# The shared dependency derivation must itself be built from that manifest
# source. crane's buildDepsOnly runs mkDummySrc over `src`, so the derivation's
# dependency closure carries exactly one rewritten manifest per tracked manifest:
# the root plus one per workspace member. An out-of-workspace manifest showing
# up here means the whole tree is being swept again.
shared_deps_drv="$(nix-store --query --references "$app_drv" 2>/dev/null | grep 'nixhomeserver-rust-workspace-deps-deps.*\.drv$' | head -1)"
if [[ -z "$shared_deps_drv" ]]; then
  echo "❌ Could not locate the shared workspace dependency derivation." >&2
  exit 1
fi
shared_deps_src="$(nix-store --query --references "$shared_deps_drv" 2>/dev/null | grep -- '-source\.drv$' | head -1)"
if [[ -z "$shared_deps_src" ]]; then
  echo "❌ Shared dependency derivation has no dummy source." >&2
  exit 1
fi
expected_manifests="$(grep -c 'Cargo\.toml$' <<<"$tracked")"
actual_manifests="$(nix-store --query --references "$shared_deps_src" 2>/dev/null | grep -c -- '-Cargo\.toml\.drv$')"
if [[ "$actual_manifests" != "$expected_manifests" ]]; then
  echo "❌ Shared dependency dummy source carries ${actual_manifests} manifests, expected ${expected_manifests}." >&2
  exit 1
fi
echo '✅ Shared dependency derivation tracks workspace manifests only, excluding Tauri lockfiles.'