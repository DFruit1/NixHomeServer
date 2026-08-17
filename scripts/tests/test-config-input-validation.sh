#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"
cd "$TESTS_REPO_ROOT"
ensure_tools jq nix rg

validation_json="$(flake_eval_json '
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
  };
  allIdentityCollisions = identityFixture // {
    identity = identityFixture.identity // {
      adminUser = "canary-user";
      localAdminUser = "canary-user";
      appUsers = ["canary-user"];
      appAdminUsers = ["canary-user"];
      appUserEmails.canary-user = "person@example.test";
    };
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
  rejectsGatewayAsLanIp = !network.sameUsableSubnet "192.168.50.1" "192.168.50.1" 24;
  rejectsDifferentSubnet = !network.sameUsableSubnet "192.168.50.10" "192.168.51.1" 24;
  rejectsNetworkAddress = !network.sameUsableSubnet "192.168.50.0" "192.168.50.1" 24;
  acceptsLanHostInSubnet = network.usableIPv4InSubnet "192.168.50.20" "192.168.50.10" 24;
  acceptsLanGatewayInSubnet = network.usableIPv4InSubnet "192.168.50.1" "192.168.50.10" 24;
  rejectsLanHostOutsideSubnet = !network.usableIPv4InSubnet "192.168.51.20" "192.168.50.10" 24;
  rejectsLanNetworkAddress = !network.usableIPv4InSubnet "192.168.50.0" "192.168.50.10" 24;
  rejectsLanBroadcastAddress = !network.usableIPv4InSubnet "192.168.50.255" "192.168.50.10" 24;
  rejectsMistypedLanPrefix = !network.usableIPv4InSubnet "192.168.50.20" "192.168.50.10" "24";
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
  acceptsOperatorEmail = identity.validEmail "operator@example.net";
  rejectsEmailWithoutPublicDomain = !identity.validEmail "operator@localhost";
  rejectsEmailWhitespace = !identity.validEmail "operator name@example.net";
  rejectsConsecutiveEmailDots = !identity.validEmail "operator..name@example.net";
  rejectsTrailingEmailDot = !identity.validEmail "operator.@example.net";
  detectsExampleEmailPlaceholder = identity.placeholderEmail "admin@example.test";
  detectsTestEmailPlaceholder = identity.placeholderEmail "admin@home.test";
  acceptsNonPlaceholderEmail = !identity.placeholderEmail "admin@mydomain.net";
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
    ];
}
')"

if ! jq -e '[to_entries[] | select(.value != true)] | length == 0' <<<"$validation_json" >/dev/null; then
  echo "❌ Shared network, storage, or name validation accepted an unsafe value or rejected a valid one."
  jq . <<<"$validation_json"
  exit 1
fi

host="$(test_default_host)"

invalid_auth_expiry_log="$(capture_eval_failure '
  base = import ./vars.nix { inherit lib; };
  invalid = base // { kanidmAuthSessionExpirySeconds = "fourteen days"; };
in import ./lib/validate-host-settings.nix {
  inherit lib;
  hostName = invalid.hostname;
  settings = invalid;
}
')"
if ! rg -Fq 'identity.authSessionExpirySeconds must be a positive integer number of seconds' \
  <<<"$invalid_auth_expiry_log"; then
  echo "❌ A mistyped Kanidm authentication-session expiry bypassed host-settings validation."
  printf '%s\n' "$invalid_auth_expiry_log"
  exit 1
fi

NIXHOMESERVER_TEST_HOST="$host" eval_fails_with 'hardware-configuration.nix must not declare data-pool filesystems' '
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

eval_fails_with 'derived service endpoints contain duplicate port values' '
  base = import ./vars.nix { inherit lib; };
  collidedPorts = base.networking.ports // {
    homepage = base.networking.ports.kopia + 1;
  };
  vars = base // {
    networking = base.networking // { ports = collidedPorts; };
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
in system.nixosConfigurations.${base.hostname}.config.system.build.toplevel.drvPath
'

eval_fails_with 'service endpoint ports must be integers from 1 through 65535' '
  base = import ./vars.nix { inherit lib; };
  vars = base // {
    networking = base.networking // {
      ports = base.networking.ports // { kopia = "not-a-port"; };
    };
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
in system.nixosConfigurations.${base.hostname}.config.system.build.toplevel.drvPath
'

invalid_lan_dns_log="$(capture_eval_failure '
  network = import ./lib/network-validation.nix { inherit lib; };
  base = import ./vars.nix { inherit lib; };
  outsideLanIp =
    if network.usableIPv4InSubnet "10.200.0.10" base.networking.lan.ip base.networking.lan.prefixLength then
      "203.0.113.10"
    else
      "10.200.0.10";
  vars = base // {
    networking = base.networking // {
      dns = base.networking.dns // {
        privacyMode = "opportunistic";
        lanHosts = {
          "Bad Host" = base.networking.lan.ip;
          invalid-ip = "999.1.1.1";
          outside-lan = outsideLanIp;
        };
      };
    };
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
in system.nixosConfigurations.${base.hostname}.config.system.build.toplevel.drvPath
')"
for expected_message in \
  'dnsSettings.privacyMode must be one of: encrypted-only' \
  'dnsSettings.lanHosts names must be valid lowercase' \
  'dnsSettings.lanHosts values must be valid IPv4 addresses' \
  'dnsSettings.lanHosts addresses must be usable host addresses'; do
  if ! rg -Fq "$expected_message" <<<"$invalid_lan_dns_log"; then
    echo "❌ Invalid LAN DNS configuration failed without the actionable message: $expected_message"
    printf '%s\n' "$invalid_lan_dns_log"
    exit 1
  fi
