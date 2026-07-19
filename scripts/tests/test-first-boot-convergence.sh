#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"
cd "$TESTS_REPO_ROOT"
ensure_tools bash jq mktemp nix

host="$(test_default_host)"
services_json="$(NIXHOMESERVER_TEST_HOST="$host" nix eval --impure --json --expr '
let
  f = builtins.getFlake (builtins.getEnv "NIXHOMESERVER_FLAKE_REF_FOR_EVAL");
  host = builtins.getEnv "NIXHOMESERVER_TEST_HOST";
  base = builtins.getAttr host f.nixosConfigurations;
  cfg = base.config;
  cfgWithSeerr = (base.extendModules {
    modules = [{ repo.seerr.enable = f.inputs.nixpkgs.lib.mkForce true; }];
  }).config;
  names = [
    "audiobookshelf-library-watch-config-v1"
    "audiobookshelf-oidc-bootstrap-v1"
    "fileshare-acl-migrate"
    "fileshare-user-root-sync"
    "jellyfin-network-config-v1"
    "jellyfin-library-monitor-v1"
    "jellyfin-library-bootstrap-v1"
    "kavita-oidc-bootstrap"
    "kavita-library-watch-config-v1"
    "kopia-repository-bootstrap"
    "kanidm-account-policy"
    "kanidm-branding"
    "kanidm-files-posix-groups"
    "local-admin-bootstrap-password"
    "media-automation-bootstrap-qbittorrent"
    "media-automation-bootstrap-prowlarr-qbittorrent"
    "media-automation-bootstrap-sonarr"
    "media-automation-bootstrap-radarr"
    "media-automation-bootstrap-prowlarr"
    "media-automation-bootstrap-seerr"
    "paperless-permissions-bootstrap"
  ];
  explicitFailureNames = [
    "audiobookshelf-library-watch-config-v1"
    "audiobookshelf-oidc-bootstrap-v1"
    "jellyfin-network-config-v1"
    "jellyfin-library-monitor-v1"
    "jellyfin-library-bootstrap-v1"
    "kavita-oidc-bootstrap"
    "kavita-library-watch-config-v1"
    "kopia-repository-bootstrap"
    "local-admin-bootstrap-password"
    "media-automation-bootstrap-qbittorrent"
    "media-automation-bootstrap-prowlarr-qbittorrent"
    "media-automation-bootstrap-sonarr"
    "media-automation-bootstrap-radarr"
    "media-automation-bootstrap-prowlarr"
    "media-automation-bootstrap-seerr"
    "paperless-permissions-bootstrap"
  ];
  serviceData = name:
    let
      serviceCfg = if name == "media-automation-bootstrap-seerr" then cfgWithSeerr else cfg;
      service = builtins.getAttr name serviceCfg.systemd.services;
    in {
      restart = service.serviceConfig.Restart or null;
      restartSec = service.serviceConfig.RestartSec or null;
      requiresExplicitFailure = builtins.elem name explicitFailureNames;
      script = service.script or "";
    };
in
  f.inputs.nixpkgs.lib.genAttrs names serviceData
')"

jq -e '
  length == 21
  and all(
    to_entries[];
    .value.restart == "on-failure"
    and (.value.restartSec | type == "string" and length > 0)
    and ((.value.requiresExplicitFailure | not) or (.value.script | contains("exit 1")))
  )
' <<<"$services_json" >/dev/null || {
  echo "❌ A first-boot reconciler can still report permanent success after transient startup failure."
  jq 'map_values({restart, restartSec, hasFailureExit: (.script | contains("exit 1"))})' <<<"$services_json"
  exit 1
}

tmpdir="$(mktemp -d)"
cleanup() { rm -rf "$tmpdir"; }
trap cleanup EXIT
mkdir -p "$tmpdir/bin"

jq -r '."media-automation-bootstrap-qbittorrent".script' <<<"$services_json" >"$tmpdir/qbittorrent-bootstrap.sh"
chmod +x "$tmpdir/qbittorrent-bootstrap.sh"

cat >"$tmpdir/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

for arg in "$@"; do
  case "$arg" in
    */api/v2/app/version)
      count=0
      [[ ! -f "$MOCK_CURL_STATE" ]] || count="$(<"$MOCK_CURL_STATE")"
      count=$((count + 1))
      printf '%s\n' "$count" >"$MOCK_CURL_STATE"
      if (( count <= MOCK_READY_AFTER )); then
        exit 22
      fi
      printf 'v-test\n'
      exit 0
      ;;
    */api/v2/torrents/info)
      printf '[]\n'
      exit 0
      ;;
    */api/v2/torrents/editCategory)
      [[ "${MOCK_FAIL_EDIT:-0}" != "1" ]]
      exit
      ;;
  esac
done
exit 0
EOF
cat >"$tmpdir/bin/sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
make_test_executable "$tmpdir/bin/curl" "$tmpdir/bin/sleep"

state="$tmpdir/delayed.state"
PATH="$tmpdir/bin:$PATH" MOCK_CURL_STATE="$state" MOCK_READY_AFTER=2 \
  bash "$tmpdir/qbittorrent-bootstrap.sh"
if [[ "$(<"$state")" -lt 4 ]]; then
  echo "❌ qBittorrent bootstrap did not wait for delayed readiness and verify it again."
  exit 1
fi

state="$tmpdir/retry.state"
if PATH="$tmpdir/bin:$PATH" MOCK_CURL_STATE="$state" MOCK_READY_AFTER=61 \
  bash "$tmpdir/qbittorrent-bootstrap.sh" >/dev/null 2>&1; then
  echo "❌ qBittorrent bootstrap returned success after its readiness timeout."
  exit 1
fi
PATH="$tmpdir/bin:$PATH" MOCK_CURL_STATE="$state" MOCK_READY_AFTER=61 \
  bash "$tmpdir/qbittorrent-bootstrap.sh"

state="$tmpdir/edit-failure.state"
if PATH="$tmpdir/bin:$PATH" MOCK_CURL_STATE="$state" MOCK_READY_AFTER=0 MOCK_FAIL_EDIT=1 \
  bash "$tmpdir/qbittorrent-bootstrap.sh" >/dev/null 2>&1; then
  echo "❌ qBittorrent bootstrap hid a failed category reconciliation."
  exit 1
fi

echo "✅ First-boot reconciliation retries and delayed-readiness behavior passed."
