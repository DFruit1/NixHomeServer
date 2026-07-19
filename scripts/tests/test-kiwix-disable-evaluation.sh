#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"
cd "$TESTS_REPO_ROOT"
ensure_tools jq nix

host="$(test_default_host)"

disabled_json="$(NIXHOMESERVER_TEST_HOST="$host" nix eval --impure --json --expr '
let
  flake = builtins.getFlake (builtins.getEnv "NIXHOMESERVER_FLAKE_REF_FOR_EVAL");
  inherit (flake.inputs.nixpkgs) lib;
  hostName = builtins.getEnv "NIXHOMESERVER_TEST_HOST";
  host = (builtins.getAttr hostName flake.nixosConfigurations).extendModules {
    modules = [
      { repo.kiwix.enable = lib.mkForce false; }
    ];
  };
  cfg = host.config;
  vars = builtins.getAttr hostName flake.lib.nixhomeserverSettings;
  wikiHost = "wiki.${vars.domain}";
  kiwixServiceNames = [
    "kiwix-serve"
    "kiwix-library-sync"
    "kiwix-library-watch"
    "kiwix-library-root-layout-v1"
    "kiwix-oauth2-proxy"
  ];
  kiwixSecretNames = [
    "kiwixOauth2ProxyClientSecret"
    "kiwixOauth2ProxyCookieSecret"
  ];
  outputDrv = value:
    builtins.head (builtins.attrNames (builtins.getContext (toString value)));
in {
  # Forcing the toplevel derivation also proves that the disabled module leaves
  # no secret assertion or dangling option reference that can break evaluation.
  drvPath = cfg.system.build.toplevel.drvPath;
  registryPresent = cfg.nixhomeserver.modules.kiwix or false;
  libraryRoot = cfg.repo.kiwix.paths.libraryRoot;
  serviceEnabled = cfg.services.kiwix-serve.enable;
  serviceUnits = builtins.filter
    (name: builtins.hasAttr name cfg.systemd.services)
    kiwixServiceNames;
  timerUnits = builtins.filter
    (name: builtins.hasAttr name cfg.systemd.timers)
    kiwixServiceNames;
  caddyHosts = builtins.filter
    (name: builtins.hasAttr name cfg.services.caddy.virtualHosts)
    [ wikiHost "http://wiki" "http://wiki.${vars.networking.dns.lanDomain}" ];
  privateDnsHosts = builtins.filter
    (name: builtins.hasAttr name cfg.services.unbound.privateHosts)
    [ wikiHost "wiki" "wiki.${vars.networking.dns.lanDomain}" ];
  gatewayRegistered = builtins.hasAttr "kiwix" cfg.repo.authGateway.protectedApps;
  gatewayConflicts = builtins.filter
    (unit: unit == "kiwix-oauth2-proxy.service")
    cfg.systemd.services.auth-gateway-oauth2-proxy.conflicts;
  oauthRegistered = builtins.hasAttr "kiwix-web" cfg.services.kanidm.provision.systems.oauth2;
  kanidmGroupRegistered = builtins.hasAttr "kiwix-users" cfg.services.kanidm.provision.groups;
  kanidmGroupDescribed = builtins.hasAttr "kiwix-users" cfg.nixhomeserver.kanidmGroupDescriptions;
  gatewayScopeRegistered = builtins.hasAttr
    "kiwix-users"
    cfg.services.kanidm.provision.systems.oauth2.auth-gateway-web.scopeMaps;
  localUserRegistered = builtins.hasAttr "kiwix" cfg.users.users;
  localGroupRegistered = builtins.hasAttr "kiwix" cfg.users.groups;
  ageSecrets = builtins.filter
    (name: builtins.hasAttr name cfg.age.secrets)
    kiwixSecretNames;
  contentSubdirRegistered = builtins.elem "_Kiwix" cfg.repo.storage.sharedRoots.contentSubdirs;
  backupCriticalPathRegistered = builtins.elem
    cfg.repo.kiwix.paths.libraryRoot
    cfg.repo.backups.criticalPaths;
  backupInventoryLabels = map (entry: entry.label) cfg.repo.backups.pathInventories;
  backupRowLabels = map (entry: entry.label) cfg.repo.backups.pathRows.app-content-roots;
  filestashGroups = cfg.users.users.filestash.extraGroups;
  filestashReadWritePaths = cfg.systemd.services.filestash.serviceConfig.ReadWritePaths or [ ];
  statePersistenceRetained = builtins.elem
    "/var/lib/kiwix"
    cfg.repo.impermanence.inventory.persistenceDirectories;
  canaryConfigDrv = outputDrv cfg.systemd.services.homepage-canary.environment.CANARY_CONFIG_FILE;
  homepageConfigDrv = outputDrv cfg.systemd.services.homepage.environment.HOMEPAGE_CONFIG_FILE;
}
')"

