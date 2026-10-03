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

# Cargo's glob handling must be matched exactly: a wildcard may sit in any
# segment (`crates/*/sub`), a pattern must not over-match into deeper nested
# packages (`crates/*` is not `crates/one/sub`), and an `exclude` pattern that
# matches nothing is legal — that is how a removed or archived path stays
# excluded. Only an unresolvable `members` pattern is an error.
write_crate() {
  local root="$1" member="$2"
  mkdir -p "$root/$member/src"
  printf '[package]\nname = "%s"\nversion = "0.1.0"\nedition = "2021"\n' "${member//\//-}" >"$root/$member/Cargo.toml"
  printf 'fn main() {}\n' >"$root/$member/src/main.rs"
}

write_workspace_root() {
  local root="$1"
  printf 'version = 4\n' >"$root/Cargo.lock"
}

active_members() {
  flake_eval_json "
    mk = import ./custom_apps/rust/lib/workspace-manifests.nix { inherit lib; };
    root = /. + (builtins.getEnv \"MANIFEST_FIXTURE\" + \"/$1\");
  in (mk { workspaceRoot = root; }).activeMembers
  "
}

nested="$test_root/nested"
mkdir -p "$nested"
cat >"$nested/Cargo.toml" <<'EOF'
[workspace]
resolver = "2"
members = ["crates/*/sub"]
exclude = ["crates/absent-*", "crates/never-built-dir", "vendor/*"]

[workspace.package]
version = "0.1.0"
edition = "2021"
EOF
write_workspace_root "$nested"
write_crate "$nested" crates/one/sub
write_crate "$nested" crates/two/sub
write_crate "$nested" crates/two/plain

jq -e 'sort == ["crates/one/sub", "crates/two/sub"]' <<<"$(active_members nested)" >/dev/null
echo '✅ A wildcard in any pattern segment resolves and non-matching excludes are legal.'

# A single-segment glob must not pick up a nested package below a matched member.
shallow="$test_root/shallow"
mkdir -p "$shallow"
cat >"$shallow/Cargo.toml" <<'EOF'
[workspace]
resolver = "2"
members = ["crates/*"]
EOF
write_workspace_root "$shallow"
write_crate "$shallow" crates/one
write_crate "$shallow" crates/one/sub

jq -e 'sort == ["crates/one"]' <<<"$(active_members shallow)" >/dev/null
echo '✅ A glob does not over-match into nested packages below a matched member.'

# Cargo applies `exclude` only to glob-expanded members: a path listed literally
# in `members` is always a member, even when an exclude entry points at it or at
# one of its ancestors.
literal="$test_root/literal-excluded"
mkdir -p "$literal"
cat >"$literal/Cargo.toml" <<'EOF'
[workspace]
resolver = "2"
members = ["crates/one", "crates/two"]
exclude = ["crates/one", "crates"]
EOF
write_workspace_root "$literal"
write_crate "$literal" crates/one
write_crate "$literal" crates/two

jq -e 'sort == ["crates/one", "crates/two"]' <<<"$(active_members literal-excluded)" >/dev/null
echo '✅ A literal member is never pruned by a matching exclude entry.'

# `exclude` entries are plain paths, not globs: a glob entry excludes nothing.
# This matches cargo, which compares exclude entries literally against a member.
glob_excluded="$test_root/glob-excluded"
mkdir -p "$glob_excluded"
cat >"$glob_excluded/Cargo.toml" <<'EOF'
[workspace]
resolver = "2"
members = ["crates/*"]
exclude = ["crates/*", "crates/**"]
EOF
write_workspace_root "$glob_excluded"
write_crate "$glob_excluded" crates/one
write_crate "$glob_excluded" crates/two

jq -e 'sort == ["crates/one", "crates/two"]' <<<"$(active_members glob-excluded)" >/dev/null
echo '✅ A glob entry in exclude excludes nothing, exactly as cargo does.'

# A plain exclude entry prunes a glob-expanded member at that path (with or
# without a trailing slash) or below it, while a deeper subpath of the member is
# not an exclusion of the member itself.
ancestor="$test_root/exclude-ancestor"
mkdir -p "$ancestor"
cat >"$ancestor/Cargo.toml" <<'EOF'
[workspace]
resolver = "2"
members = ["crates/*"]
exclude = ["crates/two/"]
EOF
write_workspace_root "$ancestor"
write_crate "$ancestor" crates/one
write_crate "$ancestor" crates/two

jq -e 'sort == ["crates/one"]' <<<"$(active_members exclude-ancestor)" >/dev/null

deeper="$test_root/exclude-deeper"
mkdir -p "$deeper"
cat >"$deeper/Cargo.toml" <<'EOF'
[workspace]
resolver = "2"
members = ["crates/*"]
exclude = ["crates/one/deeper"]
EOF
write_workspace_root "$deeper"
write_crate "$deeper" crates/one

jq -e 'sort == ["crates/one"]' <<<"$(active_members exclude-deeper)" >/dev/null

nested_excluded="$test_root/exclude-nested-member"
mkdir -p "$nested_excluded"
cat >"$nested_excluded/Cargo.toml" <<'EOF'
[workspace]
resolver = "2"
members = ["crates/*/sub"]
exclude = ["crates/two"]
EOF
write_workspace_root "$nested_excluded"
write_crate "$nested_excluded" crates/one/sub
write_crate "$nested_excluded" crates/two/sub

jq -e 'sort == ["crates/one/sub"]' <<<"$(active_members exclude-nested-member)" >/dev/null
echo '✅ An exclude prunes a glob member at or below its path, but not the member from a deeper subpath.'

# An exclude that matches nothing is legal (that is how a removed path stays
# excluded), and the workspace root itself can be excluded.
unmatched="$test_root/exclude-unmatched"
mkdir -p "$unmatched"
cat >"$unmatched/Cargo.toml" <<'EOF'
[workspace]
resolver = "2"
members = ["crates/*"]
exclude = ["archived/removed-app", "crates/never-built"]
EOF
write_workspace_root "$unmatched"
write_crate "$unmatched" crates/one
write_crate "$unmatched" crates/two

jq -e 'sort == ["crates/one", "crates/two"]' <<<"$(active_members exclude-unmatched)" >/dev/null

root_excluded="$test_root/exclude-root"
mkdir -p "$root_excluded"
cat >"$root_excluded/Cargo.toml" <<'EOF'
[workspace]
resolver = "2"
members = ["crates/*"]
exclude = ["."]
EOF
write_workspace_root "$root_excluded"
write_crate "$root_excluded" crates/one
write_crate "$root_excluded" crates/two

jq -e 'length == 0' <<<"$(active_members exclude-root)" >/dev/null
echo '✅ Unmatched excludes are legal and excluding the workspace root drops every member.'

# An unresolvable `members` pattern must still fail loudly, exactly as cargo does.
missing_members="$test_root/nested-missing-members"
mkdir -p "$missing_members"
cat >"$missing_members/Cargo.toml" <<'EOF'
[workspace]
resolver = "2"
members = ["crates/*"]
EOF
write_workspace_root "$missing_members"
eval_fails_with "resolved to no directory containing a Cargo.toml" "
  mk = import ./custom_apps/rust/lib/workspace-manifests.nix { inherit lib; };
  root = /. + (builtins.getEnv \"MANIFEST_FIXTURE\" + \"/nested-missing-members\");
in (mk { workspaceRoot = root; }).activeMembers
" >/dev/null
echo '✅ An unresolvable workspace member pattern still fails loudly.'

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