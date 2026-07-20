#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"
cd "$TESTS_REPO_ROOT"
ensure_tools jq nix rg

model_json="$(nix eval --impure --json --expr '
  let
    f = builtins.getFlake (builtins.getEnv "NIXHOMESERVER_FLAKE_REF_FOR_EVAL");
    lib = f.inputs.nixpkgs.lib;
    derive = import ./lib/authorization-groups.nix { inherit lib; };
    malformed = derive {
      monitoringAccess.group = { };
      seerrAccess.requestManagerGroup = [ ];
    };
  in {
    monitoringFallback = malformed.monitoringGroup;
    seerrFallback = malformed.seerrRequestManagerGroup;
    monitoringInputPreserved = builtins.isAttrs malformed.configuredMonitoringGroup;
    seerrInputPreserved = builtins.isList malformed.configuredSeerrRequestManagerGroup;
  }
')"

if ! jq -e '
  .monitoringFallback == "invalid-monitoring-access-group"
  and .seerrFallback == "invalid-seerr-request-manager-group"
  and .monitoringInputPreserved
  and .seerrInputPreserved
' <<<"$model_json" >/dev/null; then
  echo "❌ Authorization-group derivation is not total for malformed operator input." >&2
  jq . <<<"$model_json" >&2
  exit 1
fi

assertion_matrix_json="$(nix eval --impure --json --expr '
  let
    f = builtins.getFlake (builtins.getEnv "NIXHOMESERVER_FLAKE_REF_FOR_EVAL");
    lib = f.inputs.nixpkgs.lib;
    base = import ./vars.nix { inherit lib; };
    pkgs = f.inputs.nixpkgs.legacyPackages.${base.hostPlatform};
    packages = import ./flake/packages.nix {
      inherit lib pkgs;
      crane = f.inputs.crane;
    };
    baseSystem = import ./flake/system.nix {
      inputs = f.inputs;
      lib = lib;
      vars = base;
      inherit pkgs;
      system = base.hostPlatform;
      appPackages = packages.appPackages;
    };
    baseConfig = baseSystem.nixosConfigurations.${base.hostname}.config;
    testCases = [
      "invalid-monitoring"
      "invalid-seerr"
      "monitoring-app"
      "monitoring-local-bridge"
      "seerr-file"
      "seerr-backup"
      "mutual-active"
      "monitoring-offline-active"
      "seerr-offline-active"
      "mutual-inactive"
      "monitoring-offline-inactive"
      "seerr-file-inactive"
    ];
    varsFor = testCase:
      let
        monitoringAccess = base.monitoringAccess // {
          group =
            if testCase == "invalid-monitoring" then { }
            else if testCase == "monitoring-app" then "app-admin"
            else if testCase == "monitoring-local-bridge" then base.fileAccess.localSftpAccessGroup
            else if builtins.elem testCase [ "mutual-active" "mutual-inactive" ] then "combined-role"
            else if builtins.elem testCase [ "monitoring-offline-active" "monitoring-offline-inactive" ] then "offline-role"
            else "monitoring-users";
        };
        seerrAccess = base.seerrAccess // {
          requestManagerGroup =
            if testCase == "invalid-seerr" then [ ]
            else if builtins.elem testCase [ "seerr-file" "seerr-file-inactive" ] then base.fileAccess.webAccessGroup
            else if testCase == "seerr-backup" then base.backupStorageGroup
            else if builtins.elem testCase [ "mutual-active" "mutual-inactive" ] then "combined-role"
            else if testCase == "seerr-offline-active" then "offline-role"
            else "seerr-request-managers";
        };
        offlineMedia = base.offlineMedia // {
          enable = testCase != "monitoring-offline-inactive";
          accessGroup =
            if builtins.elem testCase [
              "monitoring-offline-active"
              "monitoring-offline-inactive"
              "seerr-offline-active"
            ] then "offline-role" else "users";
        };
        authorizationGroupModel = (import ./lib/authorization-groups.nix { inherit lib; }) {
          inherit monitoringAccess seerrAccess;
        };
        vars = base // {
          inherit authorizationGroupModel monitoringAccess offlineMedia seerrAccess;
          configuredMonitoringAccessGroup = authorizationGroupModel.configuredMonitoringGroup;
          monitoringAccessGroup = authorizationGroupModel.monitoringGroup;
          configuredSeerrRequestManagerGroup = authorizationGroupModel.configuredSeerrRequestManagerGroup;
          seerrRequestManagerGroup = authorizationGroupModel.seerrRequestManagerGroup;
        };
      in vars;
    isAuthorizationAssertion = entry:
      let message = entry.message or "";
      in lib.hasPrefix "nixhomeserver: monitoringAccess.group" message
        || lib.hasPrefix "nixhomeserver: seerrAccess.requestManagerGroup" message;
    inspectCase = testCase:
      let
        vars = varsFor testCase;
        seerrEnabled = builtins.elem testCase [
          "mutual-active"
          "seerr-backup"
          "seerr-file"
          "seerr-offline-active"
        ];
        # Reuse one real host configuration and vary only the feature flag read
        # by these assertions. This evaluates the central assertion definitions
        # themselves without constructing twelve complete NixOS systems.
        config = baseConfig // {
          repo = baseConfig.repo // {
            seerr = baseConfig.repo.seerr // { enable = seerrEnabled; };
          };
        };
        centralAssertions = (import ./modules/Core_Modules/validation {
          inherit config;
          inherit lib;
          inherit vars;
        }).assertions;
        assertions = builtins.filter isAuthorizationAssertion
          centralAssertions;
      in {
        assertionCount = builtins.length assertions;
        failures = map (entry: entry.message)
          (builtins.filter (entry: !entry.assertion) assertions);
      };
  in
  builtins.listToAttrs (map
    (testCase: {
      name = testCase;
      value = inspectCase testCase;
    })
    testCases)
