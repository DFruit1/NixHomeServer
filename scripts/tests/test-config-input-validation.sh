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

derived_port_collision_expr='
  let
    f = builtins.getFlake (builtins.getEnv "NIXHOMESERVER_FLAKE_REF_FOR_EVAL");
    lib = f.inputs.nixpkgs.lib;
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
if nix eval --impure --raw --expr "$derived_port_collision_expr" >"$invalid_filesystem_log" 2>&1; then
  echo "❌ Host evaluation accepted a service port colliding with the derived Kopia authentication bridge."
  exit 1
fi
if ! rg -Fq 'derived service endpoints contain duplicate port values' "$invalid_filesystem_log"; then
  echo "❌ Derived endpoint collision failed without the actionable validation message."
  cat "$invalid_filesystem_log"
  exit 1
fi

mistyped_kopia_port_expr='
  let
    f = builtins.getFlake (builtins.getEnv "NIXHOMESERVER_FLAKE_REF_FOR_EVAL");
    lib = f.inputs.nixpkgs.lib;
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
if nix eval --impure --raw --expr "$mistyped_kopia_port_expr" >"$invalid_filesystem_log" 2>&1; then
  echo "❌ Host evaluation accepted a non-integer Kopia service port."
  exit 1
fi
if ! rg -Fq 'service endpoint ports must be integers from 1 through 65535' "$invalid_filesystem_log"; then
  echo "❌ Mistyped Kopia port failed without the actionable validation message."
  cat "$invalid_filesystem_log"
  exit 1
fi

invalid_lan_dns_expr='
  let
    f = builtins.getFlake (builtins.getEnv "NIXHOMESERVER_FLAKE_REF_FOR_EVAL");
    lib = f.inputs.nixpkgs.lib;
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
'
if nix eval --impure --raw --expr "$invalid_lan_dns_expr" >"$invalid_filesystem_log" 2>&1; then
  echo "❌ Host evaluation accepted invalid LAN DNS names, addresses, or privacy mode."
  exit 1
fi
for expected_message in \
  'dnsSettings.privacyMode must be one of: encrypted-only' \
  'dnsSettings.lanHosts names must be valid lowercase' \
  'dnsSettings.lanHosts values must be valid IPv4 addresses' \
  'dnsSettings.lanHosts addresses must be usable host addresses'; do
  if ! rg -Fq "$expected_message" "$invalid_filesystem_log"; then
    echo "❌ Invalid LAN DNS configuration failed without the actionable message: $expected_message"
    cat "$invalid_filesystem_log"
    exit 1
  fi
done

mistyped_lan_hosts_expr='
  let
    f = builtins.getFlake (builtins.getEnv "NIXHOMESERVER_FLAKE_REF_FOR_EVAL");
    lib = f.inputs.nixpkgs.lib;
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
if nix eval --impure --raw --expr "$mistyped_lan_hosts_expr" >"$invalid_filesystem_log" 2>&1; then
  echo "❌ Host evaluation accepted a non-attribute-set dnsSettings.lanHosts value."
  exit 1
fi
if ! rg -Fq 'dnsSettings.lanHosts must be an attribute set mapping DNS names to IPv4 addresses' "$invalid_filesystem_log"; then
  echo "❌ Mistyped dnsSettings.lanHosts failed without the actionable validation message."
  cat "$invalid_filesystem_log"
  exit 1
fi

identity_input_model_json="$(nix eval --impure --json --expr '
  let
    f = builtins.getFlake (builtins.getEnv "NIXHOMESERVER_FLAKE_REF_FOR_EVAL");
    lib = f.inputs.nixpkgs.lib;
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
      seerrAccess.requestManagers = { mistaken = true; };
      fileAccess.usbUsers = "usb-only";
    };
  in {
    appUsers = model.appUsers;
    appAdminUsers = model.appAdminUsers;
    appUserEmails = model.appUserEmails;
    adminMailAddresses = model.adminMailAddresses;
    monitoringUsers = model.monitoringUsers;
    seerrRequestManagers = model.seerrRequestManagers;
    usbUsers = model.usbUsers;
    preservesAppUsers = builtins.isString model.configuredAppUsers;
    preservesAppAdminUsers = builtins.isAttrs model.configuredAppAdminUsers;
    preservesAppUserEmails = builtins.isList model.configuredAppUserEmails;
    preservesAdminMailAddresses = builtins.isString model.configuredAdminMailAddresses;
    preservesMonitoringUsers = builtins.isString model.configuredMonitoringUsers;
    preservesSeerrManagers = builtins.isAttrs model.configuredSeerrRequestManagers;
    preservesUsbUsers = builtins.isString model.configuredUsbUsers;
  }
