#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"
cd "$TESTS_REPO_ROOT"
ensure_tools jq nix

host="$(test_default_host)"
export NIXHOMESERVER_TEST_HOST="$host"

vaultwarden_json="$(
  nix eval --impure --json --expr '
    let
      flake = builtins.getFlake (builtins.getEnv "NIXHOMESERVER_FLAKE_REF_FOR_EVAL");
      host = builtins.getEnv "NIXHOMESERVER_TEST_HOST";
      cfg = (builtins.getAttr host flake.nixosConfigurations).config;
      package = cfg.services.vaultwarden.package;
      webVaultPackage = cfg.services.vaultwarden.webVaultPackage;
      unstablePackage = (builtins.getAttr cfg.nixpkgs.hostPlatform.system flake.inputs.nixpkgs-unstable.legacyPackages).vaultwarden;
    in {
      compatible = flake.inputs.nixpkgs.lib.versionAtLeast package.version "1.37.2";
      packageVersion = package.version;
      unstablePackageVersion = unstablePackage.version;
      bundledWebVault = package.webvault.drvPath;
      configuredWebVault = webVaultPackage.drvPath;
    }
  '
)"

jq -e '
  .compatible
  and .packageVersion == .unstablePackageVersion
  and .bundledWebVault == .configuredWebVault
' <<<"$vaultwarden_json" >/dev/null || {
  echo "❌ Vaultwarden must track the nixpkgs unstable package and use its matching bundled web vault."
  jq . <<<"$vaultwarden_json"
  exit 1
}

echo "✅ Vaultwarden is compatible with Bitwarden 2026.8 clients and uses its bundled web vault."