')"

if ! jq -e 'all(.[]; .assertionCount == 5)' <<<"$assertion_matrix_json" >/dev/null; then
  echo "❌ Authorization-group matrix did not inspect all five central assertions." >&2
  jq . <<<"$assertion_matrix_json" >&2
  exit 1
fi

assert_rejected() {
  local test_case="$1"
  local expected_message="$2"

  if ! jq -e --arg testCase "$test_case" --arg expected "$expected_message" '
    .[$testCase].failures
    | length > 0 and any(.[]; contains($expected))
  ' <<<"$assertion_matrix_json" >/dev/null; then
    echo "❌ Authorization-group case '$test_case' did not fail its central assertion with actionable guidance." >&2
    jq --arg testCase "$test_case" '.[$testCase]' <<<"$assertion_matrix_json" >&2
    exit 1
  fi
}

assert_rejected invalid-monitoring \
  'monitoringAccess.group must be a valid Kanidm group name'
assert_rejected invalid-seerr \
  'seerrAccess.requestManagerGroup must be a valid Kanidm group name'
assert_rejected monitoring-app \
  'monitoringAccess.group must be a dedicated authorization group'
assert_rejected monitoring-local-bridge \
  'monitoringAccess.group must be a dedicated authorization group'
assert_rejected seerr-file \
  'seerrAccess.requestManagerGroup must be a dedicated authorization group when Seerr is enabled'
assert_rejected seerr-backup \
  'seerrAccess.requestManagerGroup must be a dedicated authorization group when Seerr is enabled'
assert_rejected mutual-active \
  'monitoringAccess.group and seerrAccess.requestManagerGroup must be distinct when Seerr is enabled'
assert_rejected monitoring-offline-active \
  'monitoringAccess.group must be a dedicated authorization group'
assert_rejected seerr-offline-active \
  'seerrAccess.requestManagerGroup must be a dedicated authorization group when Seerr is enabled'

