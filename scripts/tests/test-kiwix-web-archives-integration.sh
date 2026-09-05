#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"

cd "$TESTS_REPO_ROOT"

ensure_tools jq nix

host="$(test_default_host)"

evaluate_host() {
  NIXHOMESERVER_TEST_HOST="$host" nix eval --impure --json --expr '
    let
      flake = builtins.getFlake (builtins.getEnv "NIXHOMESERVER_FLAKE_REF_FOR_EVAL");
      hostName = builtins.getEnv "NIXHOMESERVER_TEST_HOST";
      enabledApps = builtins.fromJSON (builtins.getEnv "NIXHOMESERVER_TEST_ENABLED_APPS");
      configuredVars = flake.lib.nixhomeserverSettings.${hostName};
      settings = configuredVars // {
        applications = configuredVars.applications // { enabled = enabledApps; };
      };
      vars = settings // (import ./lib/derive-vars.nix {
        inherit (flake.inputs.nixpkgs) lib;
        inherit settings;
      });
      pkgs = flake.inputs.nixpkgs.legacyPackages.${vars.hostPlatform};
      packageData = import ./flake/packages.nix {
        inherit (flake.inputs.nixpkgs) lib;
        inherit pkgs;
        crane = flake.inputs.crane;
      };
      system = import ./flake/system.nix {
        inputs = flake.inputs;
        inherit (flake.inputs.nixpkgs) lib;
        inherit pkgs vars;
        system = vars.hostPlatform;
        appPackages = packageData.appPackages;
      };
      cfg = system.nixosConfigurations.${hostName}.config;
      readerExecStart = (cfg.systemd.services.kiwix-serve-archives or {
        serviceConfig = { };
        wantedBy = [ ];
        requires = [ ];
        after = [ ];
        unitConfig = { };
      }).serviceConfig;
    in {
      expectedPort = vars.networking.ports.kiwixArchives or null;
      libraryRoot = cfg.repo.kiwix.paths.libraryRoot or null;
      browsertrixModule = cfg.nixhomeserver.modules.browsertrix-downloader or false;
      kiwixModule = cfg.nixhomeserver.modules.kiwix or false;
      zimRootEnv = (cfg.systemd.services.browsertrix-downloader.environment or { }).BROWSERTRIX_DOWNLOADER_ZIM_ROOT or null;
      readerUrlEnv = (cfg.systemd.services.browsertrix-downloader.environment or { }).BROWSERTRIX_DOWNLOADER_ZIM_READER_URL or null;
      supplementaryGroups = (cfg.systemd.services.browsertrix-downloader.serviceConfig or { }).SupplementaryGroups or [ ];
      readOnlyPaths = (cfg.systemd.services.browsertrix-downloader.serviceConfig or { }).ReadOnlyPaths or [ ];
      readerServicePresent = builtins.hasAttr "kiwix-serve-archives" cfg.systemd.services;
      readerUser = readerExecStart.User or null;
      readerGroup = readerExecStart.Group or null;
      readerExecStart = readerExecStart.ExecStart or null;
      readerNoNewPrivileges = readerExecStart.NoNewPrivileges or null;
      readerReadOnlyPaths = readerExecStart.ReadOnlyPaths or [ ];
      readerRequires = (cfg.systemd.services.kiwix-serve-archives or { requires = [ ]; }).requires or [ ];
      readerAfter = (cfg.systemd.services.kiwix-serve-archives or { after = [ ]; }).after or [ ];
      readerWantedBy = (cfg.systemd.services.kiwix-serve-archives or { wantedBy = [ ]; }).wantedBy or [ ];
      readerRequiresMountsFor = (cfg.systemd.services.kiwix-serve-archives or { unitConfig = { }; }).unitConfig.RequiresMountsFor or [ ];
      readerConditionMount = (cfg.systemd.services.kiwix-serve-archives or { unitConfig = { }; }).unitConfig.ConditionPathIsMountPoint or null;
      dataRoot = vars.dataRoot;
      dataPoolGuarded = builtins.elem "kiwix-serve-archives" cfg.repo.storage.dataPool.guardedServices;
      catalogGuarded = builtins.elem "kiwix-serve-archives" (import ./modules/catalog.nix).apps.kiwix.guardedServices;
      gatewayBrowsertrix = cfg.repo.authGateway.protectedApps.browsertrix or null;
      readerRoutes = (cfg.repo.authGateway.protectedApps.browsertrix or { authenticatedRoutes = [ ]; }).authenticatedRoutes or [ ];
      kiwixServePresent = cfg.services.kiwix-serve.enable;
    }' 2>/dev/null
}

