#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"
cd "$TESTS_REPO_ROOT"
ensure_tools jq nix rg

host="$(test_default_host)"
invalid_log="$(mktemp)"
cleanup() { rm -f "$invalid_log"; }
trap cleanup EXIT

identity_json="$(NIXHOMESERVER_TEST_HOST="$host" nix eval --json --impure --expr '
  let
    f = builtins.getFlake (builtins.getEnv "NIXHOMESERVER_FLAKE_REF_FOR_EVAL");
    lib = f.inputs.nixpkgs.lib;
    hostName = builtins.getEnv "NIXHOMESERVER_TEST_HOST";
    host = builtins.getAttr hostName f.nixosConfigurations;
    cfg = host.config;
    vars = import ./vars.nix { inherit lib; };
    validation = import ./lib/name-validation.nix { inherit lib; };
    provision = cfg.services.kanidm.provision;
    personNames = builtins.attrNames provision.persons;
    groupNames = builtins.attrNames provision.groups;
    memberships = lib.concatMap
      (groupName: map (memberName: { inherit groupName memberName; }) (provision.groups.${groupName}.members or [ ]))
      groupNames;
  in {
    invalidPersons = builtins.filter (name: !validation.validKanidmUser name) personNames;
    invalidGroups = builtins.filter (name: !validation.validKanidmGroup name) groupNames;
    invalidMemberships = builtins.filter
      (membership: !validation.validKanidmEntryName membership.memberName)
      memberships;
    missingUsbPersons = builtins.filter
      (name: !(builtins.hasAttr name provision.persons))
      (vars.fileAccess.usbUsers or [ ]);
    missingMonitoringPersons = builtins.filter
      (name: !(builtins.hasAttr name provision.persons))
      (vars.monitoringAccess.users or [ ]);
  }
')"
jq -e '
  .invalidPersons == []
  and .invalidGroups == []
  and .invalidMemberships == []
  and .missingUsbPersons == []
  and .missingMonitoringPersons == []
' <<<"$identity_json" >/dev/null || {
  echo "❌ Evaluated Kanidm provisioning contains invalid or unprovisioned identity names."
  jq . <<<"$identity_json"
  exit 1
}

# Use distinct names here so this test catches a future regression even when
# the real usb/monitoring/SFTP users also happen to be ordinary app users.
projected_people="$(nix eval --json --impure --expr '
  let
    f = builtins.getFlake (builtins.getEnv "NIXHOMESERVER_FLAKE_REF_FOR_EVAL");
    lib = f.inputs.nixpkgs.lib;
    base = import ./vars.nix { inherit lib; };
    vars = base // {
      kanidmAppUsers = [ ];
      kanidmAppAdminUsers = [ ];
      kanidmBackupUsers = [ ];
      filesSftpUsers = [ "sftp-only" ];
      monitoringAccess = base.monitoringAccess // { users = [ "monitor-only" ]; };
      fileAccess = base.fileAccess // { usbUsers = [ "usb-only" ]; };
      kanidmAdminUser = "admin-only";
      kanidmAppUserEmails = { };
      kanidmAdminMailAddresses = [ ];
      kanidmAdminEmail = "admin@example.test";
    };
    projected = import ./modules/Core_Modules/kanidm/provision.nix {
      config = { nixhomeserver.modules = { }; };
      inherit lib vars;
      pkgs = { };
    };
  in builtins.attrNames projected.config.services.kanidm.provision.persons
')"
jq -e '
  index("admin-only") != null
  and index("monitor-only") != null
  and index("sftp-only") != null
  and index("usb-only") != null
' <<<"$projected_people" >/dev/null || {
  echo "❌ Special-purpose Kanidm users were not included in person provisioning."
  jq . <<<"$projected_people"
  exit 1
}