jq -e '
  .libraryRoot as $libraryRoot
  | (.drvPath | startswith("/nix/store/") and endswith(".drv"))
  and (.registryPresent == true)
  and (.serviceEnabled == false)
  and (.serviceUnits == [])
  and (.timerUnits == [])
  and (.caddyHosts == [])
  and (.privateDnsHosts == [])
  and (.gatewayRegistered == false)
  and (.gatewayConflicts == [])
  and (.oauthRegistered == false)
  and (.kanidmGroupRegistered == false)
  and (.kanidmGroupDescribed == false)
  and (.gatewayScopeRegistered == false)
  and (.localUserRegistered == false)
  and (.localGroupRegistered == false)
  and (.ageSecrets == [])
  and (.contentSubdirRegistered == false)
  and (.backupCriticalPathRegistered == false)
  and (.backupInventoryLabels | index("kiwix") == null)
  and (.backupRowLabels | index("kiwix-library") == null)
  and (.filestashGroups | index("kiwix") == null)
  and (.filestashReadWritePaths | index($libraryRoot) == null)
  and (.statePersistenceRetained == true)
' <<<"$disabled_json" >/dev/null || {
  echo "❌ Disabling Kiwix left a runtime, route, identity, secret, backup, or integration surface enabled."
  jq . <<<"$disabled_json"
  exit 1
}

text_derivation_payload() {
  local drv_path="$1"

  nix derivation show "$drv_path" | jq -er '
    (if has("derivations") then .derivations else . end)
    | to_entries
    | if length == 1 and (.[0].value.env.text | type) == "string" then
        .[0].value.env.text
      else
        error("expected exactly one writeText derivation with an inline text payload")
      end
  '
}

# Inspect writeText's derivation payload instead of realising it. This keeps the
# test evaluation-only and lets it run in a network-isolated nested Nix store
# without attempting to rebuild the complete stdenv closure.
canary_config="$(text_derivation_payload "$(jq -r .canaryConfigDrv <<<"$disabled_json")")"
homepage_config="$(text_derivation_payload "$(jq -r .homepageConfigDrv <<<"$disabled_json")")"

jq -e '(.targets | map(.id) | index("wiki")) == null' <<<"$canary_config" >/dev/null || {
  echo "❌ Disabling Kiwix left the wiki target in the authenticated canary."
  jq . <<<"$canary_config"
  exit 1
}

jq -e '
  ([.services[] | select(.id == "wiki") | .enabled] == [false])
  and ([.folderGuides[] | select(.id == "kiwix") | .enabled] == [false])
  and (.adminGuide | map(.title) | index("Re-run Kiwix library sync") == null)
' <<<"$homepage_config" >/dev/null || {
  echo "❌ Disabling Kiwix left an enabled Homepage or operator surface behind."
  jq . <<<"$homepage_config"
  exit 1
}

echo "✅ Kiwix enable=false removes all runtime surfaces while retaining persisted state."
