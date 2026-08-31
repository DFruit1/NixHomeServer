#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"

cd "$TESTS_REPO_ROOT"

ensure_tools jq nix rg

for facet in default networking identity filepaths services backups; do
  if [[ ! -f "modules/browsertrix-downloader/${facet}.nix" ]]; then
    echo "❌ Browsertrix Downloader should keep its removable module facets explicit: missing ${facet}.nix" >&2
    exit 1
  fi
done

require_fixed modules/catalog.nix 'browsertrix-downloader = app ./browsertrix-downloader' \
  "Browsertrix Downloader should be registered in the application catalog."
require_fixed modules/Core_Modules/impermanence/default.nix '"/var/lib/browsertrix-downloader"' \
  "Browsertrix Downloader state should remain persistent when its module is removed."
require_fixed modules/browsertrix-downloader/services.nix 'virtualisation.podman.enable = true' \
  "Browsertrix Downloader should use the host's rootless Podman runtime."
require_fixed modules/browsertrix-downloader/services.nix 'browsertrix-downloader-worker' \
  "Browsertrix crawling should run in a service separate from its HTTP API."
require_fixed modules/browsertrix-downloader/services.nix 'browsertrix-downloader-egress-policy' \
  "Browsertrix crawler traffic should be denied access to private network ranges."
require_fixed modules/browsertrix-downloader/services.nix '@sha256:7f9d5e20e0f6efea2e9e257aa37e536495ac9f33422ab886e446dabf1065af2c' \
  "Browsertrix Crawler should be pinned to its published multi-architecture manifest digest."
require_fixed modules/browsertrix-downloader/filepaths.nix 'install -d -m 0770 -o browsertrix-downloader -g browsertrix-downloader' \
  "Browsertrix storage provisioning should repair the persistent state root ownership after it is mounted."
require_fixed modules/browsertrix-downloader/filepaths.nix 'chmod 0660' \
  "Browsertrix storage provisioning should keep shared SQLite files writable by both service users."
require_fixed modules/browsertrix-downloader/services.nix '${pkgs.getent}/bin/getent group' \
  "Browsertrix worker startup should resolve groups with the dedicated getent package."
require_fixed modules/browsertrix-downloader/services.nix 'path = [ "/run/wrappers"' \
  "Browsertrix rootless Podman should prefer NixOS's privileged uid/gid mapping wrappers."
require_fixed modules/browsertrix-downloader/services.nix 'openssl dgst -sha256 -binary' \
  "Browsertrix should normalize its encrypted OAuth cookie secret to the 32-byte format required by OAuth2 Proxy."

host="$(test_default_host)"
result="$(NIXHOMESERVER_TEST_HOST="$host" nix eval --impure --json --expr '
let
  flake = builtins.getFlake (builtins.getEnv "NIXHOMESERVER_FLAKE_REF_FOR_EVAL");
  hostName = builtins.getEnv "NIXHOMESERVER_TEST_HOST";
  configuredVars = flake.lib.nixhomeserverSettings.${hostName};
  settings = configuredVars // {
    applications = configuredVars.applications // { enabled = [ "browsertrix-downloader" ]; };
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
in {
  moduleEnabled = cfg.nixhomeserver.modules.browsertrix-downloader or false;
  webUser = cfg.systemd.services.browsertrix-downloader.serviceConfig.User;
  workerUser = cfg.systemd.services.browsertrix-downloader-worker.serviceConfig.User;
  workerSubIds = cfg.users.users.browsertrix-downloader-worker.autoSubUidGidRange;
  podmanEnabled = cfg.virtualisation.podman.enable;
  archiveRoot = cfg.repo.browsertrixDownloader.paths.archiveRoot;
  sqliteSources = map (entry: entry.source) cfg.repo.backups.sqliteDumps;
  privateHost = cfg.services.unbound.privateHosts."archives.${vars.domain}".target;
  webSandbox = cfg.systemd.services.browsertrix-downloader.serviceConfig;
  workerSandbox = cfg.systemd.services.browsertrix-downloader-worker.serviceConfig;
  workerAfter = cfg.systemd.services.browsertrix-downloader-worker.after;
  oauthCookieRuntimeDirectory = cfg.systemd.services.browsertrix-downloader-oauth2-cookie-secret.serviceConfig.RuntimeDirectory;
  oauthCookieRequires = cfg.systemd.services.browsertrix-downloader-oauth2-cookie-secret.requires;
  oauthCookieAfter = cfg.systemd.services.browsertrix-downloader-oauth2-cookie-secret.after;
  oauthProxyRequires = cfg.systemd.services.browsertrix-downloader-oauth2-proxy.requires;
  oauthProxyWantedBy = cfg.systemd.services.browsertrix-downloader-oauth2-proxy.wantedBy;
  oauthProxyExecStart = cfg.systemd.services.browsertrix-downloader-oauth2-proxy.serviceConfig.ExecStart;
  authGatewayMode = cfg.repo.authGateway.mode;
  authGatewayApp = cfg.repo.authGateway.protectedApps.browsertrix or null;
}
')"

if ! jq -e '
  .moduleEnabled
  and (.webUser == "browsertrix-downloader")
  and (.workerUser == "browsertrix-downloader-worker")
  and .workerSubIds
  and .podmanEnabled
  and (.archiveRoot | endswith("/_WebArchives"))
  and (.sqliteSources | any(endswith("/browsertrix-downloader.sqlite")))
  and (.privateHost == "private")
  and (.webSandbox.NoNewPrivileges == true)
  and (.webSandbox.PrivateTmp == true)
  and (.webSandbox.ProtectSystem == "strict")
  and (.webSandbox.ProtectKernelModules == true)
  and (.webSandbox.ProtectKernelTunables == true)
  and (.webSandbox.RestrictNamespaces == true)
  and (.workerSandbox.Delegate == true)
  and (.workerSandbox.PrivateTmp == true)
  and (.workerSandbox.ProtectSystem == "strict")
  and (.workerSandbox.ProtectKernelModules == true)
  and (.workerSandbox.ProtectKernelTunables == true)
  and (.workerSandbox.PrivateDevices == false)
  and (.workerAfter | index("unbound.service") != null)
  and (.oauthCookieRuntimeDirectory == "browsertrix-downloader-oauth2-proxy")
  and (.oauthCookieRequires | index("agenix.service") == null)
  and (.oauthCookieAfter | index("agenix.service") == null)
  and (.oauthProxyRequires | index("browsertrix-downloader-oauth2-cookie-secret.service") != null)
  and (.authGatewayMode == "gateway")
  and (.authGatewayApp.host | startswith("archives."))
  and (.authGatewayApp.upstream == "http://127.0.0.1:8088")
  and (.authGatewayApp.allowedGroups | index("web-archive-users") != null)
  and (.oauthProxyWantedBy | length == 0)
  and (.oauthProxyExecStart | contains("--cookie-secret-file=/run/browsertrix-downloader-oauth2-proxy/cookie-secret"))
' <<<"$result" >/dev/null; then
  echo "❌ Browsertrix Downloader module invariants were not satisfied." >&2
  jq . <<<"$result" >&2
  exit 1
fi

echo "✅ Browsertrix Downloader module tests passed."