done

eval_fails_with 'dnsSettings.lanHosts must be an attribute set mapping DNS names to IPv4 addresses' '
  base = import ./vars.nix { inherit lib; };
  vars = base // {
    networking = base.networking // {
      dns = base.networking.dns // { lanHosts = [ "server=192.168.1.10" ]; };
    };
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
in system.nixosConfigurations.${base.hostname}.config.system.build.toplevel.drvPath
'

identity_input_model_json="$(flake_eval_json '
  derive = import ./lib/identity-access.nix { inherit lib; };
  model = derive {
    identity = {
      adminUser = "identity-admin";
      canaryUser = "canary-user";
      appUsers = "ordinary-user";
      appAdminUsers = { mistaken = true; };
      appUserEmails = [ "ordinary-user=person@example.org" ];
      adminMailAddresses = "admin@example.org";
    };
    monitoringAccess.users = "monitor-only";
  };
in {
  appUsers = model.appUsers;
  appAdminUsers = model.appAdminUsers;
  appUserEmails = model.appUserEmails;
  adminMailAddresses = model.adminMailAddresses;
  monitoringUsers = model.monitoringUsers;
  preservesAppUsers = builtins.isString model.configuredAppUsers;
  preservesAppAdminUsers = builtins.isAttrs model.configuredAppAdminUsers;
  preservesAppUserEmails = builtins.isList model.configuredAppUserEmails;
  preservesAdminMailAddresses = builtins.isString model.configuredAdminMailAddresses;
  preservesMonitoringUsers = builtins.isString model.configuredMonitoringUsers;
}
')"
if ! jq -e '
  .appUsers == ["identity-admin", "canary-user"]
  and .appAdminUsers == ["identity-admin"]
  and .appUserEmails == {}
  and .adminMailAddresses == []
  and .monitoringUsers == []
  and .preservesAppUsers
  and .preservesAppAdminUsers
  and .preservesAppUserEmails
  and .preservesAdminMailAddresses
  and .preservesMonitoringUsers
' <<<"$identity_input_model_json" >/dev/null; then
  echo "❌ Identity/access derivation did not remain total while preserving malformed operator inputs."
  jq . <<<"$identity_input_model_json"
  exit 1
fi

mistyped_identity_collections_log="$(capture_eval_failure '
  base = import ./vars.nix { inherit lib; };
  invalidValues = builtins.getEnv "NIXHOMESERVER_IDENTITY_INPUT_MODE" == "invalid-values";
  identity = base.identity // {
    appUsers = if invalidValues then [ "Invalid User" ] else "ordinary-user";
    appAdminUsers = if invalidValues then [ "Invalid Admin" ] else "app-admin-only";
    appUserEmails =
      if invalidValues then { "Invalid User" = "not-an-email"; }
      else [ "ordinary-user=person@example.org" ];
    adminMailAddresses = if invalidValues then [ "not-an-email" ] else "admin@example.org";
  };
  monitoringAccess = base.monitoringAccess // {
    users = if invalidValues then [ "Invalid Monitor" ] else "monitor-only";
  };
  identityAccessModel = (import ./lib/identity-access.nix { inherit lib; }) {
    inherit identity monitoringAccess;
  };
  vars = base // {
    inherit identity identityAccessModel monitoringAccess;
    configuredIdentityAppUsers = identityAccessModel.configuredAppUsers;
    configuredIdentityAppAdminUsers = identityAccessModel.configuredAppAdminUsers;
    configuredIdentityAppUserEmails = identityAccessModel.configuredAppUserEmails;
    configuredIdentityAdminMailAddresses = identityAccessModel.configuredAdminMailAddresses;
    configuredMonitoringAccessUsers = identityAccessModel.configuredMonitoringUsers;
    kanidmAppUsers = identityAccessModel.appUsers;
    kanidmAppAdminUsers = identityAccessModel.appAdminUsers;
    kanidmAppUserEmails = identityAccessModel.appUserEmails // {
      ${identity.canaryUser} = "${identity.canaryUser}@${base.domain}";
    };
    kanidmAdminMailAddresses = identityAccessModel.adminMailAddresses;
    monitoringAccessUsers = identityAccessModel.monitoringUsers;
    filesSftpUsers = identityAccessModel.appUsers;
    jellyfinAdminUsers = identityAccessModel.appAdminUsers;
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
in system.nixosConfigurations.${base.hostname}.config.system.build.toplevel.drvPath
')"
for expected_message in \
  'identity.appUsers must be a list of Kanidm usernames' \
  'identity.appAdminUsers must be a list of Kanidm usernames' \
  'monitoringAccess.users must be a list of Kanidm usernames' \
  'identity.appUserEmails must be an attribute set mapping Kanidm usernames to email addresses' \
  'identity.adminMailAddresses must be a list of email address strings'; do
  if ! rg -Fq "$expected_message" <<<"$mistyped_identity_collections_log"; then
    echo "❌ Mistyped identity/access collections failed without actionable guidance: $expected_message"
    printf '%s\n' "$mistyped_identity_collections_log"
    exit 1
  fi
