#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"
cd "$TESTS_REPO_ROOT"

ensure_tools jq nix rg

for required_file in \
  modules/jellyfin/package.nix \
  modules/jellyfin/oidc.nix \
  modules/jellyfin/patches/oidc-hardening.patch \
  modules/jellyfin/nuget-deps.json; do
  [[ -f "$required_file" ]] || {
    echo "❌ Jellyfin OIDC implementation is missing $required_file." >&2
    exit 1
  }
done

require_fixed modules/jellyfin/package.nix \
  'rev = "0f037d99bf5849cceac1ecf7080b7a83f3b2cb64";' \
  "Jellyfin OIDC must pin the reviewed v1.0.8 source commit"
require_fixed modules/jellyfin/package.nix \
  'hash = "sha256-4oRiD30Imm5MmYjz7dBoPQyooTvl5jMSEDuhpGaEX5Q=";' \
  "Jellyfin OIDC must pin the reviewed source hash"
require_fixed modules/jellyfin/package.nix \
  'dotnet-sdk = pkgs.dotnetCorePackages.sdk_9_0;' \
  "Jellyfin OIDC must use the plugin's declared .NET 9 SDK"
require_fixed modules/jellyfin/package.nix \
  '"guid": "d4e5f6a7-b8c9-0d1e-2f3a-4b5c6d7e8f90"' \
  "Jellyfin OIDC must install a local manifest with the upstream GUID"
require_fixed modules/jellyfin/package.nix \
  '"autoUpdate": false' \
  "Jellyfin OIDC updates must remain Nix-managed"
require_fixed modules/jellyfin/package.nix \
  'jellyfinOidcWeb = pkgs.jellyfin-web.overrideAttrs' \
  "Jellyfin OIDC must use an immutable web package with the login script injected"
require_fixed modules/jellyfin/package.nix \
  '<script defer="defer" src="/sso/OIDC/LoginButtons"></script>' \
  "Jellyfin Web must load the OIDC login script outside the sanitized branding disclaimer"

for validation_fragment in \
  'ValidateIssuer = true' \
  'ValidateAudience = true' \
  'ValidateLifetime = true' \
  'ValidateIssuerSigningKey = true' \
  'RequireExpirationTime = true' \
  'RequireSignedTokens = true' \
  'SecurityTokenSignatureKeyNotFoundException' \
  'TimeSpan.FromMinutes(2)'; do
  require_fixed modules/jellyfin/patches/oidc-hardening.patch "$validation_fragment" \
    "OIDC hardening patch is missing: $validation_fragment"
done

host="$(test_default_host)"
oidc_json="$(
  nix eval --json ".#nixosConfigurations.${host}.config" \
    --apply 'cfg: {
      secret = {
        present = cfg.age.secrets ? jellyfinOidcClientSecret;
        owner = cfg.age.secrets.jellyfinOidcClientSecret.owner;
        group = cfg.age.secrets.jellyfinOidcClientSecret.group;
        mode = cfg.age.secrets.jellyfinOidcClientSecret.mode;
      };
      oauth = cfg.services.kanidm.provision.systems.oauth2.jellyfin-web;
      bootstrap = {
        after = cfg.systemd.services.jellyfin-oidc-bootstrap-v1.after;
        wants = cfg.systemd.services.jellyfin-oidc-bootstrap-v1.wants;
        restart = cfg.systemd.services.jellyfin-oidc-bootstrap-v1.serviceConfig.Restart;
        umask = cfg.systemd.services.jellyfin-oidc-bootstrap-v1.serviceConfig.UMask;
        credential = cfg.systemd.services.jellyfin-oidc-bootstrap-v1.serviceConfig.LoadCredential;
        path = map toString cfg.systemd.services.jellyfin-oidc-bootstrap-v1.path;
        script = cfg.systemd.services.jellyfin-oidc-bootstrap-v1.script;
      };
      jellyfin = {
        bindReadOnlyPaths = cfg.systemd.services.jellyfin.serviceConfig.BindReadOnlyPaths or [];
        execStartPre = map toString (cfg.systemd.services.jellyfin.serviceConfig.ExecStartPre or []);
        restartTriggers = map toString cfg.systemd.services.jellyfin.restartTriggers;
      };
      libraryBootstrapScript = cfg.systemd.services.jellyfin-library-bootstrap-v1.script;
      pluginDirs = cfg.systemd.tmpfiles.settings.jellyfinOidcDirs;
      firewall = cfg.networking.firewall.interfaces;
    }'
)"

