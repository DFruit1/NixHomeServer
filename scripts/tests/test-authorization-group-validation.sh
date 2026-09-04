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
    };
  in {
    monitoringFallback = malformed.monitoringGroup;
    monitoringInputPreserved = builtins.isAttrs malformed.configuredMonitoringGroup;
  }
')"

if ! jq -e '
  .monitoringFallback == "invalid-monitoring-access-group"
  and .monitoringInputPreserved
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
      "monitoring-app"
      "monitoring-local-bridge"
      "monitoring-offline-active"
      "monitoring-offline-inactive"
    ];
    varsFor = testCase:
      let
        monitoringAccess = base.monitoringAccess // {
          group =
            if testCase == "invalid-monitoring" then { }
            else if testCase == "monitoring-app" then "app-admin"
            else if testCase == "monitoring-local-bridge" then base.fileAccess.localSftpAccessGroup
            else if builtins.elem testCase [ "monitoring-offline-active" "monitoring-offline-inactive" ] then "offline-role"
            else "monitoring-users";
        };
        offlineMedia = base.offlineMedia // {
          enable = testCase != "monitoring-offline-inactive";
          accessGroup =
            if builtins.elem testCase [ "monitoring-offline-active" "monitoring-offline-inactive" ] then "offline-role" else "users";
        };
        authorizationGroupModel = (import ./lib/authorization-groups.nix { inherit lib; }) {
          inherit monitoringAccess;
        };
        vars = base // {
          inherit authorizationGroupModel monitoringAccess offlineMedia;
          configuredMonitoringAccessGroup = authorizationGroupModel.configuredMonitoringGroup;
          monitoringAccessGroup = authorizationGroupModel.monitoringGroup;
        };
      in vars;
    isAuthorizationAssertion = entry:
      let message = entry.message or "";
      in lib.hasPrefix "nixhomeserver: monitoringAccess.group" message;
    inspectCase = testCase:
      let
        vars = varsFor testCase;
        # Reuse one real host configuration and vary only the feature flag read
        # by these assertions. This evaluates the central assertion definitions
        # themselves without constructing five complete NixOS systems.
        config = baseConfig;
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

if ! jq -e 'all(.[]; .assertionCount == 2)' <<<"$assertion_matrix_json" >/dev/null; then
  echo "❌ Authorization-group matrix did not inspect all central monitoring assertions." >&2
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
assert_rejected monitoring-app \
  'monitoringAccess.group must be a dedicated authorization group'
assert_rejected monitoring-local-bridge \
  'monitoringAccess.group must be a dedicated authorization group'
assert_rejected monitoring-offline-active \
  'monitoringAccess.group must be a dedicated authorization group'

# Inactive optional roles must not reserve names or create authorization
# surfaces. This case would collide if its optional feature were active, and is
# intentionally allowed while that feature is off.
for inactive_case in monitoring-offline-inactive; do
  if ! jq -e --arg testCase "$inactive_case" \
      '.[$testCase].failures == []' <<<"$assertion_matrix_json" >/dev/null; then
    echo "❌ Inactive optional authorization case '$inactive_case' failed a central assertion." >&2
    jq --arg testCase "$inactive_case" '.[$testCase]' <<<"$assertion_matrix_json" >&2
    exit 1
  fi
done

echo "✅ Monitoring authorization-group validation tests passed."