done

invalid_identity_values_log="$(NIXHOMESERVER_IDENTITY_INPUT_MODE=invalid-values \
  capture_eval_failure '
  base = import ./vars.nix { inherit lib; };
  invalidValues = builtins.getEnv "NIXHOMESERVER_IDENTITY_INPUT_MODE" == "invalid-values";
  identity = base.identity // {
    appUsers = if invalidValues then [ "Invalid User" ] else "ordinary-user";
    appAdminUsers = if invalidValues then [ "Invalid Admin" ] else "app-admin-only";
    appUserEmails =
      if invalidValues then { "Invalid User" = "not-an-email"; }
      else [ "ordinary-user=person@example.org" ];
    adminMailAddresses = if invalidValues then [ "not-an-email" ] else "admin@example.org";
  };
  monitoringAccess = base.monitoringAccess // {
    users = if invalidValues then [ "Invalid Monitor" ] else "monitor-only";
  };
  identityAccessModel = (import ./lib/identity-access.nix { inherit lib; }) {
    inherit identity monitoringAccess;
  };
  vars = base // {
    inherit identity identityAccessModel monitoringAccess;
    configuredIdentityAppUsers = identityAccessModel.configuredAppUsers;
    configuredIdentityAppAdminUsers = identityAccessModel.configuredAppAdminUsers;
    configuredIdentityAppUserEmails = identityAccessModel.configuredAppUserEmails;
    configuredIdentityAdminMailAddresses = identityAccessModel.configuredAdminMailAddresses;
    configuredMonitoringAccessUsers = identityAccessModel.configuredMonitoringUsers;
    kanidmAppUsers = identityAccessModel.appUsers;
    kanidmAppAdminUsers = identityAccessModel.appAdminUsers;
    kanidmAppUserEmails = identityAccessModel.appUserEmails // {
      ${identity.canaryUser} = "${identity.canaryUser}@${base.domain}";
    };
    kanidmAdminMailAddresses = identityAccessModel.adminMailAddresses;
    monitoringAccessUsers = identityAccessModel.monitoringUsers;
    filesSftpUsers = identityAccessModel.appUsers;
    jellyfinAdminUsers = identityAccessModel.appAdminUsers;
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
in system.nixosConfigurations.${base.hostname}.config.system.build.toplevel.drvPath
')"
for expected_message in \
  'identity.appUsers entries must be canonical Kanidm usernames' \
  'identity.appAdminUsers entries must be canonical Kanidm usernames' \
  'monitoringAccess.users entries must be canonical Kanidm usernames' \
  'identity.appUserEmails keys must be canonical Kanidm usernames' \
  'identity.appUserEmails values must be ordinary user@public-domain email address strings' \
  'identity.adminMailAddresses entries must be ordinary user@public-domain email address strings'; do
  if ! rg -Fq "$expected_message" <<<"$invalid_identity_values_log"; then
    echo "❌ Invalid identity/access values failed without actionable guidance: $expected_message"
    printf '%s\n' "$invalid_identity_values_log"
    exit 1
  fi
done

require_fixed scripts/admin/validate-config-readiness.sh 'ipaddress.IPv4Address' \
  "Readiness checks must validate IPv4 values numerically, not only by text shape."
require_fixed scripts/admin/validate-config-readiness.sh 'ipaddress.IPv4Network(sys.argv[5], strict=True)' \
  "Readiness checks must reject non-canonical NetBird CIDRs."
require_fixed modules/Core_Modules/validation/default.nix 'if builtins.isInt kopiaPort then kopiaPort + 1 else -1' \
  "Derived endpoint validation must include Kopia's authentication bridge."
require_fixed modules/Core_Modules/kopia/service.nix 'if builtins.isInt kopiaPortRaw then kopiaPortRaw + 1 else -1' \
  "Kopia service evaluation must defer mistyped-port reporting to central validation."
require_fixed modules/Core_Modules/auth-gateway/default.nix 'if builtins.isInt kopiaPort then kopiaPort + 1 else -1' \
  "Auth gateway evaluation must defer mistyped-port reporting to central validation."
require_fixed modules/Core_Modules/unbound/default.nix 'if builtins.isAttrs lanDnsHostsRaw then' \
  "Unbound evaluation must defer mistyped LAN host reporting to central validation."

echo "✅ Network, DNS, Kanidm-adjacent name, ZFS pool, and managed-filesystem validation passed."
