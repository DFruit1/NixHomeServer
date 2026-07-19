#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"
cd "$TESTS_REPO_ROOT"
ensure_tools jq nix rg

validation_json="$(nix eval --impure --json --expr '
  let
    f = builtins.getFlake (builtins.getEnv "NIXHOMESERVER_FLAKE_REF_FOR_EVAL");
    lib = f.inputs.nixpkgs.lib;
    network = import ./lib/network-validation.nix { inherit lib; };
    names = import ./lib/name-validation.nix { inherit lib; };
    identity = import ./lib/identity-validation.nix;
    storage = import ./lib/storage-validation.nix { inherit lib; };
    identityFixture = {
      identity = {
        adminUser = "admin";
        localAdminUser = "local-admin";
        canaryUser = "canary-user";
        appUsers = [];
        appAdminUsers = [];
        appUserEmails = {};
      };
      backupAccess = { adminUsers = []; storageUsers = []; };
      fileAccess.usbUsers = [];
      seerrAccess.requestManagers = [];
    };
    allIdentityCollisions = identityFixture // {
      identity = identityFixture.identity // {
        adminUser = "canary-user";
        localAdminUser = "canary-user";
        appUsers = ["canary-user"];
        appAdminUsers = ["canary-user"];
        appUserEmails.canary-user = "person@example.test";
      };
      backupAccess = { adminUsers = ["canary-user"]; storageUsers = ["canary-user"]; };
      fileAccess.usbUsers = ["canary-user"];
      seerrAccess.requestManagers = ["canary-user"];
    };
  in {
    acceptsIPv4 = network.validIPv4 "192.168.50.10";
    rejectsLargeOctet = !network.validIPv4 "999.168.50.10";
    rejectsShortIPv4 = !network.validIPv4 "192.168.50";
    rejectsLeadingZero = !network.validIPv4 "192.168.050.10";
    acceptsCanonicalCidr = network.validIPv4Cidr "100.64.0.0/10";
    rejectsCidrHostBits = !network.validIPv4Cidr "100.64.0.1/10";
    rejectsLargePrefix = !network.validIPv4Cidr "100.64.0.0/33";
    acceptsUsableSubnet = network.sameUsableSubnet "192.168.50.10" "192.168.50.1" 24;
    rejectsDifferentSubnet = !network.sameUsableSubnet "192.168.50.10" "192.168.51.1" 24;
    rejectsNetworkAddress = !network.sameUsableSubnet "192.168.50.0" "192.168.50.1" 24;
    cidrContainsAddress = network.cidrContains "100.72.1.2" "100.64.0.0/10";
    cidrRejectsOutsideAddress = !network.cidrContains "192.168.1.1" "100.64.0.0/10";
    acceptsZpool = storage.validZpoolName "data-pool_1";
    rejectsReservedZpool = !storage.validZpoolName "mirror1";
    rejectsDeviceLikeZpool = !storage.validZpoolName "c0t0d0";
    rejectsPathZpool = !storage.validZpoolName "data/pool";
    rejectsNumericZpool = !storage.validZpoolName "1data";
    acceptsDiskId = storage.validDiskId "nvme-Samsung_SSD_1TB_S1234";
    rejectsDiskPath = !storage.validDiskId "/dev/nvme0n1";
    rejectsDiskTraversal = !storage.validDiskId "..";
    rejectsDiskWhitespace = !storage.validDiskId "disk with spaces";
    rejectsDiskPlaceholder = !storage.validDiskId "CHANGE_ME-system-disk";
    acceptsDnsName = names.validDnsName "server.home.arpa";
    rejectsUppercaseDns = !names.validDnsName "Server.home.arpa";
    rejectsDnsUnderscore = !names.validDnsName "server_name.home.arpa";
    acceptsPublicDomain = names.validPublicDomain "example.net";
    rejectsSingleLabelPublicDomain = !names.validPublicDomain "localhost";
    acceptsDistinctCanary = identity.canaryCollisionSources identityFixture == [];
    rejectsEveryCanaryCollision =
      lib.sort builtins.lessThan (identity.canaryCollisionSources allIdentityCollisions)
      == lib.sort builtins.lessThan [
        "identity.adminUser"
        "identity.localAdminUser"
        "identity.appUsers"
        "identity.appAdminUsers"
        "identity.appUserEmails"
        "backupAccess.adminUsers"
        "backupAccess.storageUsers"
        "fileAccess.usbUsers"
        "seerrAccess.requestManagers"
      ];
  }
')"

if ! jq -e '[to_entries[] | select(.value != true)] | length == 0' <<<"$validation_json" >/dev/null; then
  echo "❌ Shared network, storage, or name validation accepted an unsafe value or rejected a valid one."
  jq . <<<"$validation_json"
  exit 1
fi

host="$(test_default_host)"
invalid_filesystem_log="$(mktemp)"
cleanup() { rm -f "$invalid_filesystem_log"; }
trap cleanup EXIT

conflicting_filesystem_expr='
  let
    f = builtins.getFlake (builtins.getEnv "NIXHOMESERVER_FLAKE_REF_FOR_EVAL");
    hostName = builtins.getEnv "NIXHOMESERVER_TEST_HOST";
    baseHost = builtins.getAttr hostName f.nixosConfigurations;
    settings = builtins.getAttr hostName f.lib.nixhomeserverSettings;
    invalidHost = baseHost.extendModules {
      modules = [{
        fileSystems.${settings.dataRoot} = {
          device = "/dev/disk/by-label/accidental-data-root";
          fsType = "ext4";
        };
      }];
    };
  in invalidHost.config.system.build.toplevel.drvPath
'
if NIXHOMESERVER_TEST_HOST="$host" nix eval --impure --raw --expr "$conflicting_filesystem_expr" \
  >"$invalid_filesystem_log" 2>&1; then
  echo "❌ Host evaluation accepted a hardware-generated filesystem at the managed data root."
  exit 1
fi
if ! rg -Fq 'hardware-configuration.nix must not declare data-pool filesystems' "$invalid_filesystem_log"; then
  echo "❌ Conflicting data-root filesystem failed without the actionable validation message."
  cat "$invalid_filesystem_log"
  exit 1
fi

require_fixed scripts/admin/validate-config-readiness.sh 'ipaddress.IPv4Address' \
  "Readiness checks must validate IPv4 values numerically, not only by text shape."
require_fixed scripts/admin/validate-config-readiness.sh 'ipaddress.IPv4Network(sys.argv[5], strict=True)' \
  "Readiness checks must reject non-canonical NetBird CIDRs."

echo "✅ Network, DNS, Kanidm-adjacent name, ZFS pool, and managed-filesystem validation passed."
