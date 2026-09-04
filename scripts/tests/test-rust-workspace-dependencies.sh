#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"
cd "$TESTS_REPO_ROOT"
ensure_tools cargo jq rg

workspace_manifest="custom_apps/Cargo.toml"
nix_workspace="custom_apps/rust/apps/default.nix"
member_manifests=(
  custom_apps/rust/apps/browsertrix-downloader/Cargo.toml
  custom_apps/rust/apps/kanidm-canary-bootstrap/Cargo.toml
  custom_apps/rust/apps/mail-archive-ui/Cargo.toml
  custom_apps/rust/apps/media-manager/Cargo.toml
)

require_fixed "$workspace_manifest" \
  '[workspace.dependencies]' \
  "Rust dependency versions must have one workspace-owned source of truth."
require_fixed "$workspace_manifest" \
  'edition = "2021"' \
  "The Rust edition must be declared once in workspace package metadata."

for manifest in "${member_manifests[@]}"; do
  require_fixed "$manifest" \
    'version.workspace = true' \
    "Rust packages must inherit the workspace package version."
  require_fixed "$manifest" \
    'edition.workspace = true' \
    "Rust packages must inherit the workspace edition."
  forbid_match "$manifest" \
    '^[[:space:]]*[[:alnum:]_-]+[[:space:]]*=[[:space:]]*"[0-9]' \
    "Rust member manifests must not declare local package or dependency versions."
  forbid_match "$manifest" \
    '^[[:space:]]*[[:alnum:]_-]+[[:space:]]*=[[:space:]]*\{[[:space:]]*version[[:space:]]*=' \
    "Rust member manifests must inherit dependency versions from the workspace."
done

require_fixed "$nix_workspace" \
  'workspaceManifest = builtins.fromTOML (builtins.readFile ../../Cargo.toml);' \
  "Nix packaging must read the Cargo workspace package metadata."
require_fixed "$nix_workspace" \
  'workspaceVersion = workspaceManifest.workspace.package.version;' \
  "Nix packaging must derive its version from the Cargo workspace."
for package_file in custom_apps/rust/apps/*/default.nix; do
  require_fixed "$package_file" \
    'version = workspaceVersion;' \
    "Each Nix Rust package must use the Cargo workspace version."
done

metadata="$(cargo metadata \
  --manifest-path "$workspace_manifest" \
  --locked \
  --no-deps \
  --format-version 1)"

jq -e '
  (.packages | length == 4)
  and ([.packages[].version] | unique | length == 1)
  and ([.packages[].edition] | unique == ["2021"])
  and (
    [.packages[].dependencies[]]
    | group_by(.name)
    | all([.[].req] | unique | length == 1)
  )
' <<<"$metadata" >/dev/null || {
  echo "❌ Cargo resolved inconsistent direct requirements across workspace members." >&2
  jq '{packages: [.packages[] | {name, version, edition, dependencies: [.dependencies[] | {name, req}]}]}' \
    <<<"$metadata" >&2
  exit 1
}

nix_versions="$(flake_eval_json '
  system = "x86_64-linux";
  pkgs = f.inputs.nixpkgs.legacyPackages.${system};
  pkgsUnstable = f.inputs.nixpkgs-unstable.legacyPackages.${system};
  packageData = import ./flake/packages.nix {
    inherit lib pkgs pkgsUnstable;
    crane = f.inputs.crane;
  };
  workspaceMembers = [
    "browsertrix-downloader"
    "kanidm-canary-bootstrap"
    "mail-archive-ui"
    "media-manager"
  ];
in builtins.listToAttrs (map (name: {
  inherit name;
  value = packageData.rustApps.${name}.package.version;
}) workspaceMembers)
')"
workspace_version="$(jq -r '.packages[0].version' <<<"$metadata")"

jq -e --arg workspace_version "$workspace_version" \
  'all(.[]; . == $workspace_version)' \
  <<<"$nix_versions" >/dev/null || {
  echo "❌ Nix Rust package versions must match Cargo workspace version ${workspace_version}." >&2
  jq . <<<"$nix_versions" >&2
  exit 1
}