# Inactive optional roles must not reserve names or create authorization
# surfaces. These two cases would be collisions if their optional feature were
# active, and are intentionally allowed while that feature is off.
for inactive_case in mutual-inactive monitoring-offline-inactive seerr-file-inactive; do
  if ! jq -e --arg testCase "$inactive_case" \
      '.[$testCase].failures == []' <<<"$assertion_matrix_json" >/dev/null; then
    echo "❌ Inactive optional authorization case '$inactive_case' failed a central assertion." >&2
    jq --arg testCase "$inactive_case" '.[$testCase]' <<<"$assertion_matrix_json" >&2
    exit 1
  fi
done

behavior_json="$(nix eval --impure --json --expr '
  let
    f = builtins.getFlake (builtins.getEnv "NIXHOMESERVER_FLAKE_REF_FOR_EVAL");
    lib = f.inputs.nixpkgs.lib;
    base = import ./vars.nix { inherit lib; };
    monitoringAccess = base.monitoringAccess // { group = "custom-monitoring-role"; };
    seerrAccess = base.seerrAccess // { requestManagerGroup = "custom-seerr-role"; };
    authorizationGroupModel = (import ./lib/authorization-groups.nix { inherit lib; }) {
      inherit monitoringAccess seerrAccess;
    };
    vars = base // {
      inherit authorizationGroupModel monitoringAccess seerrAccess;
      configuredMonitoringAccessGroup = authorizationGroupModel.configuredMonitoringGroup;
      monitoringAccessGroup = authorizationGroupModel.monitoringGroup;
      configuredSeerrRequestManagerGroup = authorizationGroupModel.configuredSeerrRequestManagerGroup;
      seerrRequestManagerGroup = authorizationGroupModel.seerrRequestManagerGroup;
    };
    pkgs = f.inputs.nixpkgs.legacyPackages.${base.hostPlatform};
    packages = import ./flake/packages.nix {
      inherit lib pkgs;
      crane = f.inputs.crane;
    };
    system = import ./flake/system.nix {
      inputs = f.inputs;
      inherit lib vars pkgs;
      system = base.hostPlatform;
      appPackages = packages.appPackages;
    };
    cfg = (system.nixosConfigurations.${base.hostname}.extendModules {
      modules = [ { repo.seerr.enable = lib.mkForce true; } ];
    }).config;
    groups = cfg.services.kanidm.provision.groups;
  in {
    toplevel = cfg.system.build.toplevel.drvPath;
    monitoringProvisioned = builtins.hasAttr "custom-monitoring-role" groups;
    monitoringMembers = groups.custom-monitoring-role.members;
    monitoringGatewayScope = builtins.hasAttr "custom-monitoring-role"
      cfg.services.kanidm.provision.systems.oauth2.auth-gateway-web.scopeMaps;
    monitoringClientScope = builtins.hasAttr "custom-monitoring-role"
      cfg.services.kanidm.provision.systems.oauth2.monitor-web.scopeMaps;
    monitoringGatewayRole = cfg.repo.authGateway.protectedApps.monitor.allowedGroups;
    seerrProvisioned = builtins.hasAttr "custom-seerr-role" groups;
    oldMonitoringAbsent = !(builtins.hasAttr "monitoring-users" groups);
    oldSeerrAbsent = !(builtins.hasAttr "seerr-request-managers" groups);
  }
')"

if ! jq -e '
  (.toplevel | startswith("/nix/store/"))
  and .monitoringProvisioned
  and (.monitoringMembers | index("canary-user") != null)
  and .monitoringGatewayScope
  and .monitoringClientScope
  and .monitoringGatewayRole == ["custom-monitoring-role"]
  and .seerrProvisioned
  and .oldMonitoringAbsent
  and .oldSeerrAbsent
' <<<"$behavior_json" >/dev/null; then
  echo "❌ Valid custom authorization groups did not propagate to every runtime surface." >&2
  jq . <<<"$behavior_json" >&2
  exit 1
fi

echo "✅ Monitoring and Seerr authorization-group validation tests passed."