# Both applications enabled: the Kiwix library must be reachable through the
# Web Archives application.
export NIXHOMESERVER_TEST_ENABLED_APPS='["browsertrix-downloader","kiwix"]'
combined_json="$(evaluate_host)"

combined_ok="$(jq -e '
  .expectedPort as $port
  | .libraryRoot as $libraryRoot
  | (.gatewayBrowsertrix.allowedGroups | index("web-archive-users") != null)
  and .browsertrixModule
  and .kiwixModule
  and .kiwixServePresent
  and (.zimRootEnv == $libraryRoot)
  and (.readerUrlEnv == "/zim/")
  and (.supplementaryGroups | index("kiwix") != null)
  and (.readOnlyPaths | index($libraryRoot) != null)
  and .readerServicePresent
  and (.readerUser == "kiwix")
  and (.readerGroup == "kiwix")
  and (.readerNoNewPrivileges == true)
  and (.readerExecStart | contains("--urlRootLocation=/zim"))
  and (.readerExecStart | contains("--monitorLibrary"))
  and (.readerExecStart | contains("--library=/var/lib/kiwix/library.xml"))
  and (.readerExecStart | contains("--port=\($port)"))
  and (.readerReadOnlyPaths | index($libraryRoot) != null)
  and (.readerRequiresMountsFor | index($libraryRoot) != null)
  and (.readerRequires | index("data-pool-layout.service") != null)
  and (.readerAfter | index("kiwix-library-sync.service") != null)
  and (.readerWantedBy | index("multi-user.target") != null)
  and (.readerConditionMount == .dataRoot)
  and .dataPoolGuarded
  and .catalogGuarded
  and (.readerRoutes | length == 1)
  and (.readerRoutes[0].pathPrefix == "/zim")
  and (.readerRoutes[0].upstream == "http://127.0.0.1:\($port)")
' <<<"$combined_json" >/dev/null && echo yes || echo no)"
if [[ "$combined_ok" != "yes" ]]; then
  echo "❌ Kiwix archives are not correctly exposed through the Web Archives application." >&2
  jq . <<<"$combined_json" >&2
  exit 1
fi

echo "✓ Kiwix archives are exposed through the Web Archives application."

# Removing the Web Archives application must leave Kiwix standalone: no reader
# mirror, no environment wiring, and no authenticated route.
export NIXHOMESERVER_TEST_ENABLED_APPS='["kiwix"]'
kiwix_only_json="$(evaluate_host)"

jq -e '
  .libraryRoot as $libraryRoot
  | .kiwixModule
  and .kiwixServePresent
  and (.browsertrixModule == false)
  and (.zimRootEnv == null)
  and (.readerUrlEnv == null)
  and (.supplementaryGroups | index("kiwix") == null)
  and (.readOnlyPaths | index($libraryRoot) == null)
  and (.readerServicePresent == false)
  and (.gatewayBrowsertrix == null)
  and (.readerRoutes == [])
' <<<"$kiwix_only_json" >/dev/null || {
  echo "❌ Removing Web Archives left Kiwix integration surfaces behind." >&2
  jq . <<<"$kiwix_only_json" >&2
  exit 1
}

echo "✅ Kiwix Web Archives integration tests passed."