jq -e '
  .secret == {
    present: true,
    owner: "kanidm",
    group: "jellyfin",
    mode: "0440"
  }
  and (.oauth.displayName == "Videos")
  and (.oauth.originUrl | endswith("/sso/OIDC/Callback/kanidm"))
  and (.oauth.originLanding | startswith("https://videos."))
  and .oauth.preferShortUsername
  and (.oauth.scopeMaps."jellyfin-users" == ["openid", "profile", "email"])
  and (.bootstrap.after | index("jellyfin.service") != null)
  and (.bootstrap.after | index("jellyfin-library-bootstrap-v1.service") != null)
  and (.bootstrap.after | index("kanidm.service") != null)
  and (.bootstrap.after | index("caddy.service") != null)
  and (.bootstrap.wants | index("jellyfin.service") != null)
  and (.bootstrap.restart == "on-failure")
  and (.bootstrap.umask == "0077")
  and (.bootstrap.credential | tostring | contains("jellyfin-oidc-client-secret:"))
  and any(.bootstrap.path[]; contains("diffutils"))
  and (.bootstrap.script | contains("\"DefaultProvider\": \"kanidm\""))
  and (.bootstrap.script | contains("\"AutoCreateUsers\": false"))
  and (.bootstrap.script | contains("\"RoleMappings\": []"))
  and (.bootstrap.script | contains("\"DefaultRoleName\": \"\""))
  and (.bootstrap.script | contains("\"ProviderId\": \"kanidm\""))
  and (.bootstrap.script | contains("\"UsernameClaim\": \"preferred_username\""))
  and (.bootstrap.script | contains("\"SyncProfileImage\": false"))
  and (.bootstrap.script | contains(".QuickConnectAvailable = true"))
  and (.bootstrap.script | contains("nixhomeserver:jellyfin-oidc:start"))
  and (.bootstrap.script | contains("html.nixhomeserver-oidc-ready form.manualLoginForm"))
  and (.bootstrap.script | contains("/sso/OIDC/QuickConnect/kanidm"))
  and (.bootstrap.script | contains("Kanidm password is not a Jellyfin password"))
  and ((.bootstrap.script | contains("/sso/OIDC/LoginButtons")) | not)
  and (.jellyfin.bindReadOnlyPaths | length == 0)
  and any(.jellyfin.execStartPre[]; contains("jellyfin-oidc-manifest-install"))
  and (.jellyfin.restartTriggers | length > 0)
  and (.libraryBootstrapScript | contains("jellyfin_canary_user="))
  and (.libraryBootstrapScript | contains("--argjson isHidden"))
  and (.libraryBootstrapScript | contains(".IsHidden = $isHidden"))
  and (.pluginDirs."/var/lib/jellyfin/plugins".d.mode == "0700")
  and (.pluginDirs."/var/lib/jellyfin/plugins".d.user == "jellyfin")
  and (.pluginDirs."/var/lib/jellyfin/plugins".d.group == "jellyfin")
  and ([.firewall[]?.allowedTCPPorts[]?] | index(8096) != null)
  and ([.firewall[]?.allowedUDPPorts[]?] | index(7359) != null)
' <<<"$oidc_json" >/dev/null || {
  echo "❌ Evaluated Jellyfin OIDC, discovery, or Quick Connect contract is incomplete." >&2
  jq . <<<"$oidc_json" >&2
  exit 1
}

require_fixed modules/jellyfin/oidc.nix \
  'pluginConfigFile = "${dataDir}/plugins/configurations/Jellyfin.Plugin.OIDC.xml";' \
  "Jellyfin OIDC must enforce the exact plugin configuration file permissions"
require_fixed modules/jellyfin/oidc.nix \
  'install -m 0600 -o jellyfin -g jellyfin' \
  "Jellyfin OIDC configuration must remain readable only by Jellyfin"
require_fixed modules/jellyfin/oidc.nix \
  'install -m 0444' \
  "Jellyfin OIDC assemblies must remain available after a generation rollback"
forbid_match modules/jellyfin/oidc.nix \
  'pluginRuntimeDir|ln -sfn' \
  "Jellyfin OIDC must not persist links into an ephemeral runtime bind"
require_fixed modules/jellyfin/oidc.nix \
  'if $text == "" then 0' \
  "Jellyfin OIDC branding reconciliation must treat empty branding fields as having no managed markers"
require_fixed modules/jellyfin/oidc.nix \
  'Kanidm password is not a Jellyfin password' \
  "Native Jellyfin clients must explain that their password box does not accept Kanidm credentials"
require_fixed modules/jellyfin/oidc.nix \
  '/sso/OIDC/QuickConnect/kanidm' \
  "Native Jellyfin clients must receive the browser URL used to authorize Quick Connect"
require_fixed modules/jellyfin/oidc.nix \
  'def remove_managed($text; $start; $end):' \
  "Jellyfin branding reconciliation must remove the legacy browser script from native disclaimers"
require_fixed modules/jellyfin/oidc.nix \
  'if contains($nativeDisclaimer) then .' \
  "Native Jellyfin Quick Connect instructions must reconcile idempotently"
forbid_match modules/jellyfin/oidc.nix \
  '/sso/OIDC/LoginButtons' \
  "Executable Jellyfin Web markup must never be stored in the native-client LoginDisclaimer"
forbid_match modules/jellyfin/oidc.nix \
  'published-server-url|oauth2-proxy' \
  "Jellyfin OIDC must not override discovery or add an auth proxy"
require_fixed modules/jellyfin/networking.nix \
  'allowedUDPPorts = [ ports.jellyfinDiscovery ];' \
  "Jellyfin LAN autodiscovery must remain enabled"
require_fixed modules/jellyfin/networking.nix \
  'allowedTCPPorts = [ ports.jellyfin ];' \
  "Jellyfin native clients must retain direct LAN access"
require_fixed flake/nixos-tests.nix \
  'SO_BROADCAST' \
  "The Jellyfin VM test must exercise LAN broadcast discovery rather than unicast only"
require_fixed flake/nixos-tests.nix \
  'SO_BINDTODEVICE, b"eth1"' \
  "The multi-homed Jellyfin VM client must send discovery through the shared test LAN"
require_fixed flake/nixos-tests.nix \
  'client.wait_for_unit("multi-user.target")' \
  "The Jellyfin VM discovery probe must wait for the client network before broadcasting"
require_fixed flake/nixos-tests.nix \
  'b"Who is JellyfinServer?"' \
  "The Jellyfin VM test must use Fladder's discovery request payload"
require_fixed flake/nixos-tests.nix \
  '("255.255.255.255", 7359)' \
  "The Jellyfin VM test must send the discovery probe to the limited broadcast address"

echo "✅ Jellyfin OIDC, native fallback, discovery, and Quick Connect checks passed."