')"
if ! jq -e '
  .appUsers == ["identity-admin", "canary-user"]
  and .appAdminUsers == ["identity-admin"]
  and .appUserEmails == {}
  and .adminMailAddresses == []
  and .monitoringUsers == []
  and .seerrRequestManagers == []
  and .usbUsers == []
  and .preservesAppUsers
  and .preservesAppAdminUsers
  and .preservesAppUserEmails
  and .preservesAdminMailAddresses
  and .preservesMonitoringUsers
  and .preservesSeerrManagers
  and .preservesUsbUsers
' <<<"$identity_input_model_json" >/dev/null; then
  echo "❌ Identity/access derivation did not remain total while preserving malformed operator inputs."
  jq . <<<"$identity_input_model_json"
  exit 1
fi

mistyped_identity_collections_expr='
  let
    f = builtins.getFlake (builtins.getEnv "NIXHOMESERVER_FLAKE_REF_FOR_EVAL");
    lib = f.inputs.nixpkgs.lib;
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
    seerrAccess = base.seerrAccess // {
      requestManagers = if invalidValues then [ "Invalid Manager" ] else "request-manager";
    };
    fileAccess = base.fileAccess // {
      usbUsers = if invalidValues then [ "Invalid USB" ] else "usb-only";
    };
    identityAccessModel = (import ./lib/identity-access.nix { inherit lib; }) {
      inherit fileAccess identity monitoringAccess seerrAccess;
    };
    vars = base // {
      inherit fileAccess identity identityAccessModel monitoringAccess seerrAccess;
      configuredIdentityAppUsers = identityAccessModel.configuredAppUsers;
      configuredIdentityAppAdminUsers = identityAccessModel.configuredAppAdminUsers;
      configuredIdentityAppUserEmails = identityAccessModel.configuredAppUserEmails;
      configuredIdentityAdminMailAddresses = identityAccessModel.configuredAdminMailAddresses;
      configuredMonitoringAccessUsers = identityAccessModel.configuredMonitoringUsers;
      configuredSeerrRequestManagers = identityAccessModel.configuredSeerrRequestManagers;
      configuredFileAccessUsbUsers = identityAccessModel.configuredUsbUsers;
      kanidmAppUsers = identityAccessModel.appUsers;
      kanidmAppAdminUsers = identityAccessModel.appAdminUsers;
      kanidmAppUserEmails = identityAccessModel.appUserEmails // {
        ${identity.canaryUser} = "${identity.canaryUser}@${base.domain}";
      };
      kanidmAdminMailAddresses = identityAccessModel.adminMailAddresses;
      monitoringAccessUsers = identityAccessModel.monitoringUsers;
      seerrRequestManagers = identityAccessModel.seerrRequestManagers;
      fileAccessUsbUsers = identityAccessModel.usbUsers;
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
'
if nix eval --impure --raw --expr "$mistyped_identity_collections_expr" >"$invalid_filesystem_log" 2>&1; then
  echo "❌ Host evaluation accepted bare strings or a list where identity/access collections were required."
  exit 1
fi
for expected_message in \
  'identity.appUsers must be a list of Kanidm usernames' \
  'identity.appAdminUsers must be a list of Kanidm usernames' \
  'monitoringAccess.users must be a list of Kanidm usernames' \
  'seerrAccess.requestManagers must be a list of Kanidm usernames' \
  'fileAccess.usbUsers must be a list of Kanidm usernames' \
  'identity.appUserEmails must be an attribute set mapping Kanidm usernames to email addresses' \
  'identity.adminMailAddresses must be a list of email address strings'; do
  if ! rg -Fq "$expected_message" "$invalid_filesystem_log"; then
    echo "❌ Mistyped identity/access collections failed without actionable guidance: $expected_message"
    cat "$invalid_filesystem_log"
    exit 1
  fi
done

if NIXHOMESERVER_IDENTITY_INPUT_MODE=invalid-values \
    nix eval --impure --raw --expr "$mistyped_identity_collections_expr" >"$invalid_filesystem_log" 2>&1; then
  echo "❌ Host evaluation accepted invalid identity/access member names or email values."
  exit 1
fi
for expected_message in \
  'identity.appUsers entries must be canonical Kanidm usernames' \
  'identity.appAdminUsers entries must be canonical Kanidm usernames' \
  'monitoringAccess.users entries must be canonical Kanidm usernames' \
  'seerrAccess.requestManagers entries must be canonical Kanidm usernames' \
  'fileAccess.usbUsers entries must be canonical Kanidm usernames' \
  'identity.appUserEmails keys must be canonical Kanidm usernames' \
  'identity.appUserEmails values must be ordinary user@public-domain email address strings' \
  'identity.adminMailAddresses entries must be ordinary user@public-domain email address strings'; do
  if ! rg -Fq "$expected_message" "$invalid_filesystem_log"; then
    echo "❌ Invalid identity/access values failed without actionable guidance: $expected_message"
    cat "$invalid_filesystem_log"
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