name_validation_json="$(nix eval --json --impure --expr '
  let
    f = builtins.getFlake (builtins.getEnv "NIXHOMESERVER_FLAKE_REF_FOR_EVAL");
    lib = f.inputs.nixpkgs.lib;
    validation = import ./lib/name-validation.nix { inherit lib; };
  in {
    acceptsPerson = validation.validKanidmUser "valid.person-1";
    acceptsGroup = validation.validKanidmGroup "valid_group-1";
    rejectsEmpty = !(validation.validKanidmEntryName "");
    rejectsUppercase = !(validation.validKanidmEntryName "Invalid");
    rejectsPath = !(validation.validKanidmEntryName "invalid/name");
    rejectsOverlong = !(validation.validKanidmEntryName (lib.concatStrings (lib.replicate 65 "a")));
  }
')"
jq -e '[.[]] | all' <<<"$name_validation_json" >/dev/null || {
  echo "❌ Kanidm entry-name validation accepted an unsafe name or rejected a supported one."
  jq . <<<"$name_validation_json"
  exit 1
}

invalid_provision_expr='
  let
    f = builtins.getFlake (builtins.getEnv "NIXHOMESERVER_FLAKE_REF_FOR_EVAL");
    hostName = builtins.getEnv "NIXHOMESERVER_TEST_HOST";
    host = (builtins.getAttr hostName f.nixosConfigurations).extendModules {
      modules = [{
        services.kanidm.provision.persons."Invalid Person".displayName = "Invalid Person";
        services.kanidm.provision.groups."Invalid Group" = {
          members = [ ];
          overwriteMembers = false;
        };
        services.kanidm.provision.groups."valid-regression-group" = {
          members = [ "Invalid Member" ];
          overwriteMembers = false;
        };
      }];
    };
  in host.config.system.build.toplevel.drvPath
'
if NIXHOMESERVER_TEST_HOST="$host" nix eval --raw --impure --expr "$invalid_provision_expr" >"$invalid_log" 2>&1; then
  echo "❌ Host evaluation accepted invalid Kanidm provision names."
  exit 1
fi
for expected_message in \
  "provisioned Kanidm person names" \
  "provisioned Kanidm group names" \
  "provisioned Kanidm group members"; do
  if ! rg -Fq "$expected_message" "$invalid_log"; then
    echo "❌ Invalid Kanidm provisioning failed without the expected validation: $expected_message"
    cat "$invalid_log"
    exit 1
  fi
done

canary_collision_expr='
  let
    f = builtins.getFlake (builtins.getEnv "NIXHOMESERVER_FLAKE_REF_FOR_EVAL");
    lib = f.inputs.nixpkgs.lib;
    base = import ./vars.nix { inherit lib; };
    vars = base // {
      identity = base.identity // {
        appUsers = [ base.kanidmCanaryUser ];
        localAdminUser = base.kanidmCanaryUser;
      };
      localAdminUser = base.kanidmCanaryUser;
    };
    pkgs = f.inputs.nixpkgs.legacyPackages.${base.hostPlatform};
    packageData = import ./flake/packages.nix {
      inherit lib pkgs;
      crane = f.inputs.crane;
    };
    hostSet = import ./flake/system.nix {
      inputs = f.inputs;
      inherit lib vars pkgs;
      system = base.hostPlatform;
      appPackages = packageData.appPackages;
    };
  in hostSet.nixosConfigurations.${base.hostname}.config.system.build.toplevel.drvPath
'
if nix eval --raw --impure --expr "$canary_collision_expr" >"$invalid_log" 2>&1; then
  echo "❌ Host evaluation accepted a canary username that collides with human identities."
  exit 1
fi
for expected_message in \
  "identity.canaryUser must be distinct" \
  "identity.appUsers" \
  "identity.localAdminUser"; do
  if ! rg -Fq "$expected_message" "$invalid_log"; then
    echo "❌ Canary identity collision failed without the expected validation: $expected_message"
    cat "$invalid_log"
    exit 1
  fi
done

echo "✅ Kanidm person, group, membership, and special-purpose user validation passed."
